#!/usr/bin/env python3
"""Mutation check: every refusal rule must be guarded by a named test.

For each entry of scripts/mutations.py:
  1. the `old` text occurs exactly once in its file;
  2. the named test passes on the unmutated code (one baseline run of the whole suite);
  3. with the rule removed the code still compiles, and the named test runs and FAILS;
  4. the file is restored byte for byte.
The run ends with `git diff --exit-code` on src/ so a mutant can never be left behind.

Usage: python3 scripts/mutate.py [--list] [--only ID[,ID...]]
Runs forge with FOUNDRY_PROFILE=mutation unless the caller set another profile.
"""

import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
from mutations import MUTATIONS  # noqa: E402


def sh(args, check=False):
    p = subprocess.run(args, cwd=ROOT, capture_output=True, text=True)
    if check and p.returncode != 0:
        sys.stdout.write(p.stdout[-4000:])
        sys.stderr.write(p.stderr[-4000:])
        raise SystemExit(f"command failed: {' '.join(args)}")
    return p


def forge_json(args):
    """Runs `forge test --json ...` and returns (exit code, parsed results or None)."""
    p = sh(["forge", "test", "--json", *args])
    data = None
    for line in reversed(p.stdout.splitlines()):
        line = line.strip()
        if line.startswith("{"):
            try:
                data = json.loads(line)
                break
            except json.JSONDecodeError:
                continue
    return p, data


def status_of(results, contract, test):
    """Status of `contract.test` in forge JSON results: 'Success', 'Failure', or None if it did not run."""
    if not results:
        return None
    for suite, body in results.items():
        if suite.split(":")[-1] != contract:
            continue
        for name, r in body.get("test_results", {}).items():
            if name.split("(")[0] == test:
                return r.get("status")
    return None


def read(path):
    with open(os.path.join(ROOT, path), "rb") as f:
        return f.read()


def write(path, data):
    with open(os.path.join(ROOT, path), "wb") as f:
        f.write(data)


def main():
    os.environ.setdefault("FOUNDRY_PROFILE", "mutation")
    only = None
    if "--only" in sys.argv:
        only = set(sys.argv[sys.argv.index("--only") + 1].split(","))
    selected = [m for m in MUTATIONS if only is None or m["id"] in only]
    if "--list" in sys.argv:
        for m in selected:
            print(f"{m['id']:40} {m['contract']}.{m['test']}  ({m['rule']})")
        return 0

    ids = [m["id"] for m in MUTATIONS]
    if len(ids) != len(set(ids)):
        raise SystemExit("duplicate mutation id")

    # 1. anchors
    problems = []
    for m in selected:
        n = read(m["file"]).decode("utf-8").count(m["old"])
        if n != 1:
            problems.append(f"{m['id']}: old text found {n} times in {m['file']}")
    if problems:
        print("\n".join(problems))
        raise SystemExit("mutation anchors drifted from the code")

    # 2. baseline
    sh(["forge", "build"], check=True)
    p, base = forge_json([])
    if base is None:
        sys.stdout.write(p.stdout[-4000:])
        raise SystemExit("could not read the baseline test results")
    for m in selected:
        s = status_of(base, m["contract"], m["test"])
        if s != "Success":
            problems.append(f"{m['id']}: named test {m['contract']}.{m['test']} is {s} on the real code")
    if problems:
        print("\n".join(problems))
        raise SystemExit("baseline: a named test does not pass")
    print(f"baseline: {len(selected)} named tests pass on the real code")

    # 3. mutants
    survivors, broken = [], []
    for i, m in enumerate(selected, 1):
        original = read(m["file"])
        text = original.decode("utf-8")
        mutant = text.replace(m["old"], m["new"], 1)
        t0 = time.time()
        try:
            write(m["file"], mutant.encode("utf-8"))
            b = sh(["forge", "build"])
            if b.returncode != 0:
                broken.append(m["id"])
                verdict = "MUTANT DOES NOT COMPILE"
                tail = (b.stdout + b.stderr)[-1500:]
            else:
                pt, res = forge_json(["--match-contract", f"^{m['contract']}$", "--match-test", f"^{m['test']}$"])
                s = status_of(res, m["contract"], m["test"])
                if s == "Failure":
                    verdict = "killed"
                    tail = ""
                else:
                    survivors.append(m["id"])
                    verdict = f"SURVIVED (named test status: {s})"
                    tail = pt.stdout[-1500:]
        finally:
            write(m["file"], original)
        print(f"[{i:2}/{len(selected)}] {m['id']:40} {verdict:12} {time.time() - t0:5.1f}s  {m['rule']}")
        if tail:
            print(tail)

    # 4. restored
    d = sh(["git", "diff", "--exit-code", "--stat", "--", "src", "test"])
    if d.returncode != 0:
        sys.stdout.write(d.stdout)
        raise SystemExit("a mutant was left in the tree")

    print(f"\n{len(selected) - len(survivors) - len(broken)} of {len(selected)} mutants killed")
    if survivors or broken:
        print("survived:", ", ".join(survivors) or "-")
        print("did not compile:", ", ".join(broken) or "-")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
