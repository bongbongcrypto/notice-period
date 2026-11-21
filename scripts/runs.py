#!/usr/bin/env python3
"""Run records: one JSON file per evidence run (records/<deployment>-<n>.json), re-derived from public receipts.

    runs.py --emit RUN_JSON --deployment NAME --run-id ID   (in loop.yml) print run.json into the log and summary
    runs.py --fetch RUN_ID [--repo OWNER/NAME]              read that run's run.json back from its log (needs gh)
    runs.py --add NAME RUN_JSON...                          new records from run.json files
    runs.py --import-recorded NAME                          records from the hashes in docs/data/runs.js
    runs.py --write [--page NAME]                           derive every record from the chains; write
                                                            docs/data/runs.js with the runs of deployment NAME
    runs.py --check [NAME...]                               re-derive every record and stop on any mismatch
    runs.py --hold NAME WATCH --from-block N --to-block M   attribute every Lasna log of the reactive contract
                                                            between two blocks; status/hold-<NAME>.json

What --check requires of an exit run (all read from receipts, never from the record's own copy):
  - the three hashes belong together: the ExitRequested log on Lasna and the WatchEnded log on Base Sepolia both carry
    the watch id and, as origin transaction hash, the hash of the curator's Submit;
  - the exit landed strictly before the change could run (block time of the WatchEnded < executableAt of the Submit);
  - the receiver is the watch owner: the token Transfer in the exit goes from the vault to the owner of the WatchArmed;
  - its amount equals WatchEnded.assets, and the outcome is 0 (redeemed);
  - the stored copy (times, amounts, blocks) equals what the receipts say.
For an "ignored" record: no log of the reactive contract for the watch in the recorded Lasna block range. For a
"revoke-stays" record: ChangeRevoked for the watch, no ExitRequested for it in the range, and the cancel's WatchClosed.
Standard library only (and the gh command line for --fetch).
"""

import argparse
import datetime
import glob
import json
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from keccak import keccak256, topic  # noqa: E402
from rpclib import Rpc, RpcError, uint  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
T = {
    "armed": topic("WatchArmed(uint256,address,address,uint8,uint8,uint256)"),
    "ended": topic("WatchEnded(uint256,uint256,uint8,uint8,uint256,uint256)"),
    "submit": topic("Submit(bytes4,bytes,uint256)"),
    "subscribed": topic("WatchSubscribed(uint256,address,uint8,uint8)"),
    "requested": topic("ExitRequested(uint256,uint256,uint8,bytes32)"),
    "revoked": topic("ChangeRevoked(uint256,bytes32)"),
    "closed": topic("WatchClosed(uint256,uint8)"),
    "stray": topic("StrayEvent(uint256,address,uint256,uint256)"),
    "unknown": topic("UnknownEvent(uint256,address,uint256,uint256)"),
    "transfer": topic("Transfer(address,address,uint256)"),
    "refused": topic("WatchRefused(uint256,uint8)"),
    "stored": topic("ChangeStored(uint256,bytes32,uint256,uint256)"),
    "filterOn": topic("FilterOn(bytes32)"),
    "filterOff": topic("FilterOff(bytes32)"),
}
NAMES = {v: k for k, v in T.items()}
# events of NoticeReactive whose first indexed topic is a watch id (StrayEvent and UnknownEvent carry a chain id there)
WATCH_TOPICS = {T[k] for k in ("subscribed", "refused", "stored", "revoked", "requested", "closed")}
MARK_BEGIN, MARK_END = "NP-RUN-JSON-BEGIN", "NP-RUN-JSON-END"


class CheckError(Exception):
    pass


def checksum(addr):
    a = addr.lower().replace("0x", "")
    h = keccak256(a.encode()).hex()
    return "0x" + "".join(c.upper() if c.isalpha() and int(h[i], 16) >= 8 else c for i, c in enumerate(a))


def w256(n):
    return "0x" + format(int(n), "064x")


def low(x):
    return x.lower() if isinstance(x, str) else x


def load_deployment(name, root=ROOT):
    return json.loads((Path(root) / "deployments" / f"{name}.json").read_text(encoding="utf-8"))


def chains(dep):
    base = os.environ.get("BASE_RPC_READ")
    lasna = os.environ.get("LASNA_RPC_READ")
    return (Rpc(base.split()) if base else Rpc.for_chain(dep["origin"]["chainId"]),
            Rpc(lasna.split()) if lasna else Rpc.for_chain(dep["reactive"]["chainId"]))


