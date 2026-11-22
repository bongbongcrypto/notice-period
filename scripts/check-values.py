#!/usr/bin/env python3
"""Text check that the deployed values in scripts/deploy-system.sh match the tests that claim to use them (standard
library; run by the ci.yml workflow-checks step). Exit 1 on any mismatch, and on any value that is missing or
written more than once on either side, so a rename can never switch the check off.

    python3 scripts/check-values.py [--root DIR]

Compared (deploy-system.sh name -> file: name):
  test/utils/NoticeSetup.sol      the constants every test inherits that are meant to be the deployed ones:
                                  VAULT_TIMELOCK -> TIMELOCK (the maker's waiting period), LEAD, CALLBACK_GAS -> CB_GAS,
                                  LIFETIME. Its other caps are small test values on purpose and are not compared.
  test/DeployedValues.t.sol       the cfg* assignments of setUp: MAX_WAIT, MAX_REACTIONS, MAX_ACTIVE, the arm caps.
  fork/RealVault.fork.t.sol       its constants: LEAD, MAX_WAIT, MAX_ACTIVE, MAX_REACTIONS, the arm caps, LIFETIME,
                                  CB_GAS.
"""

import argparse
import re
import sys
from pathlib import Path

UNITS = {"": 1, "seconds": 1, "minutes": 60, "hours": 3600, "days": 86400, "weeks": 604800}

# (deploy-system.sh name, file, kind, name in that file); kind "const" = `constant NAME = N;`, "cfg" = `NAME = N;`.
PAIRS = [
    ("VAULT_TIMELOCK", "test/utils/NoticeSetup.sol", "const", "TIMELOCK"),
    ("LEAD", "test/utils/NoticeSetup.sol", "const", "LEAD"),
    ("CALLBACK_GAS", "test/utils/NoticeSetup.sol", "const", "CB_GAS"),
    ("LIFETIME", "test/utils/NoticeSetup.sol", "const", "LIFETIME"),
    ("MAX_WAIT", "test/DeployedValues.t.sol", "cfg", "cfgMaxWait"),
    ("MAX_REACTIONS", "test/DeployedValues.t.sol", "cfg", "cfgMaxReactions"),
    ("MAX_ACTIVE", "test/DeployedValues.t.sol", "cfg", "cfgMaxActive"),
    ("ARMS_PER_ADDRESS_PER_DAY", "test/DeployedValues.t.sol", "cfg", "cfgPerAddress"),
    ("ARMS_PER_DAY", "test/DeployedValues.t.sol", "cfg", "cfgPerDay"),
    ("TIMED_ARMS_PER_DAY", "test/DeployedValues.t.sol", "cfg", "cfgTimedPerDay"),
    ("LEAD", "fork/RealVault.fork.t.sol", "const", "LEAD"),
    ("MAX_WAIT", "fork/RealVault.fork.t.sol", "const", "MAX_WAIT"),
    ("MAX_ACTIVE", "fork/RealVault.fork.t.sol", "const", "MAX_ACTIVE"),
    ("MAX_REACTIONS", "fork/RealVault.fork.t.sol", "const", "MAX_REACTIONS"),
    ("ARMS_PER_ADDRESS_PER_DAY", "fork/RealVault.fork.t.sol", "const", "PER_ADDRESS"),
    ("ARMS_PER_DAY", "fork/RealVault.fork.t.sol", "const", "PER_DAY"),
    ("TIMED_ARMS_PER_DAY", "fork/RealVault.fork.t.sol", "const", "TIMED_PER_DAY"),
    ("LIFETIME", "fork/RealVault.fork.t.sol", "const", "LIFETIME"),
    ("CALLBACK_GAS", "fork/RealVault.fork.t.sol", "const", "CB_GAS"),
]

findings = []


def find(msg):
    findings.append(msg)
    print("FAIL " + msg)


def strip_comments(text):
    return re.sub(r"/\*.*?\*/", "", re.sub(r"//[^\n]*", "", text), flags=re.S)


def one(matches, where):
    """The single value of a name, or None (and a finding) when it is missing or written more than once."""
    if len(matches) != 1:
        find(f"{where}: found {len(matches)} times, expected exactly once")
        return None
    return matches[0]


def sh_value(text, name):
    found = re.findall(r"^" + re.escape(name) + r"=([0-9]+)(?:\s|$)", text, re.M)
    v = one(found, f"scripts/deploy-system.sh {name}=")
    return None if v is None else int(v)


def sol_value(text, kind, name, where):
    num = r"([0-9][0-9_]*)\s*(seconds|minutes|hours|days|weeks)?"
    if kind == "const":
        pat = r"\bconstant\s+" + re.escape(name) + r"\s*=\s*" + num + r"\s*;"
    else:
        pat = r"(?<![\w.])" + re.escape(name) + r"\s*=\s*" + num + r"\s*;"
    found = re.findall(pat, strip_comments(text))
    v = one(found, f"{where} {name}")
    if v is None:
        return None
    return int(v[0].replace("_", "")) * UNITS[v[1] or ""]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", default=str(Path(__file__).resolve().parent.parent))
    root = Path(ap.parse_args(argv).root)
    try:
        sh = (root / "scripts" / "deploy-system.sh").read_text(encoding="utf-8")
        files = {f: (root / f).read_text(encoding="utf-8") for f in sorted({p[1] for p in PAIRS})}
    except OSError as e:
        print(f"FAIL cannot read: {e}")
        return 1
    checked = 0
    for sh_name, f, kind, name in PAIRS:
        want = sh_value(sh, sh_name)
        got = sol_value(files[f], kind, name, f)
        if want is None or got is None:
            continue
        if want != got:
            find(f"{f} {name} = {got}, but scripts/deploy-system.sh deploys {sh_name}={want}")
        else:
            checked += 1
    if findings:
        print(f"{len(findings)} value check(s) failed")
        return 1
    print(f"value checks passed ({checked} pairs: deploy-system.sh against NoticeSetup, DeployedValues, the fork test)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
