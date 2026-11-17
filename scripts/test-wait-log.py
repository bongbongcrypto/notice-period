#!/usr/bin/env python3
"""Tests scripts/wait-log.py against a local stub RPC (no network).

The stub copies what sepolia.base.org did on the first hello loop (2026-11-18): HTTP 403 for urllib's default
User-Agent, HTTP 413 for eth_getLogs with toBlock "latest" or a span over 100 blocks, and a head that moves several
blocks a second. Further cases: a failed chunk must not be skipped, a lagging node's late logs must still be found,
logs that do not match the filter must be refused, and a missing log must end in exit 3 at the timeout.

Run: python3 scripts/test-wait-log.py   (WAIT_LOG_SCRIPT=path overrides the script under test)
"""
import json
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.environ.get("WAIT_LOG_SCRIPT", os.path.join(HERE, "wait-log.py"))
ADDR = "0x54f731519464f60eaf3f609ffa9a8b1f5db06005"
TOPIC0 = "0x4208e51a81eead0d" + "0" * 48
TOPIC1 = "0x" + "55" * 32
TX = "0x" + "ab" * 32
FROM = 1000


class Stub:
    def __init__(self, log_block, rate=50.0, strict=True, fail_chunk_times=0, index_lag=0, wrong_logs=False):
        self.t0 = time.time()
        self.log_block = log_block
        self.rate = rate                    # blocks per second
        self.strict = strict                # 403 default UA, 413 wide or "latest" ranges
        self.fail_chunk_times = fail_chunk_times  # HTTP 500 this many times for the chunk holding the log
        self.index_lag = index_lag          # eth_getLogs sees only blocks <= head - index_lag
        self.wrong_logs = wrong_logs        # return only logs that break the filter
        self.lock = threading.Lock()
        self.requests = 0

    def head(self):
        return FROM + int((time.time() - self.t0) * self.rate)

    def handle(self, ua, body):
        with self.lock:
            self.requests += 1
        if self.strict and ua.lower().startswith("python-urllib"):
            return 403, None
        req = json.loads(body)
        method, params = req["method"], req["params"]
        if method == "eth_blockNumber":
            return 200, hex(self.head())
        if method != "eth_getLogs":
            return 200, {"error": {"code": -32601, "message": "no such method"}}
        q = params[0]
        if self.strict and (q.get("toBlock") in (None, "latest") or q.get("fromBlock") in (None, "latest")):
            return 413, None
        lo, hi = int(q["fromBlock"], 16), int(q["toBlock"], 16)
        if self.strict and hi - lo + 1 > 100:
            return 413, None
        if lo <= self.log_block <= hi and self.fail_chunk_times > 0:
            with self.lock:
                self.fail_chunk_times -= 1
            return 500, None
        seen = self.head() - self.index_lag
        out = []
        if self.wrong_logs:
            out.append({"address": "0x" + "11" * 20, "blockNumber": hex(lo), "logIndex": "0x0",
                        "topics": [TOPIC0, TOPIC1], "transactionHash": "0x" + "cd" * 32})
            out.append({"address": ADDR, "blockNumber": hex(lo), "logIndex": "0x1",
                        "topics": [TOPIC0, "0x" + "66" * 32], "transactionHash": "0x" + "ef" * 32})
        elif lo <= self.log_block <= hi and self.log_block <= seen:
            out.append({"address": ADDR, "blockNumber": hex(self.log_block), "logIndex": "0x0",
                        "topics": [TOPIC0, TOPIC1], "transactionHash": TX})
        return 200, out


def serve(stub):
    class H(BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("content-length", "0")))
            code, result = stub.handle(self.headers.get("user-agent", ""), body)
            if code != 200:
                self.send_response(code)
                self.end_headers()
                return
            ans = {"jsonrpc": "2.0", "id": 1}
            if isinstance(result, dict) and "error" in result:
                ans["error"] = result["error"]
            else:
                ans["result"] = result
            data = json.dumps(ans).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *a):
            pass

    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def run(stub, timeout):
    srv = serve(stub)
    try:
        env = dict(os.environ, LOG_POLL="0.2")
        p = subprocess.run([sys.executable, SCRIPT, f"http://127.0.0.1:{srv.server_address[1]}", "test", str(FROM),
                            ADDR, TOPIC0, str(timeout), TOPIC1], capture_output=True, text=True, env=env,
                           timeout=timeout + 30)
        return p.returncode, p.stdout.strip(), p.stderr
    finally:
        srv.shutdown()


CASES = [
    # name, stub, timeout, expected exit, expected stdout
    ("base-like RPC: 403 default UA, 413 wide/latest, fast head", lambda: Stub(log_block=FROM + 250), 20, 0, TX),
    ("log far behind a fast head (many chunks)", lambda: Stub(log_block=FROM + 5, rate=400.0), 20, 0, TX),
    ("failed chunk is read again, not skipped", lambda: Stub(log_block=FROM + 150, fail_chunk_times=3), 20, 0, TX),
    ("lagging node: log indexed late is still found", lambda: Stub(log_block=FROM + 120, index_lag=30), 20, 0, TX),
    ("logs that break the filter are refused", lambda: Stub(log_block=-1, wrong_logs=True), 3, 3, ""),
    ("no log: exit 3 at the timeout", lambda: Stub(log_block=-1), 3, 3, ""),
]


def main():
    failed = 0
    for name, make, timeout, want_rc, want_out in CASES:
        rc, out, err = run(make(), timeout)
        ok = rc == want_rc and out == want_out
        failed += not ok
        print(f"{'PASS' if ok else 'FAIL'}: {name} (exit {rc}, out {out[:20] or '-'})")
        if not ok:
            print("  stderr tail: " + " | ".join(err.strip().splitlines()[-3:]))
    print(f"{len(CASES) - failed}/{len(CASES)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