def logs_of(rec, address, topic0, topic1=None):
    out = []
    for log in rec.get("logs", []):
        t = [x.lower() for x in log.get("topics", [])]
        if low(log.get("address")) != low(address) or not t or t[0] != topic0:
            continue
        if topic1 is not None and (len(t) < 2 or t[1] != low(topic1)):
            continue
        out.append(log)
    return out


def ok_receipt(rpc, h, label):
    r = rpc.receipt(h)
    if r.get("status") not in ("0x1", 1):
        raise CheckError(f"{label} {h} did not succeed")
    return r


def ts_of(rpc, block_hex):
    return int(rpc.block(int(block_hex, 16))["timestamp"], 16)


def derive_exit(rec, base, lasna):
    """Everything an exit run claims, read from receipts. Raises CheckError on any break in the chain."""
    exit_c, reactive, token = rec["exit"], rec["reactive"], rec["token"]
    wid = int(rec["watchId"])
    wt = w256(wid)
    arm = ok_receipt(base, rec["armTx"], "arm")
    armed = logs_of(arm, exit_c, T["armed"], wt)
    if len(armed) != 1:
        raise CheckError(f"arm {rec['armTx']}: {len(armed)} WatchArmed logs for watch {wid} from {exit_c}")
    owner, vault = "0x" + armed[0]["topics"][2][-40:], "0x" + armed[0]["topics"][3][-40:]
    kinds, mode = uint(armed[0]["data"], 0), uint(armed[0]["data"], 1)
    sub = ok_receipt(lasna, rec["subTx"], "subscription")
    if len(logs_of(sub, reactive, T["subscribed"], wt)) != 1:
        raise CheckError(f"subscription {rec['subTx']}: no WatchSubscribed for watch {wid} from {reactive}")
    r1 = ok_receipt(base, rec["hash1"], "curator's Submit")
    subs = logs_of(r1, vault, T["submit"])
    if len(subs) != 1:
        raise CheckError(f"hash 1 {rec['hash1']}: {len(subs)} Submit logs of vault {vault}")
    selector = subs[0]["topics"][1][:10]
    exec_at = uint(subs[0]["data"], 1)
    r2 = ok_receipt(lasna, rec["hash2"], "reactive transaction")
    req = logs_of(r2, reactive, T["requested"], wt)
    if len(req) != 1:
        raise CheckError(f"hash 2 {rec['hash2']}: {len(req)} ExitRequested logs for watch {wid}")
    if low(req[0]["topics"][2]) != low(rec["hash1"]):
        raise CheckError(f"hash 2 {rec['hash2']}: ExitRequested carries origin {req[0]['topics'][2]}, not hash 1")
    r3 = ok_receipt(base, rec["hash3"], "exit")
    ended = logs_of(r3, exit_c, T["ended"], wt)
    if len(ended) != 1:
        raise CheckError(f"hash 3 {rec['hash3']}: {len(ended)} WatchEnded logs for watch {wid}")
    if low(ended[0]["topics"][2]) != low(rec["hash1"]):
        raise CheckError(f"hash 3 {rec['hash3']}: WatchEnded carries origin {ended[0]['topics'][2]}, not hash 1")
    d = ended[0]["data"]
    outcome, reason, shares, assets = uint(d, 0), uint(d, 1), uint(d, 2), uint(d, 3)
    if outcome != 0:
        raise CheckError(f"hash 3: outcome {outcome}, not redeemed")
    paid = [log for log in logs_of(r3, token, T["transfer"])
            if len(log["topics"]) == 3 and low("0x" + log["topics"][1][-40:]) == low(vault)
            and low("0x" + log["topics"][2][-40:]) == low(owner)]
    if len(paid) != 1:
        raise CheckError(f"hash 3: {len(paid)} token transfers from the vault to the watch owner {owner}")
    if int(paid[0]["data"], 16) != assets:
        raise CheckError(f"hash 3: the owner received {int(paid[0]['data'], 16)}, WatchEnded says {assets}")
    t1, t3 = ts_of(base, r1["blockNumber"]), ts_of(base, r3["blockNumber"])
    if not t3 < exec_at:
        raise CheckError(f"the exit landed at {t3}, not before the change could run at {exec_at}")
    if t3 < t1:
        raise CheckError("the exit is older than the Submit")
    return {
        "id": wid, "mode": mode, "kinds": kinds, "owner": checksum(owner), "vault": checksum(vault),
        "selector": selector, "execAt": exec_at,
        "armTx": rec["armTx"], "armTs": ts_of(base, arm["blockNumber"]),
        "subTx": rec["subTx"], "subTs": ts_of(lasna, sub["blockNumber"]),
        "r1": {"hash": rec["hash1"], "block": int(r1["blockNumber"], 16), "ts": t1},
        "r2": {"hash": rec["hash2"], "block": int(r2["blockNumber"], 16), "ts": ts_of(lasna, r2["blockNumber"]),
               "refTx": r2.get("refTx"), "refChainId": r2.get("refChainId"), "reason": uint(req[0]["data"], 0)},
        "r3": {"hash": rec["hash3"], "block": int(r3["blockNumber"], 16), "ts": t3, "outcome": outcome,
               "reason": reason, "shares": str(shares), "assets": str(assets)},
        "exit": checksum(exit_c), "reactive": checksum(reactive),
    }


