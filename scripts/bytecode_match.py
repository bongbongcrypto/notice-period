#!/usr/bin/env python3
"""Checks that the code on chain is the build of the deployment's source commit, with no third party involved.

    python3 scripts/bytecode_match.py --deployment NAME --out OUT_DIR [--status-dir status]

For every contract in deployments/<NAME>.json "build" (chain, address, artifact "path:Name"):
  - reads the runtime code with eth_getCode (public endpoints, retries; an error is "unknown", never "no code");
  - takes deployedBytecode.object and deployedBytecode.immutableReferences from the Foundry artifact
    OUT_DIR/<File.sol>/<Name>.json built from that commit;
  - masks every immutable range in both (the values are set by the constructor, so they differ by design) and
    compares everything else byte for byte, the CBOR metadata tail included (it carries the hash of the sources and
    settings, so a different source or compiler setting does not match);
  - records the masked ranges and the values found in them on chain (for example the registry address).
Writes status/bytecode-<NAME>.json and exits 1 unless every contract matches (2 on a failed read or a bad input).
The masking itself is checked by scripts/test-bytecode-match.py. Standard library only.
"""

import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rpclib import Rpc, RpcError  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent


class MatchError(Exception):
    pass


def _hex_bytes(h):
    if not isinstance(h, str) or not h.startswith("0x"):
        raise MatchError(f"not a hex string: {str(h)[:20]!r}")
    if "__$" in h:
        raise MatchError("the artifact has unlinked library placeholders")
    return bytes.fromhex(h[2:])


def ranges_of(artifact):
    """[(start, length)] of every immutable reference, sorted; refuses overlaps and ranges outside the code."""
    refs = (artifact.get("deployedBytecode") or {}).get("immutableReferences") or {}
    out = []
    for _, lst in refs.items():
        for r in lst:
            out.append((int(r["start"]), int(r["length"])))
    out.sort()
    for (s1, l1), (s2, _) in zip(out, out[1:]):
        if s1 + l1 > s2:
            raise MatchError(f"immutable ranges overlap at {s2}")
    return out


def mask(code, ranges):
    b = bytearray(code)
    for s, n in ranges:
        if s < 0 or n <= 0 or s + n > len(b):
            raise MatchError(f"immutable range {s}+{n} outside the code ({len(b)} bytes)")
        b[s:s + n] = bytes(n)
    return bytes(b)


def metadata_length(code):
    """Length of the CBOR metadata tail (the last two bytes give it), 0 if absent or implausible."""
    if len(code) < 2:
        return 0
    n = int.from_bytes(code[-2:], "big")
    return n + 2 if 0 < n + 2 <= len(code) else 0


def compare(chain_code, artifact):
    built = _hex_bytes((artifact.get("deployedBytecode") or {}).get("object", ""))
    if not built:
        raise MatchError("the artifact has no deployed bytecode")
    ranges = ranges_of(artifact)
    res = {"codeBytes": len(chain_code), "builtBytes": len(built), "maskedRanges": [[s, n] for s, n in ranges],
           "maskedBytes": sum(n for _, n in ranges), "metadataBytes": metadata_length(built)}
    if len(chain_code) != len(built):
        res.update(match=False, firstDifference=None, why="length differs")
        return res
    a, b = mask(chain_code, ranges), mask(built, ranges)
    res["immutableValues"] = ["0x" + chain_code[s:s + n].hex() for s, n in ranges]
    if a == b:
        res.update(match=True, firstDifference=None, why="")
        return res
    first = next(i for i in range(len(a)) if a[i] != b[i])
    in_meta = res["metadataBytes"] and first >= len(a) - res["metadataBytes"]
    res.update(match=False, firstDifference=first, why="metadata differs" if in_meta else "code differs")
    return res


def artifact_path(out_dir, artifact):
    path, _, name = artifact.partition(":")
    if not path or not name:
        raise MatchError(f"artifact {artifact!r} is not path:Name")
    return Path(out_dir) / Path(path).name / f"{name}.json"


def rpc_for(chain_id):
    env = {84532: "BASE_RPC_READ", 5318007: "LASNA_RPC_READ"}.get(chain_id)
    if env and os.environ.get(env):
        return Rpc(os.environ[env].split())
    return Rpc.for_chain(chain_id)


def run(deployment, out_dir, status_dir, rpc_factory=rpc_for, root=ROOT):
    doc = json.loads((Path(root) / "deployments" / f"{deployment}.json").read_text(encoding="utf-8"))
    build = doc.get("build") or []
    if not build:
        raise MatchError(f"deployments/{deployment}.json has no build list")
    results = []
    for entry in build:
        art = json.loads(artifact_path(out_dir, entry["artifact"]).read_text(encoding="utf-8"))
        code = rpc_factory(int(entry["chainId"])).code(entry["address"])
        if not isinstance(code, str) or code in ("0x", ""):
            raise MatchError(f"{entry['key']}: no code at {entry['address']} (or the endpoint is not synced)")
        r = compare(_hex_bytes(code), art)
        r.update(key=entry["key"], chainId=entry["chainId"], address=entry["address"], artifact=entry["artifact"])
        results.append(r)
        print(f"{entry['key']:<10} {entry['address']} {'MATCH' if r['match'] else 'NO MATCH'} "
              f"({r['codeBytes']} bytes, {len(r['maskedRanges'])} immutable ranges masked{', ' + r['why'] if r['why'] else ''})")
    status = {
        "deployment": deployment,
        "sourceCommit": doc.get("sourceCommit") or doc.get("commit"),
        "builtFrom": os.environ.get("GITHUB_SHA") or "local",
        "method": "eth_getCode vs forge build of sourceCommit; immutable ranges masked in both; the rest, CBOR "
                  "metadata included, compared byte for byte (scripts/bytecode_match.py)",
        "allMatch": all(r["match"] for r in results),
        "contracts": results,
    }
    Path(status_dir).mkdir(parents=True, exist_ok=True)
    out = Path(status_dir) / f"bytecode-{deployment}.json"
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps(status, indent=2) + "\n")
    print(f"written: {out}")
    return status


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--deployment", required=True)
    ap.add_argument("--out", required=True, help="Foundry out/ directory built from the source commit")
    ap.add_argument("--status-dir", default=str(ROOT / "status"))
    ap.add_argument("--root", default=str(ROOT))
    a = ap.parse_args(argv)
    try:
        status = run(a.deployment, a.out, a.status_dir, root=a.root)
    except (MatchError, RpcError, OSError, ValueError, KeyError) as e:
        print(f"STOP: {type(e).__name__}: {e}", file=sys.stderr)
        return 2
    return 0 if status["allMatch"] else 1


if __name__ == "__main__":
    sys.exit(main())
