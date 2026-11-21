#!/usr/bin/env python3
"""Replay of our deployed exit code on a real vault; Reactive not in it.

What it does (read-only: eth_getCode, eth_call, eth_simulateV1 on public endpoints; nothing is signed or sent):
  1. Reads the runtime code of the 18 Nov 2026 NoticeExit from Base Sepolia (the deployed bytes, immutables included).
  2. On Ethereum mainnet state at block 26,406,895, with eth_simulateV1 state overrides:
       - that runtime code at its own address (empty on mainnet), storage slot 0 (nextWatchId) set to 1 as deployed;
       - at its REGISTRY address, code that answers true to every call (so the real vault is accepted);
       - at its callback proxy address, a small forwarder that calls exit() with an exact gas amount and reports the
         gas the call used.
  3. In one simulated block: the real holder approves the exit contract for its shares of Gauntlet USDC Frontier
     (a Morpho Vault V2), arms a watch (kinds 7, mode 0, all shares), and the forwarder calls exit() with the payload
     our reactive contract builds for the real Submit in transaction 0x335fe388... (decreaseTimelock of
     setIsAllocator), with the gas the Base Sepolia callback proxy forwards for a callback limit of 600,000 and of
     1,000,000 (forwarded = (limit - 23,340) x 63 / 64 - 150,000, SPEC.md section 12).
  4. Reads the holder's USDC before and after, and the WatchEnded log.

Asserts: at 1,000,000 the watch ends redeemed and the holder's USDC rises by exactly WatchEnded.assets; at 600,000 the
deposit is not redeemed. Exit code 1 if either does not hold, 2 if a read failed. Writes the result as JSON
(default status/replay-mainnet.json). Standard library only.

    python3 scripts/replay_mainnet.py [--out status/replay-mainnet.json]
"""

import argparse
import datetime
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from keccak import selector, topic  # noqa: E402
from rpclib import Rpc, RpcError, pad32, uint, word  # noqa: E402

LABEL = "replay of our deployed exit code on a real vault; Reactive not in it"
BLOCK = 26_406_895
ETH_ENDPOINTS = ["https://eth.drpc.org", "https://ethereum-rpc.publicnode.com", "https://eth.merkle.io"]
BASE_ENDPOINTS = ["https://sepolia.base.org", "https://base-sepolia-rpc.publicnode.com"]

EXIT = "0xEf1BCfeA1218c606C2AEDE19D1d25bc141be84B8"        # NoticeExit, Base Sepolia, 18 Nov 2026
REACTIVE = "0x00E4996c7255B919B619902E1Ac4b254D3c3f014"    # NoticeReactive, Lasna (its _CALLBACK_SENDER)
VAULT = "0x9a1D6bd5b8642C41F25e0958129B85f8E1176F3e"       # Gauntlet USDC Frontier (Morpho Vault V2), mainnet
HOLDER = "0xa69abE7a806a1b75E148b1d7977B87CC3e0fEE94"      # a holder of its shares
USDC = "0xA0b86991c6218b36c1D19D4a2e9Eb0cE3606eB48"
SUBMIT_TX = "0x335fe3887288e04ddf6daf958b0634cd211dddd5f8bd260aaafd62ee694a2441"
SUBMIT_LOG_INDEX = 259
SUBMIT_SELECTOR = selector("decreaseTimelock(bytes4,uint256)")  # a default watched kind
LIMITS = [600_000, 1_000_000]
WATCH_ID = 1  # storage slot 0 (nextWatchId) is set to 1 as deployed, so the first arm gets id 1

