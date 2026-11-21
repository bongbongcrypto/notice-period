#!/usr/bin/env python3
"""Self-test of scripts/runs.py --check against stub chains (no network). Exit 1 on any failure.

  1. a record whose three hashes belong together passes
  2. the reactive transaction carries another origin hash: fails
  3. the exit lands at or after executableAt: fails
  4. the tokens go to someone other than the watch owner: fails
  5. the amount sent differs from WatchEnded.assets: fails
  6. the stored copy of a derived field was edited: fails
  7. an "ignored" record with a log for the watch in its Lasna range: fails; without one: passes
  8. a revoke-stays record: passes; with an ExitRequested in its range, or closed with a status other than 3: fails
  9. an arm-only record passes, one naming another watch fails; --add links a fire run to its arm-only record and
     refuses a fire run without one
"""

import contextlib
import copy
import io
import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import runs  # noqa: E402

failures = []


def check(name, cond):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        failures.append(name)


def a(n):
    return "0x" + format(n, "040x")


def t(n):
    return "0x" + format(n, "064x")


def h(n):
    return "0x" + format(n, "064x")


EXIT, REACTIVE, TOKEN, VAULT, OWNER, OTHER = a(0xE1), a(0xEE), a(0x70), a(0x7A), a(0x0A), a(0x0B)
ARM, SUB, H1, H2, H3, IGN = h(0xA1), h(0x5B), h(0x11), h(0x22), h(0x33), h(0x44)
EXEC_AT = 2000


def log(address, topics, data="0x"):
    return {"address": address, "topics": topics, "data": data}


def world(origin=H1, exit_ts=1900, receiver=OWNER, paid=500):
    """Receipts and block times of one exit run on two stub chains."""
    base = {
        ARM: (10, [log(EXIT, [runs.T["armed"], t(1), t(int(OWNER, 16)), t(int(VAULT, 16))],
                       "0x" + "7".rjust(64, "0") + "0" * 64 + "64".rjust(64, "0"))]),
        H1: (20, [log(VAULT, [runs.T["submit"], "0x60d54d41" + "0" * 56],
                      "0x" + "40".rjust(64, "0") + format(EXEC_AT, "064x") + "0" * 64)]),
        H3: (30, [log(TOKEN, [runs.T["transfer"], t(int(VAULT, 16)), t(int(receiver, 16))], "0x" + format(paid, "064x")),
                  log(EXIT, [runs.T["ended"], t(1), H1],
                      "0x" + "0" * 64 + "1".rjust(64, "0") + format(500, "064x") + format(500, "064x"))]),
    }
    lasna = {
        SUB: (5, [log(REACTIVE, [runs.T["subscribed"], t(1), t(int(VAULT, 16))])]),
        H2: (6, [log(REACTIVE, [runs.T["requested"], t(1), origin], "0x" + "1".rjust(64, "0") + "0" * 64)]),
    }
    times = ({10: 1000, 20: 1500, 30: exit_ts}, {5: 990, 6: 1501})
    return base, lasna, times


class Stub:
    def __init__(self, receipts, times, logs=()):
        self.receipts, self.times, self.logs = receipts, times, list(logs)

    def receipt(self, tx):
        if tx not in self.receipts:
            raise runs.RpcError(f"no receipt for {tx}")
        block, logs = self.receipts[tx]
        return {"status": "0x1", "blockNumber": hex(block), "logs": logs}

    def block(self, n):
        return {"timestamp": hex(self.times.get(n, 0)), "number": hex(n)}

    def call(self, method, params):
        if method == "eth_getBlockByNumber":
            return {"number": params[0]}
        if method == "eth_getLogs":
            f = params[0]
            lo, hi = int(f["fromBlock"], 16), int(f["toBlock"], 16)
            return [x for x in self.logs if lo <= int(x["blockNumber"], 16) <= hi]
        raise runs.RpcError(method)


def factory(base, lasna, times, lasna_logs=()):
    return lambda _dep: (Stub(base, times[0]), Stub(lasna, times[1], lasna_logs))


def run_check(root, chain_factory):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = runs.check(["t"], root=root, chain_factory=chain_factory)
    return code, out.getvalue()


RECORD = {"deployment": "t", "n": 1, "exit": EXIT, "reactive": REACTIVE, "token": TOKEN, "watchId": 1,
          "armTx": ARM, "subTx": SUB, "hash1": H1, "hash2": H2, "hash3": H3}

