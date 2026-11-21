#!/usr/bin/env python3
"""Reads one deployment file, deployments/<name>.json, the only hand-edited place for addresses.

    python3 scripts/deployment.py NAME [--github-output] [--env]

Checks the name, the status ("deployed"), every address, and prints the loop inputs. With --github-output the values
are also appended to $GITHUB_OUTPUT (token, factory, exit, reactive, factory_kind, health_min_float, source_commit);
with --env they are printed as NP_TOKEN=... lines. The vault source is `contracts.maker` (MorphoVaultMaker, factory
kind "maker") or `contracts.factory` (DemoVaultFactory, kind "demo"). Exit 2 on any problem. Standard library only.
"""

import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NAME = re.compile(r"^[0-9A-Za-z][0-9A-Za-z-]{0,40}$")
ADDRESS = re.compile(r"^0x[0-9a-fA-F]{40}$")


class DeploymentError(Exception):
    pass


def load(name, root=ROOT):
    if not NAME.match(name or ""):
        raise DeploymentError(f"deployment name {name!r}: letters, digits and dashes only")
    path = Path(root) / "deployments" / f"{name}.json"
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        raise DeploymentError(f"cannot read {path.name}: {e}")
    if doc.get("status") != "deployed":
        raise DeploymentError(f"{path.name} is not a filled deployment (status {doc.get('status')!r})")
    c = doc.get("contracts") or {}
    if c.get("maker"):
        factory, kind = c["maker"], "maker"
    elif c.get("factory"):
        factory, kind = c["factory"], "demo"
    else:
        raise DeploymentError(f"{path.name}: neither contracts.maker nor contracts.factory")
    out = {"token": c.get("token"), "factory": factory, "exit": c.get("exit"), "reactive": c.get("reactive"),
           "factory_kind": kind}
    for k in ("token", "factory", "exit", "reactive"):
        if not isinstance(out[k], str) or not ADDRESS.match(out[k]):
            raise DeploymentError(f"{path.name}: {k} is not an address: {out[k]!r}")
    if doc.get("registryKind") not in (None, kind):
        raise DeploymentError(f"{path.name}: registryKind {doc.get('registryKind')!r} but the vault source is {kind}")
    hmf = str(doc.get("healthMinFloat", ""))
    if not re.match(r"^[0-9]+(\.[0-9]{1,18})?$", hmf):
        raise DeploymentError(f"{path.name}: healthMinFloat {hmf!r} is not a decimal number")
    out["health_min_float"] = hmf
    out["source_commit"] = doc.get("sourceCommit") or doc.get("commit") or ""
    return doc, out


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    if len(args) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        _, out = load(args[0])
    except DeploymentError as e:
        print(f"STOP: {e}", file=sys.stderr)
        return 2
    for k, v in out.items():
        print(f"{k}={v}")
    if "--github-output" in argv and os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as f:
            for k, v in out.items():
                f.write(f"{k}={v}\n")
    if "--env" in argv:
        for k, env in (("token", "NP_TOKEN"), ("factory", "NP_FACTORY"), ("exit", "NP_EXIT"),
                       ("reactive", "NP_REACTIVE"), ("factory_kind", "LOOP_FACTORY_KIND"),
                       ("health_min_float", "HEALTH_MIN_FLOAT")):
            print(f"{env}={out[k]}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
