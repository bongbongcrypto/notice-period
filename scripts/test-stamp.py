"""Checks scripts/stamp.py on a scratch folder (standard library only, no network).

A stamp then --check passes; a hand edit inside a stamped block, or in docs/data/deployment.js, makes --check fail
(exit 1); an edit outside the blocks does not; no deployment file given, a template deployment file, a broken marker
and an unknown block stop with exit 2 and write nothing. Both shapes of deployment (vault maker, demo factory) stamp
the page blocks of docs/index.html with their own words; operators and rules are checked.
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
    list_rules = deployment()
    list_rules["rules"] = ["maker"]
    false_values = deployment()
    false_values["values"] = False
    malformed = [("a JSON list", "[]"), ("a JSON string", '"deployed"'), ("no origin", json.dumps(no_origin)),
                 ("contracts as a list", json.dumps(list_contracts)), ("rules as a list", json.dumps(list_rules)),
                 ("values as false", json.dumps(false_values))]
    for label, raw in malformed:
        r = fresh(tmp)
        (r / "deployments" / "current.json").write_text(raw, encoding="utf-8")
        rc, out = stamp(r)
        expect(f"{label} refused", rc, 2, out)
        if label in ("contracts as a list", "values as false"):  # an empty or false part is not taken for {}
            expect(f"{label} named as not an object", int("is not a JSON object" in out), 1, out)
        expect(f"{label} writes nothing", int((r / "docs").exists()), 0)

    # No deployment file given: there is no default file, so nothing is written.
    r = fresh(tmp)
    res = subprocess.run([sys.executable, "-I", str(STAMP), "--root", str(r)], capture_output=True, text=True)
    expect("no deployment file given refused", res.returncode, 2, res.stdout + res.stderr)
    expect("no deployment file given writes nothing", int((r / "docs").exists()), 0)

    page = ("<footer>\n  <table>\n<!-- stamp:pagecontracts -->\nold\n<!-- /stamp:pagecontracts -->\n  </table>\n"
            "<ul>\n<!-- stamp:demolimits -->\n<!-- /stamp:demolimits -->\n</ul>\n</footer>\n")

    # The demo-factory shape (the 18 Nov 2026 deployment): no maker, no timer values, leave-now watches expire.
    def demo_doc():
        d = deployment()
        d["name"] = "2026-11-18"
        d["contracts"].pop("maker")
        d["contracts"].pop("morphoFactory")
        d["contracts"]["factory"] = "0x" + "8".rjust(40, "0")
        d["values"].pop("MAX_TIMED")
        d["values"].pop("TIMED_ARMS_PER_DAY")
        return d

    root5 = fresh(tmp, doc=demo_doc())
    (root5 / "docs").mkdir()
    (root5 / "docs" / "index.html").write_text(page, encoding="utf-8", newline="\n")
    rc, out = stamp(root5)
    expect("demo-factory shape stamps", rc, 0, out)
    html = (root5 / "docs" / "index.html").read_text(encoding="utf-8")
    js5 = (root5 / "docs" / "data" / "deployment.js").read_text(encoding="utf-8")
    readme5 = (root5 / "README.md").read_text(encoding="utf-8")
    expect("demo shape: page lists the demo vault factory, not a maker",
           int(not ("Demo vault factory" in html and "Vault maker" not in html and "0x" + "8".rjust(40, "0") in html)), 0)
    expect("demo shape: caption dated from the deployment name", int("Contracts of the 18 Nov 2026 testnet" not in html), 0)
    expect("demo shape: a watch lasts one day", int("A watch lasts one day in this demo." not in html), 0)
    expect("demo shape: timer values stamped as none", int("| `MAX_TIMED` | none" not in readme5), 0)
    expect("demo shape: rules in deployment.js",
           int('"leaveNowExpires": true' not in js5 or '"vaultSource": "demo"' not in js5), 0)
    expect("deployment.js carries no transaction lists", int("deployTxs" in js5 or "smokeVault" in js5), 0)
    rc, out = stamp(root5, "--check")
    expect("demo shape: check after stamp passes", rc, 0, out)
    good_html = html
    (root5 / "docs" / "index.html").write_text(html.replace("one day", "one week"), encoding="utf-8", newline="\n")
    rc, out = stamp(root5, "--check")
    expect("hand edit inside a page block fails the check", rc, 1, out)
    (root5 / "docs" / "index.html").write_text(good_html, encoding="utf-8", newline="\n")

    # The maker shape (Morpho Vault V2s made through our maker): the words follow the deployment's values.
    maker = deployment()
    maker["name"] = "2026-11-22"
    maker["rules"] = {"leaveNowExpires": False, "timedCap": 8, "timedArmsPerDay": 4, "vaultSource": "maker"}
    root6 = fresh(tmp, doc=maker)
    (root6 / "docs").mkdir()
    (root6 / "docs" / "index.html").write_text(page, encoding="utf-8", newline="\n")
    rc, out = stamp(root6)
    expect("maker shape stamps", rc, 0, out)
    html6 = (root6 / "docs" / "index.html").read_text(encoding="utf-8")
    js6 = (root6 / "docs" / "data" / "deployment.js").read_text(encoding="utf-8")
    expect("maker shape: page lists the maker and Morpho's factory",
           int(not ("Vault maker (ours)" in html6 and "Morpho&rsquo;s Vault V2 factory" in html6
                    and "Demo vault factory" not in html6 and "Demo dollar (ours)" in html6)), 0)
    expect("maker shape: the vault is Morpho's, made through our maker",
           int("real Morpho Vault V2, made by Morpho&rsquo;s own factory through our maker" not in html6), 0)
    expect("maker shape: a leave-now watch does not expire, a timer watch can be ended after the lifetime",
           int("watch does not expire" not in html6 or "can be ended by anyone one day after" not in html6), 0)
    expect("maker shape: the float and the three-per-vault limit stand next to it",
           int("only the first three watches are served" not in html6 or "only while our float" not in html6), 0)
    expect("maker shape: waiting period and caps from the values",
           int("waits 180 seconds" not in html6 or "4 per address, 50 for everyone" not in html6
               or "8 at a time and 4 new a day" not in html6), 0)
    expect("maker shape: our accounts in deployment.js", int("0x" + "7".rjust(40, "0") not in js6), 0)
    maker2 = json.loads(json.dumps(maker))
    maker2["values"]["VAULT_TIMELOCK"] = 600
    maker2["values"]["ARMS_PER_DAY"] = 20
    (root6 / "deployments" / "current.json").write_text(json.dumps(maker2), encoding="utf-8")
    rc, out = stamp(root6, "--check")
    expect("maker shape: new values without a stamp fail the check", rc, 1, out)
    rc, out = stamp(root6)
    html6b = (root6 / "docs" / "index.html").read_text(encoding="utf-8")
    expect("maker shape: restamped words follow the new values",
           int("waits 600 seconds" not in html6b or "4 per address, 20 for everyone" not in html6b), 0)

    both = deployment()
    both["contracts"]["factory"] = "0x" + "9".rjust(40, "0")
    rc, out = stamp(fresh(tmp, doc=both))
    expect("maker and factory together refused", rc, 2, out)
    noops = deployment()
    noops["operators"] = []
    rc, out = stamp(fresh(tmp, doc=noops))
    expect("a deployment without operators refused", rc, 2, out)
    badop = deployment()
    badop["operators"] = ["0x1234"]
    rc, out = stamp(fresh(tmp, doc=badop))
    expect("an operator that is not an address refused", rc, 2, out)
    wrong = demo_doc()
    wrong["rules"] = {"vaultSource": "maker"}
    rc, out = stamp(fresh(tmp, doc=wrong))
    expect("rules.vaultSource that contradicts the contracts refused", rc, 2, out)
    skew = deployment()
    skew["rules"] = {"timedCap": 3}
    rc, out = stamp(fresh(tmp, doc=skew))
    expect("rules.timedCap that differs from values.MAX_TIMED refused", rc, 2, out)
    flag = deployment()
    flag["rules"] = {"leaveNowExpires": "no"}
    rc, out = stamp(fresh(tmp, doc=flag))
    expect("rules.leaveNowExpires that is not true or false refused", rc, 2, out)

if failures:
    sys.exit(f"{len(failures)} stamp check(s) failed: {failures}")
print("stamp checks passed")