with tempfile.TemporaryDirectory() as d:
    root = Path(d)
    (root / "deployments").mkdir()
    (root / "records").mkdir()
    (root / "deployments" / "t.json").write_text(json.dumps(
        {"name": "t", "contracts": {"exit": EXIT, "reactive": REACTIVE, "token": TOKEN}}))

    def put(rec):
        for p in (root / "records").glob("*.json"):
            p.unlink()
        (root / "records" / "t-1.json").write_text(json.dumps(rec))

    put(RECORD)
    code, out = run_check(root, factory(*world()))
    check("1 a record whose hashes belong together passes", code == 0 and "1 of 1 records check out" in out)
    code, out = run_check(root, factory(*world(origin=h(0x99))))
    check("2 another origin hash on the reactive transaction fails", code == 1 and "not hash 1" in out)
    code, out = run_check(root, factory(*world(exit_ts=EXEC_AT)))
    check("3 an exit at executableAt fails", code == 1 and "not before the change could run" in out)
    code, out = run_check(root, factory(*world(receiver=OTHER)))
    check("4 tokens to someone other than the owner fail", code == 1 and "to the watch owner" in out)
    code, out = run_check(root, factory(*world(paid=499)))
    check("5 an amount other than WatchEnded.assets fails", code == 1 and "WatchEnded says 500" in out)

    base, lasna, times = world()
    derived = runs.derive(RECORD, Stub(base, times[0]), Stub(lasna, times[1]))
    edited = copy.deepcopy(RECORD)
    edited["derived"] = copy.deepcopy(derived)
    put(edited)
    code, out = run_check(root, factory(*world()))
    check("6a the stored copy equal to the receipts passes", code == 0)
    edited["derived"]["page"]["r3"]["ts"] -= 100
    put(edited)
    code, out = run_check(root, factory(*world()))
    check("6b an edited stored copy fails", code == 1 and "stored copy differs" in out)

    ignored = {"deployment": "t", "n": 1, "exit": EXIT, "reactive": REACTIVE, "token": TOKEN, "watchId": 1,
               "ignoredTx": IGN, "ignoredLasnaFrom": 100, "ignoredLasnaTo": 120}
    put(ignored)
    seen = [{"address": REACTIVE, "blockNumber": hex(110), "transactionHash": h(0x55),
             "topics": [runs.T["stored"], t(1), h(0x66)], "data": "0x"}]
    code, out = run_check(root, factory(*world(), lasna_logs=seen))
    check("7a a log for the watch after an unwatched change fails", code == 1 and "unwatched change" in out)
    code, out = run_check(root, factory(*world(), lasna_logs=[]))
    check("7b no log for the watch passes", code == 0 and "absence conditions hold" in out)

    # 8. revoke-stays: ChangeRevoked, no ExitRequested in the range, WatchClosed with status 3
    REV, CLOSED = h(0x77), h(0x78)

    def revoke_world(closed_status=3):
        base, lasna, times = world()
        lasna = dict(lasna)
        lasna[REV] = (7, [log(REACTIVE, [runs.T["revoked"], t(1), h(0x66)])])
        lasna[CLOSED] = (8, [log(REACTIVE, [runs.T["closed"], t(1)], "0x" + format(closed_status, "064x"))])
        return base, lasna, times

    revoked = {"deployment": "t", "n": 1, "exit": EXIT, "reactive": REACTIVE, "token": TOKEN, "watchId": 1,
               "action": "revoke-stays", "hash1": H1, "revokeTx": h(0x76), "changeRevokedTx": REV,
               "watchClosedTx": CLOSED, "lasnaFrom": 100, "lasnaTo": 120, "armTx": ARM, "subTx": SUB}
    put(revoked)
    code, out = run_check(root, factory(*revoke_world(), lasna_logs=[]))
    check("8a a revoked change with no exit asked passes", code == 0 and "absence conditions hold" in out)
    asked = [{"address": REACTIVE, "blockNumber": hex(115), "transactionHash": h(0x79),
              "topics": [runs.T["requested"], t(1), H1], "data": "0x"}]
    code, out = run_check(root, factory(*revoke_world(), lasna_logs=asked))
    check("8b an ExitRequested after the revoke fails", code == 1 and "after the revoke" in out)
    code, out = run_check(root, factory(*revoke_world(closed_status=2), lasna_logs=[]))
    check("8c a watch closed as exited, not cancelled, fails", code == 1 and "cancelled (3)" in out)

    # 9. arm-only record, and a fire run linked to it by add()
    armonly = {"deployment": "t", "n": 1, "exit": EXIT, "reactive": REACTIVE, "token": TOKEN, "watchId": 1,
               "action": "arm-only", "armTx": ARM, "subTx": SUB}
    put(armonly)
    code, out = run_check(root, factory(*world()))
    check("9a an arm-only record whose watch was armed and subscribed passes", code == 0 and "armed and subscribed" in out)
    wrong = dict(armonly, watchId=2)
    put(wrong)
    code, out = run_check(root, factory(*world()))
    check("9b an arm-only record naming another watch fails", code == 1)
    put(armonly)
    fire_run = root / "fire.json"
    fire_run.write_text(json.dumps({"result": "ok", "action": "fire", "exit": EXIT, "watchId": 1, "vault": VAULT,
                                    "hash1": H1, "hash2": H2, "hash3": H3}))
    with contextlib.redirect_stdout(io.StringIO()):
        runs.add("t", [str(fire_run)], root=root)
    fired = json.loads((root / "records" / "t-2.json").read_text())
    check("9c add() takes the fire run's arm and subscription from the arm-only record",
          fired["armTx"] == ARM and fired["subTx"] == SUB and fired["armRecord"] == 1)
    code, out = run_check(root, factory(*world()))
    check("9d the fire record then checks out from receipts", code == 0 and "2 of 2 records check out" in out)
    (root / "records" / "t-2.json").unlink()
    (root / "records" / "t-1.json").unlink()
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            runs.add("t", [str(fire_run)], root=root)
        check("9e a fire run without its arm-only record is refused", False)
    except runs.CheckError:
        check("9e a fire run without its arm-only record is refused", True)

if failures:
    print(f"{len(failures)} failed")
    sys.exit(1)
print("run record checks passed")
