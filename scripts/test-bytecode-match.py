#!/usr/bin/env python3
"""Self-test of scripts/bytecode_match.py against a stub RPC (no network). Exit 1 on any failure.

  1. code that differs from the build only inside an immutable range: MATCH
  2. code that differs by one byte outside every immutable range: NO MATCH
  3. code whose CBOR metadata hash differs: NO MATCH (reported as metadata)
  4. code of another length: NO MATCH
  5. the whole run writes status/bytecode-<name>.json with allMatch false when one contract differs
Masking skipped fails case 1; masking that is too broad (the whole code, or the metadata) fails cases 2 and 3.
"""

import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bytecode_match as bm  # noqa: E402

failures = []


def check(name, cond):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        failures.append(name)


# A 160-byte "runtime": 100 bytes of code with two 32-byte immutables at 10 and 50, then a 53-byte CBOR tail
# (0xa2 64 'ipfs' 58 22 <34 bytes> 64 'solc' 43 <3 bytes>) and its 2-byte length 0x0033.
body = bytearray((i * 7 + 3) % 251 for i in range(105))
meta = bytes.fromhex("a264697066735822") + bytes(range(1, 35)) + bytes.fromhex("64736f6c6343") + bytes([0, 8, 30])
built = bytes(body) + meta + len(meta).to_bytes(2, "big")
refs = {"101": [{"start": 10, "length": 32}], "202": [{"start": 50, "length": 32}]}
artifact = {"deployedBytecode": {"object": "0x" + built.hex(), "immutableReferences": refs}}


def chain_with(changes):
    b = bytearray(built)
    for i, v in changes.items():
        b[i] = v
    return bytes(b)


r1 = bm.compare(chain_with({10: 0xAA, 41: 0xBB, 60: 0xCC}), artifact)
check("1 difference only inside immutable ranges matches", r1["match"] is True)
check("1 masked ranges are exactly the two references", r1["maskedRanges"] == [[10, 32], [50, 32]] and r1["maskedBytes"] == 64)
check("1 the value found in the first range is reported", r1["immutableValues"][0].startswith("0xaa"))
r2 = bm.compare(chain_with({9: (built[9] + 1) % 256}), artifact)
check("2 one byte outside the ranges does not match", r2["match"] is False and r2["firstDifference"] == 9)
r2b = bm.compare(chain_with({42: (built[42] + 1) % 256}), artifact)
check("2b the byte right after a range does not match", r2b["match"] is False and r2b["firstDifference"] == 42)
r3 = bm.compare(chain_with({len(built) - 20: (built[-20] + 1) % 256}), artifact)
check("3 a different metadata hash does not match", r3["match"] is False and r3["why"] == "metadata differs")
r4 = bm.compare(built + b"\x00", artifact)
check("4 another length does not match", r4["match"] is False and r4["why"] == "length differs")
try:
    bm.compare(built, {"deployedBytecode": {"object": artifact["deployedBytecode"]["object"],
                                            "immutableReferences": {"1": [{"start": 150, "length": 32}]}}})
    check("4b a range outside the code is refused", False)
except bm.MatchError:
    check("4b a range outside the code is refused", True)

# 5. the whole run against a stub RPC and a scratch deployment
with tempfile.TemporaryDirectory() as d:
    root = Path(d)
    (root / "deployments").mkdir()
    (root / "out" / "A.sol").mkdir(parents=True)
    (root / "out" / "A.sol" / "A.json").write_text(json.dumps(artifact))
    dep = {"name": "t", "status": "deployed", "sourceCommit": "abc", "build": [
        {"key": "good", "chainId": 84532, "address": "0x" + "11" * 20, "artifact": "src/A.sol:A"},
        {"key": "bad", "chainId": 84532, "address": "0x" + "22" * 20, "artifact": "src/A.sol:A"}]}
    (root / "deployments" / "t.json").write_text(json.dumps(dep))
    codes = {"0x" + "11" * 20: chain_with({12: 1}), "0x" + "22" * 20: chain_with({0: (built[0] + 1) % 256})}

    class Stub:
        def code(self, address):
            return "0x" + codes[address].hex()

    st = bm.run("t", root / "out", root / "status", rpc_factory=lambda _c: Stub(), root=root)
    written = json.loads((root / "status" / "bytecode-t.json").read_text())
    check("5 the run reports one match and one difference",
          [c["match"] for c in st["contracts"]] == [True, False] and st["allMatch"] is False)
    check("5 the status file is written", written["allMatch"] is False and written["sourceCommit"] == "abc")

if failures:
    print(f"{len(failures)} failed")
    sys.exit(1)
print("bytecode match checks passed")