# Answers 32 bytes of 1 to every call: PUSH1 1 PUSH1 0 MSTORE PUSH1 32 PUSH1 0 RETURN
TRUE_CODE = "0x600160005260206000f3"
# Forwarder. Calldata: gas (32) | target (32) | payload. Calls target with exactly `gas`, then returns
# success (32) | gas used by the CALL opcode, overhead included (32) | the call's return data.
FORWARDER = ("0x"
             "60403603"      # len = calldatasize - 64
             "80"            # dup len
             "6040" "6000"   # offset 0x40, dest 0
             "37"            # calldatacopy(0, 0x40, len)
             "5a"            # g0 = gas
             "6000" "6000"   # retSize 0, retOffset 0
             "83"            # argsSize = len (dup4: stack len g0 0 0 -> len)
             "6000" "6000"   # argsOffset 0, value 0
             "602035"        # target = calldataload(0x20)
             "600035"        # gas = calldataload(0)
             "f1"            # call
             "5a"            # g1 = gas
             "82"            # dup3 -> g0
             "03"            # g0 - g1
             "602052"        # mstore(0x20, used)
             "600052"        # mstore(0, success)
             "3d" "6000" "6040" "3e"   # returndatacopy(0x40, 0, returndatasize)
             "3d" "6040" "01" "6000" "f3")  # return(0, 0x40 + returndatasize)

WATCH_ENDED = topic("WatchEnded(uint256,uint256,uint8,uint8,uint256,uint256)")
WATCH_ARMED = topic("WatchArmed(uint256,address,address,uint8,uint8,uint256)")
REDEEM_REVERTED = topic("RedeemReverted(uint256,bytes)")
SUBMIT = topic("Submit(bytes4,bytes,uint256)")
TRANSFER = topic("Transfer(address,address,uint256)")


def forwarded(limit):
    return (limit - 23_340) * 63 // 64 - 150_000


def enc_bytes(data_hex):
    d = data_hex[2:] if data_hex.startswith("0x") else data_hex
    n = len(d) // 2
    return pad32(n) + d + "0" * ((64 - len(d) % 64) % 64)


def call_data(sig, *words, tail=""):
    return selector(sig) + "".join(words) + tail


def submit_payload(eth, tx):
    """The `data` of the Submit log in the transaction, as our reactive contract forwards it (at most 256 bytes)."""
    rec = eth.receipt(tx)
    if rec.get("status") not in ("0x1", 1):
        raise RpcError(f"{tx} did not succeed")
    for log in rec["logs"]:
        # The transaction holds several Submit logs; the one replayed is the decreaseTimelock at SUBMIT_LOG_INDEX.
        if (log["address"].lower() == VAULT.lower() and log["topics"][0].lower() == SUBMIT
                and int(log["logIndex"], 16) == SUBMIT_LOG_INDEX):
            if log["topics"][1][:10].lower() != SUBMIT_SELECTOR:
                raise RpcError(f"log {SUBMIT_LOG_INDEX} of {tx} is selector {log['topics'][1][:10]}, not {SUBMIT_SELECTOR}")
            data = log["data"][2:]
            off = int(data[0:64], 16) * 2
            n = int(data[off:off + 64], 16)
            payload = "0x" + data[off + 64:off + 64 + 2 * n]
            return payload, int(rec["blockNumber"], 16), int(data[64:128], 16)
    raise RpcError(f"no Submit of {VAULT} at log index {SUBMIT_LOG_INDEX} in {tx}")


