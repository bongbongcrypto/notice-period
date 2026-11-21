#!/usr/bin/env python3
"""Sourcify v2 with the standard library (branch B of scripts/verify.sh; runs only with the owner's yes to publish).

    sourcify.py check  --chain ID --address ADDR
        exit 0 only if Sourcify reports an exact match (GET /v2/contract/{chain}/{address}).
    sourcify.py submit --build-dir DIR --chain ID --address ADDR --artifact path:Name --deployment NAME --key KEY
        builds the standard JSON input with `forge verify-contract --show-standard-json-input` inside DIR (the
        checkout of the source commit), reads the compiler version from the artifact's metadata, sends
        POST /v2/verify/{chain}/{address} with the creation transaction from the deployment file, and polls the job.

This sends our own source code to Sourcify, an outside site: verify.yml calls it only when its input publish is yes.
"""

import argparse
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

API = "https://sourcify.dev/server"
AGENT = "rpc-client"


def http(method, url, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Content-Type": "application/json", "User-Agent": AGENT})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"{}")
        except ValueError:
            return e.code, {}


def check(chain, address):
    code, body = http("GET", f"{API}/v2/contract/{chain}/{address}")
    match = body.get("match") if isinstance(body, dict) else None
    print(f"Sourcify {chain}/{address}: HTTP {code}, match {match!r}")
    return 0 if code == 200 and match == "exact_match" else 1


def submit(a):
    root = Path(__file__).resolve().parent.parent
    dep = json.loads((root / "deployments" / f"{a.deployment}.json").read_text(encoding="utf-8"))
    entry = next(b for b in dep["build"] if b["key"] == a.key)
    path, _, name = a.artifact.partition(":")
    art = json.loads((Path(a.build_dir) / "out" / Path(path).name / f"{name}.json").read_text(encoding="utf-8"))
    meta = art.get("metadata")
    meta = json.loads(meta) if isinstance(meta, str) else meta
    version = meta["compiler"]["version"]  # e.g. 0.8.30+commit.73712a01
    p = subprocess.run(["forge", "verify-contract", "--show-standard-json-input", a.address, a.artifact],
                       cwd=a.build_dir, capture_output=True, text=True)
    if p.returncode != 0:
        print(f"forge could not write the standard JSON input: {p.stderr.strip()[-300:]}", file=sys.stderr)
        return 1
    std = json.loads(p.stdout)
    body = {"stdJsonInput": std, "compilerVersion": version, "contractIdentifier": a.artifact}
    if entry.get("creationTx"):
        body["creationTransactionHash"] = entry["creationTx"]
    code, res = http("POST", f"{API}/v2/verify/{a.chain}/{a.address}", body)
    print(f"POST verify: HTTP {code} {json.dumps(res)[:300]}")
    job = res.get("verificationId") if isinstance(res, dict) else None
    if code not in (200, 202) or not job:
        return 1
    for _ in range(40):
        time.sleep(6)
        code, st = http("GET", f"{API}/v2/verify/{job}")
        if isinstance(st, dict) and st.get("isJobCompleted"):
            print(f"job {job}: {json.dumps(st)[:400]}")
            return 0 if not st.get("error") else 1
    print(f"job {job}: not completed in time", file=sys.stderr)
    return 1


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("what", choices=["check", "submit"])
    ap.add_argument("--chain", required=True, type=int)
    ap.add_argument("--address", required=True)
    ap.add_argument("--build-dir")
    ap.add_argument("--artifact")
    ap.add_argument("--deployment")
    ap.add_argument("--key")
    a = ap.parse_args(argv)
    if a.what == "check":
        return check(a.chain, a.address)
    if not (a.build_dir and a.artifact and a.deployment and a.key):
        ap.error("submit needs --build-dir, --artifact, --deployment and --key")
    return submit(a)


if __name__ == "__main__":
    sys.exit(main())