def lasna_logs(lasna, reactive, lo, hi, topics):
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from logs import read_logs
    return read_logs(lasna, reactive, int(lo), int(hi), topics, int(os.environ.get("LOG_CHUNK", "500")))


def derive_absence(rec, base, lasna):
    wt = w256(rec["watchId"])
    if rec.get("ignoredTx"):
        seen = lasna_logs(lasna, rec["reactive"], rec["ignoredLasnaFrom"], rec["ignoredLasnaTo"], ["-", wt])
        if seen:
            raise CheckError(f"{len(seen)} logs of the reactive contract for watch {rec['watchId']} after the "
                             f"unwatched change {rec['ignoredTx']}")
    if rec.get("revokeTx"):
        rv = ok_receipt(lasna, rec["changeRevokedTx"], "ChangeRevoked")
        if not logs_of(rv, rec["reactive"], T["revoked"], wt):
            raise CheckError("no ChangeRevoked for the watch")
        asked = lasna_logs(lasna, rec["reactive"], rec["lasnaFrom"], rec["lasnaTo"], [T["requested"], wt])
        if asked:
            raise CheckError(f"{len(asked)} ExitRequested for the watch after the revoke")
        cl = ok_receipt(lasna, rec["watchClosedTx"], "WatchClosed")
        closed = logs_of(cl, rec["reactive"], T["closed"], wt)
        if not closed or uint(closed[0]["data"], 0) != 3:
            raise CheckError("the watch was not closed as cancelled (3) on Lasna")
    return {"absenceChecked": bool(rec.get("ignoredTx") or rec.get("revokeTx"))}


def derive_arm(rec, base, lasna):
    """An arm-only record: the watch was armed on Base Sepolia and subscribed on Lasna."""
    wt = w256(rec["watchId"])
    arm = ok_receipt(base, rec["armTx"], "arm")
    if len(logs_of(arm, rec["exit"], T["armed"], wt)) != 1:
        raise CheckError(f"arm {rec['armTx']}: no WatchArmed for watch {rec['watchId']}")
    sub = ok_receipt(lasna, rec["subTx"], "subscription")
    if len(logs_of(sub, rec["reactive"], T["subscribed"], wt)) != 1:
        raise CheckError(f"subscription {rec['subTx']}: no WatchSubscribed for watch {rec['watchId']}")
    return {"armBlock": int(arm["blockNumber"], 16), "armTs": ts_of(base, arm["blockNumber"])}


def derive(rec, base, lasna):
    out = {}
    if rec.get("revokeTx") or rec.get("ignoredTx"):
        out.update(derive_absence(rec, base, lasna))
    if rec.get("hash3"):
        out["page"] = derive_exit(rec, base, lasna)
    elif rec.get("armTx") and rec.get("subTx") and not rec.get("revokeTx"):
        out["arm"] = derive_arm(rec, base, lasna)
    return out


# ------------------------------------------------------------------ record files

def record_paths(root=ROOT, names=None):
    out = sorted(glob.glob(str(Path(root) / "records" / "*.json")))
    if names:
        out = [p for p in out if any(Path(p).name.startswith(n + "-") for n in names)]
    return out


