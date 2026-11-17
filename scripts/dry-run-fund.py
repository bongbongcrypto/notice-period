#!/usr/bin/env python3
"""CI assertions for fund.sh. Stdlib only; all RPCs are loopback anvils started by dry-run-fund.sh.

Transactions and receipts are real local-chain records. A cast shim only injects a code change immediately
before broadcast, so estimation succeeds but the faucet transaction mines with status 0. It never fakes a
transaction or receipt. Destination balance changes model delayed credit, not an actual cross-chain relay.
"""

import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
import urllib.request
from urllib.parse import urlsplit

ACCOUNT = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
# Public accounts 0 and 1 of anvil's default mnemonic. Refuse any other keys, even if CI is misconfigured.
KEY0 = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
KEY1 = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
FAUCET = "0x9b9BB25f1A81078C544C829c5EB7822d747Cf434"
BRIDGE = "0xfd0Bf71F60660E2f608ed56e1659C450eB113120"
COIN = 10**18
RPCS = [os.environ[n] for n in ("SEPOLIA_RPC", "BASE_RPC", "LASNA_RPC")]
SEPOLIA, BASE, LASNA = RPCS
REAL_CAST = shutil.which("cast")
LOGS = Path(sys.argv[1]).resolve()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def rpc(url, method, params):
    require(urlsplit(url).hostname == "127.0.0.1" and urlsplit(url).scheme == "http", "non-local RPC refused")
    req = urllib.request.Request(
        url, data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
        headers={"content-type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=5) as response:
        body = json.load(response)
    require("error" not in body, f"local RPC {method} failed: {body.get('error')}")
    return body["result"]


def tool(*args):
    return subprocess.run(args, capture_output=True, text=True, check=True, timeout=30).stdout.strip()


def balance(url):
    return int(rpc(url, "eth_getBalance", [ACCOUNT, "latest"]), 16)


def set_balance(url, value):
    rpc(url, "anvil_setBalance", [ACCOUNT, hex(value)])


def transactions(url=SEPOLIA):
    head = int(rpc(url, "eth_blockNumber", []), 16)
    return [tx for number in range(head + 1)
            for tx in rpc(url, "eth_getBlockByNumber", [hex(number), True])["transactions"]]


def assert_sends(count):
    txs = transactions()
    require(len(txs) == count, f"expected {count} Sepolia sends, saw {len(txs)}")
    require(not transactions(BASE) and not transactions(LASNA), "fund sent on a destination chain")
    return txs


def assert_transaction(tx, to, value, calldata, status=1):
    require(tx["from"].lower() == ACCOUNT, "unexpected sender")
    require(tx["to"].lower() == to.lower(), "wrong transaction destination/order")
    require(int(tx["value"], 16) == value, "wrong transaction value")
    require(tx["input"].lower() == calldata.lower(), "wrong selector or arguments")
    receipt = rpc(SEPOLIA, "eth_getTransactionReceipt", [tx["hash"]])
    require(int(receipt["status"], 16) == status, "wrong receipt status")


def main():
    require(os.environ.get("DEPLOY_KEY") == KEY0 and os.environ.get("RELAY_KEY") == KEY1,
            "fund dry run requires only the two public default anvil keys")
    for url, chain in zip(RPCS, (11155111, 84532, 5318007)):
        require(int(rpc(url, "eth_chainId", []), 16) == chain, "dry-run chain configuration mismatch")
    codes = {name: tool("forge", "inspect", f"test/mocks/FundMocks.sol:{name}", "deployedBytecode")
             for name in ("MockFundFaucet", "MockFundBridge", "MockFundRevertingFaucet")}
    rpc(SEPOLIA, "anvil_setCode", [FAUCET, codes["MockFundFaucet"]])
    rpc(SEPOLIA, "anvil_setCode", [BRIDGE, codes["MockFundBridge"]])
    set_balance(SEPOLIA, 100 * COIN)
    set_balance(BASE, COIN)
    set_balance(LASNA, 5 * COIN)
    snapshots = {url: rpc(url, "evm_snapshot", []) for url in RPCS}

    # Fault injection goes through the actual cast binary after changing the local faucet's bytecode.
    shim = LOGS / "bin"
    shim.mkdir(exist_ok=True)
    (shim / "cast").write_text('''#!/usr/bin/env bash
set -euo pipefail
if [ "${1-}" = send ] && [ "${FUND_TEST_REVERT_ON_SEND-}" = 1 ]; then
  "$FUND_REAL_CAST" rpc --rpc-url "$SEPOLIA_RPC" anvil_setCode "$FAUCET_ADDRESS" "$FUND_REVERT_CODE" >/dev/null
fi
exec "$FUND_REAL_CAST" "$@"
''', encoding="utf-8")
    (shim / "cast").chmod(0o755)
    env = dict(os.environ, DEPLOY_KEY=KEY0, TESTNET_ADDRESS=ACCOUNT.upper().replace("0X", "0x"),
               FAUCET_ADDRESS=FAUCET, BRIDGE_ADDRESS=BRIDGE, REACT_ETH="0.1", BASE_ETH="0.05",
               FUND_POLL_TIMEOUT="45", FUND_REAL_CAST=REAL_CAST, FUND_TEST_REVERT_ON_SEND="0",
               FUND_REVERT_CODE=codes["MockFundRevertingFaucet"], PATH=f"{shim}:{os.environ['PATH']}")
    # Do not inherit fault controls or a summary destination from another dry run.
    env.pop("BASH_ENV", None)
    request_data = tool(REAL_CAST, "calldata", "request(address)", ACCOUNT)
    bridge_data = tool(REAL_CAST, "calldata", "depositETH(uint32,bytes)", "200000", "0x")

    def reset():
        for url in RPCS:
            require(rpc(url, "evm_revert", [snapshots[url]]), "snapshot restore failed")
            snapshots[url] = rpc(url, "evm_snapshot", [])

    def run(name, overrides=None, refusal=None, credit=False):
        case_env = dict(env, **(overrides or {}))
        summary = LOGS / f"{name}.md"
        summary.write_text("", encoding="utf-8")
        case_env["GITHUB_STEP_SUMMARY"] = str(summary)
        credited = set()
        end = time.monotonic() + 90
        credit_at = time.monotonic() + 2  # let fund.sh read the original balances first
        with (LOGS / f"{name}.log").open("w", encoding="utf-8") as log:
            process = subprocess.Popen(["bash", "scripts/fund.sh"], env=case_env, stdout=log,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            try:
                while process.poll() is None:
                    require(time.monotonic() < end, f"{name}: fund script hung")
                    if credit and time.monotonic() >= credit_at:
                        for tx in transactions():
                            to = tx["to"].lower()
                            receipt = rpc(SEPOLIA, "eth_getTransactionReceipt", [tx["hash"]])
                            if to in credited or int(receipt["status"], 16) != 1:
                                continue
                            if to == FAUCET.lower():
                                set_balance(LASNA, 5 * COIN + int(tx["value"], 16) * 100)
                            elif to == BRIDGE.lower():
                                set_balance(BASE, COIN + int(tx["value"], 16))
                            credited.add(to)
                    time.sleep(0.1)
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        output = (LOGS / f"{name}.log").read_text(encoding="utf-8")
        report = summary.read_text(encoding="utf-8")
        if refusal:
            require(process.returncode != 0 and refusal in output, f"{name}: expected refusal '{refusal}':\n{output}")
        else:
            require(process.returncode == 0, f"{name}: fund failed:\n{output}")
        print(f"fund dry run: {name} returned the expected exit status", flush=True)
        return report

    def refuse(name, overrides, message, prepare=None):
        reset()
        if prepare:
            prepare()
        run(name, overrides, refusal=message)
        assert_sends(0)

    reset()
    report = run("happy", credit=True)
    txs = assert_sends(2)
    assert_transaction(txs[0], FAUCET, COIN // 10, request_data)
    assert_transaction(txs[1], BRIDGE, COIN // 20, bridge_data)
    require(balance(LASNA) == 15 * COIN and balance(BASE) == COIN + COIN // 20, "simulated credits missing")
    require("WARNING" not in report and "| Before | After | Change |" in report, "bad happy-path summary")
    require("| 5.000000000000000000 | 15.000000000000000000 | 10.000000000000000000 |" in report,
            "Lasna balance change missing from summary")
    require("| 1.000000000000000000 | 1.050000000000000000 | 0.050000000000000000 |" in report,
            "Base balance change missing from summary")
    for tx in txs:
        require(f"https://sepolia.etherscan.io/tx/{tx['hash']}" in report, "transaction explorer link missing")
    for explorer in ("https://base-sepolia.blockscout.com/address/", "https://lasna.reactscan.net/address/"):
        require(explorer in report, "destination explorer link missing")

    # The cap must be rejected even with an unreachable RPC, before any funding transaction.
    refuse("react-six", {"REACT_ETH": "6", "SEPOLIA_RPC": "http://127.0.0.1:1"}, "react_eth exceeds")
    refuse("react-cap-one-wei", {"REACT_ETH": "2.000000000000000001"}, "react_eth exceeds")
    refuse("base-cap-one-wei", {"BASE_ETH": "0.200000000000000001"}, "base_eth exceeds")
    for field in ("REACT_ETH", "BASE_ETH"):
        for i, value in enumerate(("-0.1", "1e-2", ".1", "1.", " 0.1", "0.1234567890123456789")):
            refuse(f"decimal-{field}-{i}", {field: value}, "not a plain decimal")
    refuse("both-zero", {"REACT_ETH": "0.000", "BASE_ETH": "0"}, "both funding legs are zero")
    refuse("empty-address", {"TESTNET_ADDRESS": ""}, "TESTNET_ADDRESS is not set")
    refuse("empty-key", {"DEPLOY_KEY": ""}, "DEPLOY_KEY is not set")
    refuse("wrong-key", {"DEPLOY_KEY": KEY1}, "key address differs")
    for field, wrong in (("SEPOLIA_RPC", BASE), ("BASE_RPC", LASNA), ("LASNA_RPC", BASE)):
        refuse(f"wrong-chain-{field}", {field: wrong}, "chain id is")
    refuse("insufficient", {}, "balance below what this run needs",
           lambda: set_balance(SEPOLIA, 159 * COIN // 1000))
    for name, address in (("faucet", FAUCET), ("bridge", BRIDGE)):
        refuse(f"no-code-{name}", {}, "no contract code",
               lambda a=address: rpc(SEPOLIA, "anvil_setCode", [a, "0x"]))
    refuse("bridge-estimate-revert", {}, "funding gas estimate failed",
           lambda: rpc(SEPOLIA, "anvil_setCode", [BRIDGE, codes["MockFundRevertingFaucet"]]))

    # Estimation succeeds, then the shim installs a reverting faucet immediately before the real broadcast.
    reset()
    report = run("faucet-receipt-revert", {"FUND_TEST_REVERT_ON_SEND": "1"}, refusal="receipt status is not 1")
    txs = assert_sends(1)
    assert_transaction(txs[0], FAUCET, COIN // 10, request_data, status=0)
    require("Bridge: unsent" in report and txs[0]["hash"] in report, "partial-failure summary missing")

    for name, react, base, destination, value, data in (
        ("skip-faucet", "0", "0.05", BRIDGE, COIN // 20, bridge_data),
        ("skip-bridge", "0.1", "0.000000000000000000", FAUCET, COIN // 10, request_data),
        ("one-wei", "0", "0.000000000000000001", BRIDGE, 1, bridge_data),
    ):
        reset()
        report = run(name, {"REACT_ETH": react, "BASE_ETH": base}, credit=True)
        assert_transaction(assert_sends(1)[0], destination, value, data)
        require("skipped" in report and "WARNING" not in report, "zero leg was not skipped cleanly")

    reset()
    report = run("caps-and-credit-timeout", {"REACT_ETH": "2", "BASE_ETH": "0.2", "FUND_POLL_TIMEOUT": "0"})
    txs = assert_sends(2)
    assert_transaction(txs[0], FAUCET, 2 * COIN, request_data)
    assert_transaction(txs[1], BRIDGE, COIN // 5, bridge_data)
    require("WARNING: Credit not observed" in report and "Credit may arrive later" in report,
            "credit timeout must warn and succeed")
    require(balance(LASNA) == 5 * COIN and balance(BASE) == COIN, "timeout case should have no credits")
    print("fund dry run: all transaction, refusal, receipt, skip and summary checks passed", flush=True)


if __name__ == "__main__":
    main()