def simulate(eth, exit_code, registry, proxy, payload, limit, shares):
    gas = forwarded(limit)
    exit_args = (pad32(REACTIVE) + pad32(WATCH_ID) + pad32(VAULT) + pad32(6 * 32) + pad32(int(SUBMIT_TX, 16)) + pad32(1)
                 + enc_bytes(payload))
    exit_call = selector("exit(address,uint256,address,bytes,uint256,uint8)") + exit_args
    fwd = "0x" + pad32(gas) + pad32(EXIT) + exit_call[2:]
    bal = call_data("balanceOf(address)", pad32(HOLDER))
    calls = [
        {"from": HOLDER, "to": USDC, "data": bal},
        {"from": HOLDER, "to": VAULT, "data": call_data("approve(address,uint256)", pad32(EXIT), pad32(shares))},
        {"from": HOLDER, "to": EXIT, "data": call_data("arm(address,uint8,uint8,uint256)", pad32(VAULT), pad32(7),
                                                       pad32(0), pad32((1 << 256) - 1))},
        {"from": HOLDER, "to": proxy, "data": fwd, "gas": hex(gas + 200_000)},
        {"from": HOLDER, "to": USDC, "data": bal},
        {"from": HOLDER, "to": VAULT, "data": call_data("balanceOf(address)", pad32(HOLDER))},
    ]
    overrides = {
        EXIT: {"code": exit_code, "stateDiff": {"0x" + pad32(0): "0x" + pad32(1)}},
        registry: {"code": TRUE_CODE},
        proxy: {"code": FORWARDER},
    }
    res = eth.call("eth_simulateV1", [{"blockStateCalls": [{"stateOverrides": overrides, "calls": calls}],
                                       "validation": False}, hex(BLOCK)])
    out = res[0]["calls"]
    for i, c in enumerate(out[:3]):
        if c.get("status") not in ("0x1", 1):
            raise RpcError(f"setup call {i} failed: {c.get('error')} {c.get('returnData', '')[:200]}")
    fwd_ret = out[3].get("returnData", "0x")
    fwd_ok = out[3].get("status") in ("0x1", 1)
    exit_success = fwd_ok and uint(fwd_ret, 0) == 1
    call_gas = uint(fwd_ret, 1) if fwd_ok and len(fwd_ret) >= 130 else None
    exit_return = "0x" + fwd_ret[2 + 128:] if fwd_ok else None
    armed = [l for l in out[2].get("logs", []) if l["topics"][0].lower() == WATCH_ARMED]
    ended = [l for l in out[3].get("logs", []) if l["topics"][0].lower() == WATCH_ENDED
             and l["address"].lower() == EXIT.lower()]
    reverted = [l for l in out[3].get("logs", []) if l["topics"][0].lower() == REDEEM_REVERTED]
    usdc_to_holder = sum(int(l["data"], 16) for l in out[3].get("logs", [])
                         if l["topics"][0].lower() == TRANSFER and l["address"].lower() == USDC.lower()
                         and len(l["topics"]) == 3 and l["topics"][2][-40:].lower() == HOLDER[2:].lower())
    before, after = uint(out[0]["returnData"]), uint(out[4]["returnData"])
    shares_after = uint(out[5]["returnData"])
    if not armed or int(armed[0]["topics"][1], 16) != WATCH_ID:
        raise RpcError(f"the simulated arm did not give watch id {WATCH_ID}: {armed}")
    r = {
        "callbackGasLimit": limit,
        "gasForwardedToExit": gas,
        "exitCallSucceeded": exit_success,
        "gasUsedByTheCall": call_gas,
        "exitRevertData": None if exit_success or exit_return is None else exit_return[:200],
        # An empty revert after using all the gas it was given: the exit ran out of gas (no WatchEnded; on the real
        # network the callback fails and the watch stays active on Base).
        "outOfGas": (not exit_success) and exit_return == "0x" and call_gas is not None and call_gas >= gas,
        "watchId": int(armed[0]["topics"][1], 16) if armed else None,
        "watchEnded": None,
        "redeemReverted": bool(reverted),
        "holderUsdcBefore": str(before),
        "holderUsdcAfter": str(after),
        "holderUsdcDelta": str(after - before),
        "usdcTransferredToHolderInExit": str(usdc_to_holder),
        "holderSharesAfter": str(shares_after),
        "simulatedBlock": int(res[0]["number"], 16),
    }
    if ended:
        d = ended[0]["data"]
        r["watchEnded"] = {"outcome": uint(d, 0), "reason": uint(d, 1), "shares": str(uint(d, 2)),
                           "assets": str(uint(d, 3)), "originTxHash": ended[0]["topics"][2]}
    return r


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "status",
                                                  "replay-mainnet.json"))
    a = ap.parse_args(argv)
    eth, base = Rpc(ETH_ENDPOINTS), Rpc(BASE_ENDPOINTS)
    try:
        exit_code = base.code(EXIT)
        if not exit_code or exit_code == "0x":
            raise RpcError("no code at the exit contract on Base Sepolia")
        registry = "0x" + base.eth_call(EXIT, selector("REGISTRY()"))[-40:]
        proxy = "0x" + base.eth_call(EXIT, selector("_SERVICE_PROVIDER()"))[-40:]
        sender = "0x" + base.eth_call(EXIT, selector("_CALLBACK_SENDER()"))[-40:]
        next_id_deployed = int(base.call("eth_getStorageAt", [EXIT, "0x0", "latest"]), 16)
        next_id_view = uint(base.eth_call(EXIT, selector("nextWatchId()")))
        if next_id_deployed != next_id_view:
            raise RpcError(f"storage slot 0 ({next_id_deployed}) is not nextWatchId ({next_id_view}): layout differs")
        if sender.lower() != REACTIVE.lower():
            raise RpcError(f"_CALLBACK_SENDER is {sender}, expected {REACTIVE}")
        for addr in (EXIT, registry, proxy):
            c = eth.code(addr, hex(BLOCK))
            if c not in ("0x", "0x0", ""):
                raise RpcError(f"{addr} has code on mainnet; an override would replace a real contract")
        payload, submit_block, executable_at = submit_payload(eth, SUBMIT_TX)
        shares = uint(eth.eth_call(VAULT, call_data("balanceOf(address)", pad32(HOLDER)), hex(BLOCK)))
        name_hex = eth.eth_call(VAULT, selector("name()"), hex(BLOCK))
        n = uint(name_hex, 1)
        vault_name = bytes.fromhex(word(name_hex, 2)[:2 * n]).decode()
        assets = uint(eth.eth_call(VAULT, call_data("previewRedeem(uint256)", pad32(shares)), hex(BLOCK)))
        results = [simulate(eth, exit_code, registry, proxy, payload, lim, shares) for lim in LIMITS]
    except RpcError as e:
        print(f"STOP: a read failed: {e}", file=sys.stderr)
        return 2

    failures = []
    hi, lo = results[1], results[0]
    he = hi["watchEnded"]
    if not (hi["exitCallSucceeded"] and he and he["outcome"] == 0):
        failures.append("at 1,000,000 the watch did not end redeemed")
    elif str(hi["holderUsdcDelta"]) != he["assets"]:
        failures.append(f"at 1,000,000 the holder's USDC rose by {hi['holderUsdcDelta']}, WatchEnded says {he['assets']}")
    le = lo["watchEnded"]
    if lo["exitCallSucceeded"] and le and le["outcome"] == 0:
        failures.append("at 600,000 the deposit was redeemed (expected: not redeemed)")
    if int(lo["holderUsdcDelta"]) != 0:
        failures.append(f"at 600,000 the holder's USDC moved by {lo['holderUsdcDelta']}")

    doc = {
        "label": LABEL,
        "readAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "method": "eth_simulateV1 on Ethereum mainnet state at the block below, with state overrides; nothing sent",
        "block": BLOCK,
        "exitCode": {"chain": "Base Sepolia (84532)", "address": EXIT, "bytes": len(exit_code) // 2 - 1,
                     "registryOverridden": registry, "callbackProxyOverridden": proxy, "callbackSender": sender},
        "vault": {"address": VAULT, "name": vault_name, "asset": USDC},
        "holder": {"address": HOLDER, "shares": str(shares), "previewRedeem": str(assets)},
        "change": {"submitTx": SUBMIT_TX, "logIndex": SUBMIT_LOG_INDEX, "block": submit_block, "payload": payload, "executableAt": executable_at},
        "gasFormula": "forwarded = (limit - 23340) * 63 / 64 - 150000 (Base Sepolia proxy, SPEC.md section 12)",
        "results": results,
        "asserts": {"redeemedAt1000000AndDeltaEqualsAssets": not any("1,000,000" in f for f in failures),
                    "notRedeemedAt600000": not any("600,000" in f for f in failures)},
        "failures": failures,
    }
    out = os.path.normpath(a.out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps(doc, indent=2) + "\n")
    print(json.dumps(doc, indent=2))
    print(f"written: {out}")
    if failures:
        print("FAIL: " + "; ".join(failures), file=sys.stderr)
        return 1
    print("replay asserts held")
    return 0


if __name__ == "__main__":
    sys.exit(main())