def next_n(name, root=ROOT):
    ns = [int(m.group(1)) for p in record_paths(root, [name])
          if (m := re.search(r"-(\d+)\.json$", p))]
    return max(ns, default=0) + 1


def rel(path, root=ROOT):
    try:
        return Path(path).resolve().relative_to(Path(root).resolve()).as_posix()
    except ValueError:
        return Path(path).name


def write_json(path, doc):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps(doc, indent=2) + "\n")


KEEP = ["kind", "mode", "action", "depositorKey", "curatorKey", "depositor", "curator", "vault", "watchId", "armTx",
        "subscribedTx", "hash1", "hash2", "hash3", "ignoredTx", "ignoredLasnaFrom", "ignoredLasnaTo", "revokeTx",
        "changeRevokedTx", "cancelTx", "watchClosedTx", "lasnaFrom", "lasnaTo", "seconds", "heldSeconds", "burstTx",
        "reactiveTxs", "strayBefore", "strayAfter", "floatBefore", "floatAfter", "expiredWatch", "topupTx"]


def add(name, files, root=ROOT):
    dep = load_deployment(name, root)
    made = []
    for f in files:
        run = json.loads(Path(f).read_text(encoding="utf-8"))
        if run.get("result") != "ok":
            print(f"{f}: run did not succeed ({run.get('result')}); not recorded")
            continue
        if low(run.get("exit")) != low(dep["contracts"]["exit"]):
            raise CheckError(f"{f}: exit {run.get('exit')} is not deployment {name}'s")
        rec = {"deployment": name, "n": next_n(name, root), "loopRun": run.get("loopRun"),
               "exit": dep["contracts"]["exit"], "reactive": dep["contracts"]["reactive"],
               "token": dep["contracts"]["token"]}
        rec.update({k: run[k] for k in KEEP if k in run})
        if "subscribedTx" in rec:
            rec["subTx"] = rec.pop("subscribedTx")
        if run.get("action") == "fire":
            # The watch was armed by an earlier arm-only run: its arm and subscription come from that record.
            armed = [json.loads(Path(p).read_text(encoding="utf-8")) for p in record_paths(root, [name])]
            armed = [r for r in armed if r.get("action") == "arm-only" and str(r.get("watchId")) == str(run.get("watchId"))]
            if len(armed) != 1:
                raise CheckError(f"{f}: fire on watch {run.get('watchId')} needs exactly one arm-only record of it "
                                 f"(found {len(armed)}); add that run first")
            rec["armTx"], rec["subTx"], rec["armRecord"] = armed[0]["armTx"], armed[0]["subTx"], armed[0]["n"]
        path = Path(root) / "records" / f"{name}-{rec['n']}.json"
        write_json(path, rec)
        made.append(str(path))
        print(f"written: {rel(path, root)}")
    return made


def import_recorded(name, root=ROOT):
    """Records for the runs already on the page (docs/data/runs.js), by their hashes only."""
    dep = load_deployment(name, root)
    text = (Path(root) / "docs" / "data" / "runs.js").read_text(encoding="utf-8")
    m = re.search(r"NP\.recorded = (\{.*\});\s*\}\(\)\);", text, re.S)
    if not m:
        raise CheckError("docs/data/runs.js: NP.recorded not found")
    runs = json.loads(m.group(1))["runs"]
    loop_runs = {r["watch"]: r for r in dep.get("runs", [])}
    for r in runs:
        meta = loop_runs.get(r["id"], {})
        rec = {"deployment": name, "n": meta.get("n", r["id"]), "loopRun": meta.get("loopRun"),
               "exit": dep["contracts"]["exit"], "reactive": dep["contracts"]["reactive"],
               "token": dep["contracts"]["token"], "kind": "adapter", "mode": r["mode"], "action": "exit",
               "depositorKey": "a", "curatorKey": "a", "vault": r["vault"], "watchId": r["id"], "armTx": r["armTx"],
               "subTx": r["subTx"], "hash1": r["r1"]["hash"], "hash2": r["r2"]["hash"], "hash3": r["r3"]["hash"]}
        path = Path(root) / "records" / f"{name}-{rec['n']}.json"
        write_json(path, rec)
        print(f"written: {rel(path, root)}")


