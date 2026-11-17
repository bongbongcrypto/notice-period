#!/usr/bin/env python3
"""Plays the Reactive Network between two local anvil chains, for the CI dry run only.

Base anvil (chain 84532) holds the mock callback proxy at the real proxy address; Lasna anvil (chain 5318007) holds
the mock system contract at 0x8888...8888 and the CRON source at 0x...fffFfF. This relay:
  - copies every Base log to MockSystem.deliver(reactive, record) on Lasna (the mock checks subscriptions);
  - every --cron seconds emits a Cron10 tick on Lasna and delivers it the same way;
  - forwards every callback the reactive contracts asked for to MockCallbackProxy.deliver on Base.
It sends with its own anvil account (RELAY_KEY), so the deployer's nonces are untouched.
Stdlib only; transactions go through `cast send`.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

SYSTEM = "0x8888888888888888888888888888888888888888"
CRON = "0x0000000000000000000000000000000000fffFfF"
RECORD = "(uint256,address,uint256,uint256,uint256,uint256,bytes,uint256,uint256,uint256,uint256,uint256)"


def rpc(url, method, params):
    req = urllib.request.Request(
        url, data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
        headers={"content-type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=10) as r:
        body = json.load(r)
    if "error" in body:
        raise RuntimeError(f"{method}: {body['error']}")
    return body["result"]


def cast(*args):
    p = subprocess.run(["cast", *args], capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(f"cast {args[0]} failed: {p.stderr.strip()[-500:]}")
    return p.stdout.strip()


def send(url, key, to, sig, *args):
    out = json.loads(cast("send", "--json", "--rpc-url", url, "--private-key", key, to, sig, *args))
    if out.get("status") not in ("0x1", 1, True):
        raise RuntimeError(f"{sig} reverted: {out.get('transactionHash')}")
    return out["transactionHash"]


def record(log, chain_id):
    topics = log["topics"] + ["0x0"] * (4 - len(log["topics"]))
    fields = [
        str(chain_id), log["address"], *[str(int(t, 16)) for t in topics[:4]], log["data"] or "0x",
        str(int(log["blockNumber"], 16)), str(len(log["topics"])), str(int(log["blockHash"], 16)),
        str(int(log["transactionHash"], 16)), str(int(log["logIndex"], 16)),
    ]
    return "(" + ",".join(fields) + ")"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--lasna", required=True)
    ap.add_argument("--proxy", required=True)
    ap.add_argument("--reactive", action="append", required=True)
    ap.add_argument("--cron", type=float, default=10.0)
    ap.add_argument("--duration", type=float, default=1200.0)
    a = ap.parse_args()
    key = os.environ["RELAY_KEY"]
    base_chain = int(rpc(a.base, "eth_chainId", []), 16)
    lasna_chain = int(rpc(a.lasna, "eth_chainId", []), 16)
    base_next = int(rpc(a.base, "eth_blockNumber", []), 16) + 1
    lasna_next = int(rpc(a.lasna, "eth_blockNumber", []), 16) + 1
    done = int(cast("call", "--rpc-url", a.lasna, SYSTEM, "callbackCount()(uint256)").split()[0])
    last_tick = 0.0
    end = time.time() + a.duration
    print(f"relay: base {base_chain} from {base_next}, lasna {lasna_chain} from {lasna_next}, reactive {a.reactive}",
          flush=True)
    while time.time() < end:
        # origin logs -> reactive contracts
        head = int(rpc(a.base, "eth_blockNumber", []), 16)
        if head >= base_next:
            logs = rpc(a.base, "eth_getLogs", [{"fromBlock": hex(base_next), "toBlock": hex(head)}])
            for log in logs:
                for target in a.reactive:
                    send(a.lasna, key, SYSTEM, f"deliver(address,{RECORD})", target, record(log, base_chain))
            base_next = head + 1
        # CRON
        if time.time() - last_tick >= a.cron:
            send(a.lasna, key, CRON, "tick()")
            last_tick = time.time()
        head = int(rpc(a.lasna, "eth_blockNumber", []), 16)
        if head >= lasna_next:
            logs = rpc(a.lasna, "eth_getLogs", [{"fromBlock": hex(lasna_next), "toBlock": hex(head), "address": CRON}])
            lasna_next = head + 1
            for log in logs:
                for target in a.reactive:
                    send(a.lasna, key, SYSTEM, f"deliver(address,{RECORD})", target, record(log, lasna_chain))
            lasna_next = max(lasna_next, int(rpc(a.lasna, "eth_blockNumber", []), 16) + 1)
        # callbacks -> Base
        count = int(cast("call", "--rpc-url", a.lasna, SYSTEM, "callbackCount()(uint256)").split()[0])
        while done < count:
            raw = cast("call", "--rpc-url", a.lasna, SYSTEM, "callbackAt(uint256)((address,uint256,address,uint64,bytes))",
                       str(done))
            m = re.match(r"^\((0x[0-9a-fA-F]{40}), (\d+)(?: \[[^\]]*\])?, (0x[0-9a-fA-F]{40}), (\d+)(?: \[[^\]]*\])?, (0x[0-9a-fA-F]*)\)$",
                         raw)
            if not m:
                raise RuntimeError(f"cannot read callback {done}: {raw[:200]}")
            sender, chain, recipient, gas, payload = m.groups()
            if int(chain) == base_chain:
                tx = send(a.base, key, a.proxy, "deliverWithGas(address,bytes,address,uint256)", recipient, payload,
                          sender, gas)
                print(f"relay: callback {done} from {sender} to {recipient}: {tx}", flush=True)
            done += 1
        time.sleep(1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
