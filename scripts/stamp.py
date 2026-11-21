"""Writes the deployment's addresses and values into the places that show them, from one deployment file.

    python3 scripts/stamp.py [--check] [--root DIR] [DEPLOYMENT_JSON]

Without DEPLOYMENT_JSON: the file named in docs/data/deployment.js (the one the page shows now), else
deployments/current.json.

The deployment file is the only hand-edited place for addresses. From it this script
writes docs/data/deployment.js (window.NP_DEPLOYMENT, the part the page needs) and every marked block of README.md,
SPEC.md and docs/index.html:

    <!-- stamp:contracts -->   ...generated, never edited by hand...   <!-- /stamp:contracts -->
    <!-- stamp:values -->      ...                                     <!-- /stamp:values -->
    <!-- stamp:pagecontracts -->, <!-- stamp:demolimits -->           (docs/index.html)

Two shapes of deployment file are accepted: a vault maker (contracts.maker and contracts.morphoFactory: Morpho
Vault V2s, the redeploy) or a demo factory (contracts.factory: our own demo vault, the 18 Nov 2026 deployment).
MAX_TIMED and TIMED_ARMS_PER_DAY exist only in the contracts of the redeploy; when absent they are stamped as none.
The page's rules follow from the file: `rules.vaultSource` (default: maker or demo, from the contracts) and
`rules.leaveNowExpires` (default: true when TIMED_ARMS_PER_DAY is absent, since only the redeploy refuses to expire
a "leave now" watch).

--check writes nothing and exits 1 if any of those places differs from what the deployment file gives (a hand edit
inside a block, or a deployment file changed without a stamp). Exit 2: the deployment file is a template or malformed,
or a marker is broken. Standard library only.
"""

import argparse
import json
import re
import sys
from pathlib import Path

CONTRACT_KEYS = ["exit", "reactive", "token", "callbackProxy"]
SHAPES = {"maker": ["maker", "morphoFactory"], "demo": ["factory"]}
VALUE_KEYS = ["VAULT_TIMELOCK", "LEAD", "MAX_WAIT", "CALLBACK_GAS", "MAX_ACTIVE", "MAX_REACTIONS", "MAX_TIMED",
              "ARMS_PER_ADDRESS_PER_DAY", "ARMS_PER_DAY", "TIMED_ARMS_PER_DAY", "LIFETIME"]
OPTIONAL_VALUES = {"MAX_TIMED", "TIMED_ARMS_PER_DAY"}
PAGE_KEYS = ["name", "origin", "reactive", "contracts", "operators", "values", "rules", "healthMinFloat"]
ADDRESS = re.compile(r"^0x[0-9a-fA-F]{40}$")
BLOCK = re.compile(r"(<!-- stamp:([a-z]+) -->\n)(.*?)(<!-- /stamp:([a-z]+) -->)", re.S)
OPEN = re.compile(r"<!-- stamp:([a-z]+) -->")
CLOSE = re.compile(r"<!-- /stamp:([a-z]+) -->")
BASE_EXPLORER = "https://base-sepolia.blockscout.com/address/"
LASNA_EXPLORER = "https://lasna.reactscan.net/address/"
MARKDOWN_TARGETS = ["README.md", "SPEC.md", "docs/index.html"]
JS_TARGET = "docs/data/deployment.js"


class StampError(Exception):
    pass


def load(path):
    try:
        doc = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        raise StampError(f"cannot read {path}: {e}")
    if not isinstance(doc, dict):
        raise StampError(f"{path}: not a JSON object")
    if doc.get("status") != "deployed":
        raise StampError(f"{path} is not a filled deployment (status {doc.get('status')!r}); nothing to stamp")
    for side in ("origin", "reactive"):
        chain = doc.get(side)
        if (not isinstance(chain, dict) or not isinstance(chain.get("name"), str)
                or not isinstance(chain.get("chainId"), int) or isinstance(chain.get("chainId"), bool)):
            raise StampError(f"{path}: {side} needs a name and a whole-number chainId: {chain!r}")
    for part, kind in (("contracts", dict), ("values", dict), ("rules", dict), ("operators", list)):
        if not isinstance(doc.get(part) or kind(), kind):
            raise StampError(f"{path}: {part} is not a JSON {'object' if kind is dict else 'list'}")
    contracts = doc.get("contracts") or {}
    shape = "maker" if contracts.get("maker") else "demo"
    for k in CONTRACT_KEYS + SHAPES[shape]:
        if not isinstance(contracts.get(k), str) or not ADDRESS.match(contracts[k]):
            raise StampError(f"{path}: contracts.{k} is not an address: {contracts.get(k)!r}")
    if shape == "maker" and contracts.get("factory"):
        raise StampError(f"{path}: both contracts.maker and contracts.factory; one vault source per deployment")
    values = doc.get("values") or {}
    for k in VALUE_KEYS:
        v = values.get(k)
        if v is None and k in OPTIONAL_VALUES:
            continue
        if not isinstance(v, int) or isinstance(v, bool):
            raise StampError(f"{path}: values.{k} is not a whole number: {v!r}")
    ops = doc.get("operators") or []
    if not ops or any(not isinstance(a, str) or not ADDRESS.match(a) for a in ops):
        raise StampError(f"{path}: operators must list our own accounts (addresses)")
    rules = dict(doc.get("rules") or {})
    rules.setdefault("vaultSource", shape)
    if rules["vaultSource"] != shape:
        raise StampError(f"{path}: rules.vaultSource {rules['vaultSource']!r} but the contracts are of a {shape} deployment")
    rules.setdefault("leaveNowExpires", values.get("TIMED_ARMS_PER_DAY") is None)
    if not isinstance(rules["leaveNowExpires"], bool):
        raise StampError(f"{path}: rules.leaveNowExpires must be true or false")
    doc = dict(doc)
    doc["rules"] = rules
    doc["shape"] = shape
    return doc


