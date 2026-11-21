"""Checks scripts/stamp.py on a scratch folder (standard library only, no network).

A stamp then --check passes; a hand edit inside a stamped block, or in docs/data/deployment.js, makes --check fail
(exit 1); an edit outside the blocks does not; a template deployment file, a broken marker and an unknown block stop
with exit 2 and write nothing.
"""

import json
import subprocess
import sys
import tempfile
from pathlib import Path

STAMP = Path(__file__).resolve().parent / "stamp.py"


def deployment(status="deployed"):
    a = lambda n: "0x" + f"{n:040x}"  # noqa: E731
    return {
        "name": "current",
        "status": status,
        "commit": "test",
        "origin": {"name": "Base Sepolia", "chainId": 84532},
        "reactive": {"name": "Reactive Lasna", "chainId": 5318007},
        "contracts": {"token": a(1), "maker": a(2), "morphoFactory": a(3), "reactive": a(4), "exit": a(5),
                      "callbackProxy": a(6)},
        "deployTxs": {},
        "smokeVault": {},
        "operators": [a(7)],
        "values": {"VAULT_TIMELOCK": 180, "LEAD": 120, "MAX_WAIT": 200, "CALLBACK_GAS": 600000, "MAX_ACTIVE": 1000,
                   "MAX_REACTIONS": 16, "MAX_TIMED": 8, "ARMS_PER_ADDRESS_PER_DAY": 4, "ARMS_PER_DAY": 50,
                   "TIMED_ARMS_PER_DAY": 4, "LIFETIME": 86400},
        "healthMinFloat": "4",
    }


README = """# Title

Text before.

<!-- stamp:contracts -->
old table
<!-- /stamp:contracts -->

Middle text.

<!-- stamp:values -->
<!-- /stamp:values -->

Text after.
"""

failures = []


def stamp(root, *args):
    r = subprocess.run([sys.executable, "-I", str(STAMP), "--root", str(root), *args,
                        str(root / "deployments" / "current.json")], capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def expect(label, got, want, out=""):
    ok = got == want
    print(f"{'ok  ' if ok else 'FAIL'} {label}: exit {got}, expected {want}")
    if not ok:
        failures.append(label)
        print(out)


def fresh(tmp, doc=None, readme=README):
    root = Path(tempfile.mkdtemp(dir=tmp))
    (root / "deployments").mkdir()
    (root / "deployments" / "current.json").write_text(json.dumps(doc or deployment()), encoding="utf-8")
    (root / "README.md").write_text(readme, encoding="utf-8", newline="\n")
    (root / "SPEC.md").write_text("# Spec without stamp blocks\n", encoding="utf-8", newline="\n")
    return root


with tempfile.TemporaryDirectory() as tmp:
    root = fresh(tmp)
    rc, out = stamp(root)
    expect("first stamp writes", rc, 0, out)
    text = (root / "README.md").read_text(encoding="utf-8")
    expect("table written inside the block", int("old table" in text or "0x" + "5".rjust(40, "0") not in text), 0)
    expect("text outside the blocks kept", int(not ("Middle text." in text and "Text after." in text)), 0)
    expect("SPEC.md without blocks untouched",
           int((root / "SPEC.md").read_text(encoding="utf-8") != "# Spec without stamp blocks\n"), 0)
    rc, out = stamp(root, "--check")
    expect("check after stamp passes", rc, 0, out)

    readme = root / "README.md"
    good = readme.read_text(encoding="utf-8")
    readme.write_text(good.replace("| `LEAD` | 120 |", "| `LEAD` | 60 |"), encoding="utf-8", newline="\n")
    rc, out = stamp(root, "--check")
    expect("hand edit inside a block fails the check", rc, 1, out)
    readme.write_text(good.replace("Middle text.", "Middle text, edited."), encoding="utf-8", newline="\n")
    rc, out = stamp(root, "--check")
    expect("edit outside the blocks passes the check", rc, 0, out)
    readme.write_text(good, encoding="utf-8", newline="\n")

    js = root / "docs" / "data" / "deployment.js"
    good_js = js.read_text(encoding="utf-8")
    js.write_text(good_js.replace('"LEAD": 120', '"LEAD": 60'), encoding="utf-8", newline="\n")
    rc, out = stamp(root, "--check")
    expect("hand edit of deployment.js fails the check", rc, 1, out)
    js.write_text(good_js, encoding="utf-8", newline="\n")

    doc = deployment()
    doc["values"]["LEAD"] = 90
    (root / "deployments" / "current.json").write_text(json.dumps(doc), encoding="utf-8")
    rc, out = stamp(root, "--check")
    expect("deployment file changed without a stamp fails the check", rc, 1, out)

    t = deployment(status="template")
    t["contracts"]["exit"] = None
    root2 = fresh(tmp, doc=t)
    rc, out = stamp(root2)
    expect("template refused", rc, 2, out)
    expect("template writes nothing", int((root2 / "docs").exists()), 0)

    root3 = fresh(tmp, readme="<!-- stamp:contracts -->\nno end\n")
    rc, out = stamp(root3)
    expect("unclosed marker refused", rc, 2, out)
    root4 = fresh(tmp, readme="<!-- stamp:prices -->\nx\n<!-- /stamp:prices -->\n")
    rc, out = stamp(root4)
    expect("unknown block refused", rc, 2, out)
    expect("refusal writes nothing", int((root4 / "docs").exists()), 0)

    # Malformed deployment files stop with exit 2 (not a Python traceback, exit 1) and write nothing.
    no_origin = deployment()
    del no_origin["origin"]
    list_contracts = deployment()
    list_contracts["contracts"] = []
    malformed = [("a JSON list", "[]"), ("a JSON string", '"deployed"'), ("no origin", json.dumps(no_origin)),
                 ("contracts as a list", json.dumps(list_contracts))]
    for label, raw in malformed:
        r = fresh(tmp)
        (r / "deployments" / "current.json").write_text(raw, encoding="utf-8")
        rc, out = stamp(r)
        expect(f"{label} refused", rc, 2, out)
        expect(f"{label} writes nothing", int((r / "docs").exists()), 0)

if failures:
    sys.exit(f"{len(failures)} stamp check(s) failed: {failures}")
print("stamp checks passed")