def render_runs_js(page_runs, read_at):
    body = json.dumps({"readAt": read_at, "runs": page_runs}, indent=2)
    return ("/* Recorded runs: real transactions read from the public RPC endpoints of Base Sepolia and Reactive Lasna\n"
            "   at the time in readAt. The page re-reads every receipt before it calls a run checked.\n"
            "   Written by scripts/runs.py --write from records/; never edit by hand. */\n"
            "(function () {\n  'use strict';\n  var NP = window.NP = window.NP || {};\n  NP.recorded = "
            + body.replace("\n", "\n  ") + ";\n}());\n")


def page_deployment(root=ROOT):
    """The deployment the page shows: named in docs/data/deployment.js (scripts/stamp.py), else 2026-11-18."""
    js = Path(root) / "docs" / "data" / "deployment.js"
    m = re.search(r"from deployments/([0-9A-Za-z-]+)\.json;", js.read_text(encoding="utf-8")) if js.exists() else None
    return m.group(1) if m else "2026-11-18"


def write(page, root=ROOT, chain_factory=chains):
    page_runs = []
    for p in record_paths(root):
        rec = json.loads(Path(p).read_text(encoding="utf-8"))
        dep = load_deployment(rec["deployment"], root)
        base, lasna = chain_factory(dep)
        d = derive(rec, base, lasna)
        rec["derived"] = d
        write_json(p, rec)
        print(f"{Path(p).name}: derived from receipts")
        if rec["deployment"] == page and "page" in d:
            page_runs.append(d["page"])
    page_runs.sort(key=lambda r: r["id"])
    read_at = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    out = Path(root) / "docs" / "data" / "runs.js"
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write(render_runs_js(page_runs, read_at))
    print(f"written: {rel(out, root)} ({len(page_runs)} runs of deployment {page})")


def check(names, root=ROOT, chain_factory=chains):
    paths = record_paths(root, names)
    if not paths:
        raise CheckError("no records to check")
    bad = skipped = 0
    for p in paths:
        rec = json.loads(Path(p).read_text(encoding="utf-8"))
        dep = load_deployment(rec["deployment"], root)
        if low(rec["exit"]) != low(dep["contracts"]["exit"]) or low(rec["reactive"]) != low(dep["contracts"]["reactive"]):
            print(f"FAIL {Path(p).name}: its contracts are not deployment {rec['deployment']}'s")
            bad += 1
            continue
        try:
            base, lasna = chain_factory(dep)
            d = derive(rec, base, lasna)
            if "derived" in rec and rec["derived"] != d:
                raise CheckError("the stored copy differs from what the receipts say: "
                                 + ", ".join(k for k in set(d) | set(rec["derived"]) if d.get(k) != rec["derived"].get(k)))
            parts = []
            if d.get("absenceChecked"):
                parts.append("absence conditions hold")
            if "page" in d:
                pg = d["page"]
                parts.append(f"watch {pg['id']}, mode {pg['mode']}, deposit back {pg['r3']['ts'] - pg['r1']['ts']} s "
                             f"after the Submit, {pg['execAt'] - pg['r3']['ts']} s before it could run, "
                             f"{pg['r3']['assets']} to the owner")
            if "arm" in d:
                parts.append(f"watch {rec['watchId']} armed and subscribed")
            if not parts:
                print(f"skip {Path(p).name}: action {rec.get('action')} has nothing re-derived from receipts")
                skipped += 1
                continue
            print(f"ok   {Path(p).name}: {'; '.join(parts)}")
        except (CheckError, RpcError) as e:
            print(f"FAIL {Path(p).name}: {e}")
            bad += 1
    print(f"{len(paths) - bad - skipped} of {len(paths)} records check out, {bad} fail, {skipped} skipped")
    return 1 if bad else 0


