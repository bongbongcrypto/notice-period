#!/usr/bin/env python3
"""Lists the logs of one contract in a closed block range, for absence checks and counts.

Usage: logs.py RPC ADDRESS FROM_BLOCK TO_BLOCK [TOPIC0|- [TOPIC1|- ...]]
Prints a JSON object: {"count": n, "txs": [distinct transaction hashes], "logs": [{tx, block, topics, data}]}.

An empty answer is trusted only for blocks the endpoint has: the endpoint must return block TO_BLOCK itself first,
or the read is "unknown" (exit 2), never "no logs". Queries span at most LOG_CHUNK blocks (default 100; Base Sepolia
answers 413 to wide ranges). Every returned log is checked again (address, range, topics). Standard library only.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rpclib import Rpc, RpcError  # noqa: E402


def read_logs(rpc, address, lo, hi, topics, chunk=100):
    if rpc.call("eth_getBlockByNumber", [hex(hi), False]) is None:
        raise RpcError(f"the endpoint does not have block {hi} yet")
    want = [None if t in (None, "-", "") else t.lower() for t in topics]
    out = []
    start = lo
    while start <= hi:
        end = min(hi, start + chunk - 1)
        flt = {"address": address, "fromBlock": hex(start), "toBlock": hex(end)}
        if any(want):
            flt["topics"] = want
        logs = rpc.call("eth_getLogs", [flt])
        if not isinstance(logs, list):
            raise RpcError("eth_getLogs answer is not a list")
        for log in logs:
            b = int(log["blockNumber"], 16)
            t = [x.lower() for x in log.get("topics", [])]
            if log["address"].lower() != address.lower() or not start <= b <= end:
                continue
            if any(w is not None and (i >= len(t) or t[i] != w) for i, w in enumerate(want)):
                continue
            out.append({"tx": log["transactionHash"], "block": b, "topics": t, "data": log.get("data", "0x")})
        start = end + 1
    return out


def main(argv):
    if len(argv) < 5:
        print(__doc__, file=sys.stderr)
        return 4
    url, address, lo, hi = argv[1], argv[2], int(argv[3]), int(argv[4])
    try:
        logs = read_logs(Rpc(url), address, lo, hi, argv[5:], int(os.environ.get("LOG_CHUNK", "100")))
    except RpcError as e:
        print(f"logs: unknown: {e}", file=sys.stderr)
        return 2
    txs = []
    for log in logs:
        if log["tx"] not in txs:
            txs.append(log["tx"])
    print(json.dumps({"count": len(logs), "txs": txs, "logs": logs}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