def _link(address, explorer):
    return f"[`{address}`]({explorer}{address})"


def vault_rows(doc):
    c = doc["contracts"]
    if doc["shape"] == "maker":
        return [("`MorphoVaultMaker` (ours; makes Morpho Vault V2s, the list of vaults `NoticeExit` accepts)",
                 "Vault maker", c["maker"]),
                ("`VaultV2Factory` (Morpho's)", "Morpho Vault V2 factory", c["morphoFactory"])]
    return [("`DemoVaultFactory` (ours; makes the demo vaults, the list of vaults `NoticeExit` accepts)",
             "Demo vault factory", c["factory"])]


def render_contracts(doc):
    c = doc["contracts"]
    origin = f"{doc['origin']['name']} ({doc['origin']['chainId']})"
    reactive = f"{doc['reactive']['name']} ({doc['reactive']['chainId']})"
    rows = [
        ("`NoticeExit`", origin, _link(c["exit"], BASE_EXPLORER)),
        ("`NoticeReactive`", reactive, _link(c["reactive"], LASNA_EXPLORER)),
    ]
    rows += [(md, origin, _link(addr, BASE_EXPLORER)) for md, _, addr in vault_rows(doc)]
    rows += [
        ("`DemoToken` (demo dollar, 6 decimals, test only)", origin, _link(c["token"], BASE_EXPLORER)),
        ("Callback proxy (Reactive's)", origin, _link(c["callbackProxy"], BASE_EXPLORER)),
    ]
    lines = ["| Contract | Chain | Address |", "|---|---|---|"]
    lines += [f"| {a} | {b} | {d} |" for a, b, d in rows]
    return "\n".join(lines) + "\n"


def render_values(doc):
    v = doc["values"]
    lines = ["| Value | Deployed |", "|---|---|"]
    lines += [f"| `{k}` | {'none (not in these contracts)' if v.get(k) is None else v[k]} |" for k in VALUE_KEYS]
    lines.append(f"| Health float threshold (lREACT) | {doc.get('healthMinFloat')} |")
    return "\n".join(lines) + "\n"


def _html_addr(label, chain, address, explorer):
    return (f'      <tr><th scope="row">{label} <span class="quiet">{chain}</span></th><td><a class="addr" '
            f'href="{explorer}{address}" rel="noopener noreferrer">{address}</a></td></tr>')


MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]


def deployed_on(doc):
    m = re.match(r"^(\d{4})-(\d{2})-(\d{2})$", str(doc.get("name", "")))
    return f"{int(m.group(3))} {MONTHS[int(m.group(2)) - 1]} {m.group(1)}" if m else str(doc.get("name", ""))


def render_pagecontracts(doc):
    c = doc["contracts"]
    o, r = doc["origin"]["name"], doc["reactive"]["name"]
    rows = [_html_addr("Exit contract", o, c["exit"], BASE_EXPLORER),
            _html_addr("Reactive contract", r, c["reactive"], LASNA_EXPLORER)]
    rows += [_html_addr(label, o, addr, BASE_EXPLORER) for _, label, addr in vault_rows(doc)]
    rows.append(_html_addr("Demo dollar", o, c["token"], BASE_EXPLORER))
    return (f"    <caption>Contracts of the {deployed_on(doc)} testnet deployment</caption>\n    <tbody>\n"
            + "\n".join(rows) + "\n    </tbody>\n")


def lifetime_text(seconds):
    if seconds % 86400 == 0:
        d = seconds // 86400
        return "one day" if d == 1 else f"{d} days"
    if seconds % 3600 == 0:
        return f"{seconds // 3600} hours"
    return f"{seconds} seconds"


def render_demolimits(doc):
    rules, life = doc["rules"], lifetime_text(doc["values"]["LIFETIME"])
    if rules["vaultSource"] == "maker":
        vault = ("Each vault is a real Morpho Vault V2, made for you by our maker contract on Base Sepolia; the dollars "
                 "are ours and have no value.")
    else:
        vault = "The vault and the dollars are ours; the vault copies the events of Morpho Vault V2."
    if rules["leaveNowExpires"]:
        lease = f"A watch lasts {life} in this demo."
    else:
        lease = (f"A &ldquo;leave now&rdquo; watch stays on until it exits or you turn it off; a timer watch lasts "
                 f"{life}.")
    items = ["Test networks only.", vault, lease, "A change with no waiting period leaves no time to exit."]
    return "".join(f"        <li>{x}</li>\n" for x in items)


RENDER = {"contracts": render_contracts, "values": render_values, "pagecontracts": render_pagecontracts,
          "demolimits": render_demolimits}


def render_js(doc, source_name):
    page = {k: doc[k] for k in PAGE_KEYS if k in doc}
    body = json.dumps(page, indent=2, sort_keys=True)
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
    deployment = a.deployment
    if not deployment:
        # The page shows the deployment named in its stamped file; without one, deployments/current.json.
        js = Path(a.root) / JS_TARGET
        m = re.search(r"from deployments/([0-9A-Za-z-]+\.json);", js.read_text(encoding="utf-8")) if js.exists() else None
        deployment = str(Path(a.root) / "deployments" / (m.group(1) if m else "current.json"))
    try:
        return run(a.root, deployment, a.check)
    except StampError as e:
        print(f"STOP: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
