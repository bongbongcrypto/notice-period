"""Writes the deployment's addresses and values into the places that show them, from one deployment file.

    python3 scripts/stamp.py [--check] [--root DIR] [DEPLOYMENT_JSON]

DEPLOYMENT_JSON (default deployments/current.json) is the only hand-edited place for addresses. From it this script
writes docs/data/deployment.js (window.NP_DEPLOYMENT) and every marked block of README.md and SPEC.md:

    <!-- stamp:contracts -->   ...generated, never edited by hand...   <!-- /stamp:contracts -->
    <!-- stamp:values -->      ...                                     <!-- /stamp:values -->

--check writes nothing and exits 1 if any of those places differs from what the deployment file gives (a hand edit
inside a block, or a deployment file changed without a stamp). Exit 2: the deployment file is a template or malformed,
or a marker is broken. Standard library only.
"""

import argparse
import json
import re
import sys
from pathlib import Path

CONTRACT_KEYS = ["exit", "reactive", "maker", "morphoFactory", "token", "callbackProxy"]
VALUE_KEYS = ["VAULT_TIMELOCK", "LEAD", "MAX_WAIT", "CALLBACK_GAS", "MAX_ACTIVE", "MAX_REACTIONS", "MAX_TIMED",
              "ARMS_PER_ADDRESS_PER_DAY", "ARMS_PER_DAY", "TIMED_ARMS_PER_DAY", "LIFETIME"]
ADDRESS = re.compile(r"^0x[0-9a-fA-F]{40}$")
BLOCK = re.compile(r"(<!-- stamp:([a-z]+) -->\n)(.*?)(<!-- /stamp:([a-z]+) -->)", re.S)
OPEN = re.compile(r"<!-- stamp:([a-z]+) -->")
CLOSE = re.compile(r"<!-- /stamp:([a-z]+) -->")
BASE_EXPLORER = "https://base-sepolia.blockscout.com/address/"
LASNA_EXPLORER = "https://lasna.reactscan.net/address/"
MARKDOWN_TARGETS = ["README.md", "SPEC.md"]
JS_TARGET = "docs/data/deployment.js"


class StampError(Exception):
    pass


def load(path):
    try:
        doc = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        raise StampError(f"cannot read {path}: {e}")
    if doc.get("status") != "deployed":
        raise StampError(f"{path} is not a filled deployment (status {doc.get('status')!r}); nothing to stamp")
    contracts = doc.get("contracts") or {}
    for k in CONTRACT_KEYS:
        if not isinstance(contracts.get(k), str) or not ADDRESS.match(contracts[k]):
            raise StampError(f"{path}: contracts.{k} is not an address: {contracts.get(k)!r}")
    values = doc.get("values") or {}
    for k in VALUE_KEYS:
        if not isinstance(values.get(k), int) or isinstance(values.get(k), bool):
            raise StampError(f"{path}: values.{k} is not a whole number: {values.get(k)!r}")
    return doc


def _link(address, explorer):
    return f"[`{address}`]({explorer}{address})"


def render_contracts(doc):
    c = doc["contracts"]
    origin = f"{doc['origin']['name']} ({doc['origin']['chainId']})"
    reactive = f"{doc['reactive']['name']} ({doc['reactive']['chainId']})"
    rows = [
        ("`NoticeExit`", origin, _link(c["exit"], BASE_EXPLORER)),
        ("`NoticeReactive`", reactive, _link(c["reactive"], LASNA_EXPLORER)),
        ("`MorphoVaultMaker` (ours; makes Morpho Vault V2s, the list of vaults `NoticeExit` accepts)", origin,
         _link(c["maker"], BASE_EXPLORER)),
        ("`VaultV2Factory` (Morpho's)", origin, _link(c["morphoFactory"], BASE_EXPLORER)),
        ("`DemoToken` (demo dollar, 6 decimals, test only)", origin, _link(c["token"], BASE_EXPLORER)),
        ("Callback proxy (Reactive's)", origin, _link(c["callbackProxy"], BASE_EXPLORER)),
    ]
    lines = ["| Contract | Chain | Address |", "|---|---|---|"]
    lines += [f"| {a} | {b} | {d} |" for a, b, d in rows]
    return "\n".join(lines) + "\n"


def render_values(doc):
    v = doc["values"]
    lines = ["| Value | Deployed |", "|---|---|"]
    lines += [f"| `{k}` | {v[k]} |" for k in VALUE_KEYS]
    lines.append(f"| Health float threshold (lREACT) | {doc.get('healthMinFloat')} |")
    return "\n".join(lines) + "\n"


RENDER = {"contracts": render_contracts, "values": render_values}


def render_js(doc, source_name):
    body = json.dumps(doc, indent=2, sort_keys=True)
    return (f"// Written by scripts/stamp.py from deployments/{source_name}; never edit by hand.\n"
            f"window.NP_DEPLOYMENT = {body};\n")


def stamp_markdown(text, doc, name):
    """Returns the text with every marked block regenerated. Raises StampError on a broken or unknown marker."""
    opens, closes = OPEN.findall(text), CLOSE.findall(text)
    if opens != closes:
        raise StampError(f"{name}: stamp markers do not pair up (open {opens}, close {closes})")
    blocks = BLOCK.findall(text)
    if len(blocks) != len(opens):
        raise StampError(f"{name}: a stamp marker is not on its own line or a block is nested")

    def repl(m):
        kind, end_kind = m.group(2), m.group(5)
        if kind != end_kind:
            raise StampError(f"{name}: block {kind} closed as {end_kind}")
        if kind not in RENDER:
            raise StampError(f"{name}: unknown stamp block {kind!r}")
        return m.group(1) + RENDER[kind](doc) + m.group(4)

    return BLOCK.sub(repl, text), len(blocks)


def run(root, deployment, check):
    doc = load(deployment)
    root = Path(root)
    planned = {JS_TARGET: render_js(doc, Path(deployment).name)}
    for name in MARKDOWN_TARGETS:
        p = root / name
        if not p.exists():
            print(f"{name}: not present, skipped")
            continue
        old = p.read_text(encoding="utf-8")
        new, n = stamp_markdown(old, doc, name)
        if n == 0:
            print(f"{name}: no stamp block, nothing to write")
            continue
        planned[name] = new
    differ = []
    for name, new in planned.items():
        p = root / name
        old = p.read_text(encoding="utf-8") if p.exists() else None
        if old == new:
            print(f"{name}: up to date")
            continue
        if check:
            differ.append(name)
            print(f"{name}: DIFFERS from {deployment} (hand edit inside a stamped block, or not stamped)")
        else:
            p.parent.mkdir(parents=True, exist_ok=True)
            with open(p, "w", encoding="utf-8", newline="\n") as f:
                f.write(new)
            print(f"{name}: written")
    return 1 if differ else 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("deployment", nargs="?", default=None)
    ap.add_argument("--root", default=str(Path(__file__).resolve().parent.parent))
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args(argv)
    deployment = a.deployment or str(Path(a.root) / "deployments" / "current.json")
    try:
        return run(a.root, deployment, a.check)
    except StampError as e:
        print(f"STOP: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