def hold(name, watch, lo, hi, root=ROOT, chain_factory=chains):
    dep = load_deployment(name, root)
    _, lasna = chain_factory(dep)
    reactive = dep["contracts"]["reactive"]
    logs = lasna_logs(lasna, reactive, lo, hi, [])
    by_tx = {}
    for log in logs:
        by_tx.setdefault(log["tx"], []).append(log)
    wt = w256(watch)
    rows, caused = [], 0
    for tx, ls in by_tx.items():
        scoped = [x for x in ls if len(x["topics"]) > 1 and x["topics"][0] in WATCH_TOPICS]
        watches = sorted({int(x["topics"][1], 16) for x in scoped})
        kinds = sorted({NAMES.get(x["topics"][0], x["topics"][0][:10]) for x in ls})
        held = any(x["topics"][1] == wt for x in scoped)
        caused += 1 if held else 0
        rows.append({"tx": tx, "block": ls[0]["block"], "events": kinds, "watches": watches, "heldWatch": held})
    doc = {"deployment": name, "watch": watch, "lasnaFrom": lo, "lasnaTo": hi, "reactive": reactive,
           "method": "every log of the reactive contract in the range, grouped by transaction; a transaction that "
                     "emitted no log is not seen by this method",
           "transactionsWithLogs": len(rows), "causedByHeldWatch": caused, "transactions": rows}
    out = Path(root) / "status" / f"hold-{name}.json"
    write_json(out, doc)
    print(f"{len(rows)} transactions with logs in Lasna blocks {lo} to {hi}; {caused} carry watch {watch}")
    print(f"written: {rel(out, root)}")
    return 0


# ------------------------------------------------------------------ Actions side

def emit(run_json, deployment, run_id):
    p = Path(run_json)
    doc = json.loads(p.read_text(encoding="utf-8")) if p.exists() else {"result": "no run record written"}
    doc["deployment"] = deployment
    doc["loopRun"] = int(run_id) if str(run_id).isdigit() else run_id
    text = json.dumps(doc, indent=2)
    print(MARK_BEGIN)
    print(text)
    print(MARK_END)
    s = os.environ.get("GITHUB_STEP_SUMMARY")
    if s:
        with open(s, "a", encoding="utf-8") as f:
            f.write("\nRun record (run.json):\n\n```json\n" + text + "\n```\n")
    return 0


def fetch(run_id, repo, root=ROOT):
    jobs = json.loads(subprocess.run(["gh", "api", f"repos/{repo}/actions/runs/{run_id}/jobs"],
                                     capture_output=True, text=True, check=True).stdout)
    for job in jobs.get("jobs", []):
        log = subprocess.run(["gh", "api", f"repos/{repo}/actions/jobs/{job['id']}/logs"],
                             capture_output=True, text=True, check=True).stdout
        lines = [re.sub(r"^\S+Z ", "", line) for line in log.splitlines()]
        if MARK_BEGIN in lines and MARK_END in lines:
            body = "\n".join(lines[lines.index(MARK_BEGIN) + 1:lines.index(MARK_END)])
            doc = json.loads(body)
            out = Path(root) / "records" / "raw" / f"run-{run_id}.json"
            write_json(out, doc)
            print(f"written: {rel(out, root)}")
            return 0
    print(f"no run record in the logs of run {run_id}", file=sys.stderr)
    return 1


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--emit")
    ap.add_argument("--deployment")
    ap.add_argument("--run-id")
    ap.add_argument("--fetch")
    ap.add_argument("--repo", default="bongbongcrypto/notice-period")
    ap.add_argument("--add", nargs="+", metavar=("NAME", "RUN_JSON"))
    ap.add_argument("--import-recorded")
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--page", default=None, help="deployment whose runs the page lists (default: the one named in docs/data/deployment.js, else 2026-11-18)")
    ap.add_argument("--check", nargs="*")
    ap.add_argument("--hold", nargs=2, metavar=("NAME", "WATCH"))
    ap.add_argument("--from-block", type=int)
    ap.add_argument("--to-block", type=int)
    a = ap.parse_args(argv)
    try:
        if a.emit:
            return emit(a.emit, a.deployment or "", a.run_id or "")
        if a.fetch:
            return fetch(a.fetch, a.repo)
        if a.add:
            add(a.add[0], a.add[1:])
            return 0
        if a.import_recorded:
            import_recorded(a.import_recorded)
            return 0
        if a.write:
            write(a.page or page_deployment())
            return 0
        if a.check is not None:
            return check(a.check)
        if a.hold:
            if a.from_block is None or a.to_block is None:
                ap.error("--hold needs --from-block and --to-block")
            return hold(a.hold[0], int(a.hold[1]), a.from_block, a.to_block)
    except (CheckError, RpcError, OSError, ValueError, KeyError) as e:
        print(f"STOP: {type(e).__name__}: {e}", file=sys.stderr)
        return 2
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
