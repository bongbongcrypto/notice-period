"""JSON-RPC reads over several public endpoints, standard library only (used by bytecode_match, runs, replay).

Every failed or malformed answer is "unknown": it is retried, then the next endpoint is tried, and only when every
endpoint has failed does the call raise RpcError. Nothing here signs or sends a transaction.
"""

import json
import time
import urllib.error
import urllib.request

AGENT = "rpc-client"  # sepolia.base.org refuses urllib's default agent with 403

ENDPOINTS = {
    84532: ["https://sepolia.base.org", "https://base-sepolia-rpc.publicnode.com"],
    5318007: ["https://lasna-rpc.rnk.dev/"],
    1: ["https://ethereum-rpc.publicnode.com", "https://eth.drpc.org"],
}


class RpcError(Exception):
    pass


class Rpc:
    """Rpc(urls) or Rpc.for_chain(chain_id). `post` may be replaced by a stub in tests."""

    def __init__(self, urls, tries=3, timeout=30, pause=1.5):
        self.urls = [urls] if isinstance(urls, str) else list(urls)
        self.tries, self.timeout, self.pause = tries, timeout, pause

    @classmethod
    def for_chain(cls, chain_id, **kw):
        if chain_id not in ENDPOINTS:
            raise RpcError(f"no endpoint known for chain {chain_id}")
        return cls(ENDPOINTS[chain_id], **kw)

    def post(self, url, payload):
        req = urllib.request.Request(url, data=json.dumps(payload).encode(),
                                     headers={"Content-Type": "application/json", "User-Agent": AGENT})
        with urllib.request.urlopen(req, timeout=self.timeout) as r:
            return json.load(r)

    def call(self, method, params):
        errors = []
        for url in self.urls:
            for attempt in range(self.tries):
                try:
                    body = self.post(url, {"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
                    if not isinstance(body, dict):
                        raise RpcError("answer is not an object")
                    if body.get("error") is not None:
                        err = body["error"]
                        # An execution error is an answer, not an outage: hand it to the caller.
                        if isinstance(err, dict) and err.get("code") in (3, -32015) or "revert" in str(err).lower():
                            raise ExecutionReverted(err)
                        raise RpcError(f"{method}: {err}")
                    if "result" not in body:
                        raise RpcError(f"{method}: no result")
                    return body["result"]
                except ExecutionReverted:
                    raise
                except (RpcError, urllib.error.URLError, OSError, ValueError) as e:
                    errors.append(f"{url} try {attempt + 1}: {type(e).__name__}: {str(e)[:160]}")
                    time.sleep(self.pause * (attempt + 1))
        raise RpcError(f"{method} failed on every endpoint: " + " | ".join(errors[-3:]))

    # helpers
    def code(self, address, block="latest"):
        return self.call("eth_getCode", [address, block])

    def receipt(self, tx):
        r = self.call("eth_getTransactionReceipt", [tx])
        if r is None:
            raise RpcError(f"no receipt for {tx} (unknown, not absent)")
        return r

    def tx(self, tx):
        r = self.call("eth_getTransactionByHash", [tx])
        if r is None:
            raise RpcError(f"no transaction {tx} (unknown, not absent)")
        return r

    def block(self, number):
        b = self.call("eth_getBlockByNumber", [hex(number) if isinstance(number, int) else number, False])
        if b is None:
            raise RpcError(f"no block {number}")
        return b

    def eth_call(self, to, data, block="latest"):
        return self.call("eth_call", [{"to": to, "data": data}, block])


class ExecutionReverted(Exception):
    pass


def word(hexdata, i):
    d = hexdata[2:] if hexdata.startswith("0x") else hexdata
    return d[64 * i:64 * i + 64]


def uint(hexdata, i=0):
    return int(word(hexdata, i), 16)


def pad32(value):
    if isinstance(value, str):
        return value.lower().replace("0x", "").rjust(64, "0")
    return format(value, "064x")


def addr_of_topic(t):
    return "0x" + t[-40:]


def same(a, b):
    return isinstance(a, str) and isinstance(b, str) and a.lower() == b.lower()
