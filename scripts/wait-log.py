#!/usr/bin/env python3
"""Polls a chain for the first log that matches a filter and prints its transaction hash.

Usage: wait-log.py RPC LABEL FROM_BLOCK ADDRESS TOPIC0 TIMEOUT_S [TOPIC1 ...]

Called by wait_log in scripts/chain.sh. Exit codes: 0 found (hash on stdout), 3 not seen within the timeout,
4 bad arguments.

Why this is a separate file (2026-11-18, first hello loop on Base Sepolia):
  - sepolia.base.org answers HTTP 403 to urllib's default User-Agent, so every request sends its own.
  - It answers HTTP 413 to eth_getLogs over a wide range or a toBlock of "latest", and Base Sepolia now makes about
    five blocks a second. So every query names both ends and spans at most LOG_CHUNK blocks (default 100).
An RPC error, an HTTP error or a malformed answer is "unknown", never "no log": the poll is retried and the scan
cursor never moves past a block that was not read. The cursor also stays LOG_LAG blocks (default 50) behind the
head, so a load-balanced node that is behind and answers "no logs" for blocks it does not have yet is read again on
the next poll. Every returned log is checked again here (address, block range, topics), so an RPC that ignores part
of the filter cannot hand back the wrong log.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

USER_AGENT = "notice-period-loop/1"


class Unknown(Exception):
    """A read whose answer is unknown (error, refusal, malformed). Never read as 'absent'."""


def rpc_call(rpc, method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(rpc, data=body, headers={"content-type": "application/json",
                                                          "user-agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            ans = json.load(r)
    except urllib.error.HTTPError as e:
        raise Unknown(f"{method}: HTTP {e.code} {e.reason}") from None
    except Exception as e:  # timeout, connection reset, bad JSON
        raise Unknown(f"{method}: {type(e).__name__}: {e}") from None
    if not isinstance(ans, dict) or "error" in ans or "result" not in ans:
        err = ans.get("error") if isinstance(ans, dict) else ans
        raise Unknown(f"{method}: error answer {str(err)[:200]}")
    return ans["result"]


def head_block(rpc):
    res = rpc_call(rpc, "eth_blockNumber", [])
    try:
        return int(res, 16)
    except (TypeError, ValueError):
        raise Unknown(f"eth_blockNumber: malformed answer {str(res)[:80]}") from None


def matches(log, addr, lo, hi, topics):
    try:
        t = [x.lower() for x in log.get("topics", [])]
        bn = int(log["blockNumber"], 16)
        return (log.get("address", "").lower() == addr and lo <= bn <= hi and t[:len(topics)] == topics
                and isinstance(log.get("transactionHash"), str))
    except (KeyError, TypeError, ValueError, AttributeError):
        return False


def scan(rpc, addr, topics, cursor, head, chunk):
    """Reads [cursor, head] in chunks. Returns (tx hash or None, last block read in full). Raises Unknown."""
    done = cursor - 1
    b = cursor
    while b <= head:
        e = min(b + chunk - 1, head)
        res = rpc_call(rpc, "eth_getLogs", [{"fromBlock": hex(b), "toBlock": hex(e), "address": addr,
                                             "topics": topics}])
        if not isinstance(res, list):
            raise Unknown(f"eth_getLogs: malformed answer {str(res)[:80]}")
        found = [x for x in res if matches(x, addr, b, e, topics)]
        if found:
            found.sort(key=lambda x: (int(x["blockNumber"], 16), int(x.get("logIndex", "0x0"), 16)))
            return found[0]["transactionHash"], e
        done = e
        b = e + 1
    return None, done


def main(argv):
    if len(argv) < 7:
        print(__doc__.splitlines()[2], file=sys.stderr)
        return 4
    rpc, label, frm, addr, topic0, timeout = argv[1:7]
    topics = [topic0.lower()] + [t.lower() for t in argv[7:]]
    addr = addr.lower()
    try:
        frm, timeout = int(frm, 0), int(timeout)
        chunk = int(os.environ.get("LOG_CHUNK", "100"))
        lag = int(os.environ.get("LOG_LAG", "50"))
        poll = float(os.environ.get("LOG_POLL", "3"))
    except ValueError as e:
        print(f"{label}: bad argument: {e}", file=sys.stderr)
        return 4
    if chunk < 1 or lag < 0 or frm < 0:
        print(f"{label}: bad chunk, lag or from block", file=sys.stderr)
        return 4
    cursor = frm
    start = time.time()
    while True:
        try:
            head = head_block(rpc)
            tx, done = scan(rpc, addr, topics, cursor, head, chunk)
            if tx:
                print(f"{label}: tx {tx} after {int(time.time() - start)} s of waiting", file=sys.stderr)
                print(tx)
                return 0
            # Everything up to `done` was read and had no match; keep the last `lag` blocks for a re-read.
            cursor = max(cursor, min(done, head - lag) + 1)
        except Unknown as e:
            print(f"{label}: log query failed ({e}), retrying (state unknown, not 'absent')", file=sys.stderr)
        if time.time() - start >= timeout:
            print(f"{label}: not seen within {timeout} s (scanned from {frm}, cursor {cursor})", file=sys.stderr)
            return 3
        time.sleep(poll)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
