#!/usr/bin/env python3
"""CI assertions for fund.sh. Stdlib only; all RPCs are loopback anvils started by dry-run-fund.sh.

Transactions and receipts are real local-chain records. A cast shim only injects a code change immediately
before broadcast, so estimation succeeds but the faucet transaction mines with status 0. It never fakes a
transaction or receipt. Destination balance changes model the cross-chain credit, not an actual relay.
Every case runs; failures are collected and listed at the end.
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
# Independent copies of the real addresses (Reactive and Base docs, read-only chain checks 2026-11-17/18). fund.sh
# has its own fixed copies; if they differ, fund.sh meets no code at its address and the happy case fails.
FAUCET = "0x9b9BB25f1A81078C544C829c5EB7822d747Cf434"  # Reactive faucet, Sepolia
BRIDGE = "0xfd0Bf71F60660E2f608ed56e1659C450eB113120"  # Base L1StandardBridge, Sepolia
PAYER = "0x5cBC52A390E69D9193996AeBFB53F7b97DB6cf51"  # Reactive faucet payer, Lasna (l1() == FAUCET)
SYSTEM = "0x8888888888888888888888888888888888888888"  # Reactive system contract, Lasna (debt ledger)
DEAD = "0x000000000000000000000000000000000000dEaD"
COIN = 10**18
SEPOLIA_BASE_FEE = 7  # dry-run-fund.sh starts the Sepolia anvil with this base fee and no minimum tip
RPCS = [os.environ[n] for n in ("SEPOLIA_RPC", "BASE_RPC", "LASNA_RPC")]
SEPOLIA, BASE, LASNA = RPCS
REAL_CAST = shutil.which("cast")
LOGS = Path(sys.argv[1]).resolve()
FAILURES = []


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


def word(value):
    return "0x" + format(value, "064x")


def set_slot(url, address, slot, value):
    slot = slot if isinstance(slot, str) else word(slot)
    rpc(url, "anvil_setStorageAt", [address, slot, word(value)])


def balance(url, who=ACCOUNT):
    return int(rpc(url, "eth_getBalance", [who, "latest"]), 16)


def set_balance(url, value, who=ACCOUNT):
    rpc(url, "anvil_setBalance", [who, hex(value)])


def transactions(url=SEPOLIA):
    head = int(rpc(url, "eth_blockNumber", []), 16)
    return [tx for number in range(head + 1)
            for tx in rpc(url, "eth_getBlockByNumber", [hex(number), True])["transactions"]]


def assert_sends(count):
    txs = transactions()
    require(len(txs) == count, f"expected {count} mined Sepolia sends, saw {len(txs)}")
    require(not transactions(BASE) and not transactions(LASNA), "fund sent on a destination chain")
    return txs


def pending_nonce():
    return int(rpc(SEPOLIA, "eth_getTransactionCount", [ACCOUNT, "pending"]), 16)


def assert_transaction(tx, to, value, calldata, status=1, nonce=None, gas_price=None, gas_limit=None):
    require(tx["from"].lower() == ACCOUNT, "unexpected sender")
    require(tx["to"].lower() == to.lower(), "wrong transaction destination/order")
    require(int(tx["value"], 16) == value, "wrong transaction value")
    require(tx["input"].lower() == calldata.lower(), "wrong selector or arguments")
    receipt = rpc(SEPOLIA, "eth_getTransactionReceipt", [tx["hash"]])
    require(int(receipt["status"], 16) == status, "wrong receipt status")
    require(int(tx.get("type", "0x0"), 16) == 0, f"transaction type {tx.get('type')}, expected legacy (0)")
    if nonce is not None:
        require(int(tx["nonce"], 16) == nonce, f"nonce {int(tx['nonce'], 16)}, expected {nonce}")
    if gas_price is not None:
        require(int(tx["gasPrice"], 16) == gas_price, f"gas price {int(tx['gasPrice'], 16)}, expected {gas_price}")
    if gas_limit is not None:
        require(int(tx["gas"], 16) == gas_limit, f"gas limit {int(tx['gas'], 16)}, expected {gas_limit}")


def main():
    require(os.environ.get("DEPLOY_KEY") == KEY0 and os.environ.get("RELAY_KEY") == KEY1,
            "fund dry run requires only the two public default anvil keys")
    for url, chain in zip(RPCS, (11155111, 84532, 5318007)):
        require(int(rpc(url, "eth_chainId", []), 16) == chain, "dry-run chain configuration mismatch")
    require(int(rpc(SEPOLIA, "eth_gasPrice", []), 16) == SEPOLIA_BASE_FEE,
            "the Sepolia anvil must report the low base fee as its gas price (see dry-run-fund.sh)")
    names = ("MockFundFaucet", "MockFundBridge", "MockFundRevertingFaucet", "MockFundPayer", "MockFundSystem")
    codes = {name: tool("forge", "inspect", f"test/mocks/FundMocks.sol:{name}", "deployedBytecode")
             for name in names}
    debt_slot = tool(REAL_CAST, "index", "address", PAYER, "0")
    rpc(SEPOLIA, "anvil_setCode", [FAUCET, codes["MockFundFaucet"]])
    set_slot(SEPOLIA, FAUCET, 0, 50 * COIN)  # live Sepolia max_payout 2026-11-17
    rpc(SEPOLIA, "anvil_setCode", [BRIDGE, codes["MockFundBridge"]])
    # Live Lasna payer state 2026-11-17: wired to FAUCET, 100 lREACT per ETH, max 500, reserve 10, not paused.
    rpc(LASNA, "anvil_setCode", [PAYER, codes["MockFundPayer"]])
    for slot, value in enumerate((int(FAUCET, 16), 11155111, 500 * COIN, 1_000_000, 10 * COIN, 0)):
        set_slot(LASNA, PAYER, slot, value)
    set_balance(LASNA, 97_879 * COIN, PAYER)
    rpc(LASNA, "anvil_setCode", [SYSTEM, codes["MockFundSystem"]])
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
  "$FUND_REAL_CAST" rpc --rpc-url "$SEPOLIA_RPC" anvil_setCode "$FUND_TEST_FAUCET" "$FUND_REVERT_CODE" >/dev/null
fi
exec "$FUND_REAL_CAST" "$@"
''', encoding="utf-8")
    (shim / "cast").chmod(0o755)
    env = dict(os.environ, DEPLOY_KEY=KEY0, TESTNET_ADDRESS=ACCOUNT.upper().replace("0X", "0x"),
               REACT_ETH="0.1", BASE_ETH="0.05", SEPOLIA_NONCE="0", FUND_POLL_TIMEOUT="45",
               FUND_REAL_CAST=REAL_CAST, FUND_TEST_REVERT_ON_SEND="0", FUND_TEST_FAUCET=FAUCET,
               FUND_REVERT_CODE=codes["MockFundRevertingFaucet"], PATH=f"{shim}:{os.environ['PATH']}")
    # fund.sh must use its own fixed addresses; never inherit overrides or fault controls.
    for name in ("BASH_ENV", "FAUCET_ADDRESS", "BRIDGE_ADDRESS", "LASNA_PAYER", "LASNA_SYSTEM",
                 "FUND_RECEIPT_TIMEOUT"):
        env.pop(name, None)
    request_data = tool(REAL_CAST, "calldata", "request(address)", ACCOUNT)
    bridge_data = tool(REAL_CAST, "calldata", "depositETH(uint32,bytes)", "200000", "0x")

    def reset():
        for url in RPCS:
            require(rpc(url, "evm_revert", [snapshots[url]]), "snapshot restore failed")
            snapshots[url] = rpc(url, "evm_snapshot", [])

    def restore_mining():
        rpc(SEPOLIA, "anvil_dropAllTransactions", [])
        rpc(SEPOLIA, "evm_setAutomine", [True])
        rpc(SEPOLIA, "anvil_setNextBlockBaseFeePerGas", [hex(SEPOLIA_BASE_FEE)])

    def check(name, body):
        try:
            body()
            print(f"fund dry run: {name} passed", flush=True)
        except Exception as exc:  # collect, keep going, fail at the end
            FAILURES.append(f"{name}: {exc}")
            print(f"fund dry run: {name} FAILED: {exc}", flush=True)
        finally:
            try:
                restore_mining()
            except Exception as exc:
                FAILURES.append(f"{name}: could not restore the Sepolia anvil: {exc}")

    def run(name, overrides=None, refusal=None, credit=None, credit_delay=2.0):
        """credit: None, 'both', 'lasna' (no Base credit) or 'short' (half the Lasna credit)."""
        case_env = dict(env, **(overrides or {}))
        summary = LOGS / f"{name}.md"
        summary.write_text("", encoding="utf-8")
        case_env["GITHUB_STEP_SUMMARY"] = str(summary)
        credited = set()
        end = time.monotonic() + 90
        credit_at = time.monotonic() + credit_delay  # let fund.sh read the original balances first
        lasna0, base0 = balance(LASNA), balance(BASE)
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
                            value = int(tx["value"], 16)
                            if to == FAUCET.lower():
                                # The payer pays 100 lREACT per ETH up to 5 ETH, and nothing above that.
                                paid = value * 100 if value <= 5 * COIN else 0
                                set_balance(LASNA, lasna0 + (paid // 2 if credit == "short" else paid))
                            elif to == BRIDGE.lower() and credit != "lasna":
                                set_balance(BASE, base0 + value)
                            credited.add(to)
                    time.sleep(0.1)
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        output = (LOGS / f"{name}.log").read_text(encoding="utf-8")
        report = summary.read_text(encoding="utf-8")
        for key in (KEY0, KEY1):
            require(key[2:].lower() not in (output + report).lower(), f"{name}: a key appeared in the log or summary")
        if refusal:
            require(process.returncode != 0 and refusal in output, f"expected refusal '{refusal}':\n{output}")
        else:
            require(process.returncode == 0, f"fund failed:\n{output}")
        return output, report

    def refuse(name, overrides, message, prepare=None):
        def body():
            reset()
            if prepare:
                prepare()
            run(name, overrides, refusal=message)
            assert_sends(0)
            require(pending_nonce() == 0 or prepare is not None, "a transaction was left pending")
        check(name, body)

    def expected_limit(to, value, data):
        est = int(rpc(SEPOLIA, "eth_estimateGas", [{"from": ACCOUNT, "to": to, "value": hex(value), "data": data,
                                                    "gasPrice": hex(SEPOLIA_BASE_FEE)}]), 16)
        return (est * 120 + 99) // 100

    def happy_then_duplicate():
        reset()
        limits = (expected_limit(FAUCET, COIN // 10, request_data), expected_limit(BRIDGE, COIN // 20, bridge_data))
        _, report = run("happy", credit="both")
        txs = assert_sends(2)
        for i, (tx, to, value, data) in enumerate(((txs[0], FAUCET, COIN // 10, request_data),
                                                   (txs[1], BRIDGE, COIN // 20, bridge_data))):
            assert_transaction(tx, to, value, data, nonce=i, gas_price=2 * SEPOLIA_BASE_FEE, gas_limit=limits[i])
        require(balance(LASNA) == 15 * COIN and balance(BASE) == COIN + COIN // 20, "simulated credits missing")
        require("WARNING" not in report and "STOP" not in report and "| Before | After | Change |" in report,
                "bad happy-path summary")
        require("Lasna credit observed: yes" in report and "Base Sepolia credit observed: yes" in report,
                "credit lines missing from summary")
        require("sepolia_nonce for a deliberate next run: 2" in report, "next sepolia_nonce missing from summary")
        require("| 5.000000000000000000 | 15.000000000000000000 | 10.000000000000000000 |" in report,
                "Lasna balance change missing from summary")
        require("| 1.000000000000000000 | 1.050000000000000000 | 0.050000000000000000 |" in report,
                "Base balance change missing from summary")
        for tx in txs:
            require(f"https://sepolia.etherscan.io/tx/{tx['hash']}" in report, "transaction explorer link missing")
        for explorer in ("https://base-sepolia.blockscout.com/address/", "https://lasna.reactscan.net/address/"):
            require(explorer in report, "destination explorer link missing")
        # A second dispatch (or a re-run) with the same inputs must not fund again.
        run("duplicate-dispatch", credit="both", refusal="Sepolia nonce is 2, but sepolia_nonce is 0")
        assert_sends(2)

    check("happy-then-duplicate", happy_then_duplicate)

    # Input checks run before any RPC: the cap must be refused even with an unreachable RPC.
    refuse("react-six", {"REACT_ETH": "6", "SEPOLIA_RPC": "http://127.0.0.1:1"}, "react_eth exceeds")
    refuse("react-cap-one-wei", {"REACT_ETH": "2.000000000000000001"}, "react_eth exceeds")
    refuse("base-cap-one-wei", {"BASE_ETH": "0.200000000000000001"}, "base_eth exceeds")
    for field in ("REACT_ETH", "BASE_ETH"):
        for i, value in enumerate(("-0.1", "1e-2", ".1", "1.", " 0.1", "0.1234567890123456789")):
            refuse(f"decimal-{field}-{i}", {field: value}, "not a plain decimal")
    refuse("both-zero", {"REACT_ETH": "0.000", "BASE_ETH": "0"}, "both funding legs are zero")
    refuse("empty-address", {"TESTNET_ADDRESS": ""}, "TESTNET_ADDRESS is not set")
    refuse("short-address", {"TESTNET_ADDRESS": "0x1234"}, "TESTNET_ADDRESS is not a")
    refuse("empty-key", {"DEPLOY_KEY": ""}, "DEPLOY_KEY is not set")
    refuse("malformed-key", {"DEPLOY_KEY": "0x1234"}, "could not derive the testnet address")
    refuse("wrong-key", {"DEPLOY_KEY": KEY1}, "key address differs")
    refuse("empty-nonce", {"SEPOLIA_NONCE": ""}, "SEPOLIA_NONCE is not set")
    for i, value in enumerate(("-1", "01", "1.0", "x")):
        refuse(f"bad-nonce-{i}", {"SEPOLIA_NONCE": value}, "sepolia_nonce must be")
    for i, value in enumerate(("0", "901", "abc")):
        refuse(f"poll-timeout-{i}", {"FUND_POLL_TIMEOUT": value}, "FUND_POLL_TIMEOUT must be")
    for i, value in enumerate(("0", "181", "abc")):
        refuse(f"receipt-timeout-{i}", {"FUND_RECEIPT_TIMEOUT": value}, "FUND_RECEIPT_TIMEOUT must be")
    for field, wrong in (("SEPOLIA_RPC", BASE), ("BASE_RPC", LASNA), ("LASNA_RPC", BASE)):
        refuse(f"wrong-chain-{field}", {field: wrong}, "chain id is")
    # Fixed addresses: an environment override (here, swapped) must have no effect on where funds go.
    def address_override_ignored():
        reset()
        run("address-override-ignored", {"FAUCET_ADDRESS": BRIDGE, "BRIDGE_ADDRESS": FAUCET}, credit="both")
        txs = assert_sends(2)
        assert_transaction(txs[0], FAUCET, COIN // 10, request_data, nonce=0)
        assert_transaction(txs[1], BRIDGE, COIN // 20, bridge_data, nonce=1)
    check("address-override-ignored", address_override_ignored)

    # Balance and gas.
    refuse("insufficient", {}, "balance below what this run needs",
           lambda: set_balance(SEPOLIA, 159 * COIN // 1000))
    refuse("leg-above-balance", {"REACT_ETH": "0.1", "BASE_ETH": "0"}, "balance below what this run needs",
           lambda: set_balance(SEPOLIA, 9 * COIN // 100))
    refuse("gas-price-ceiling", {}, "Sepolia gas price too high",
           lambda: rpc(SEPOLIA, "anvil_setNextBlockBaseFeePerGas", [hex(10**9 + 1)]))
    for name, address in (("faucet", FAUCET), ("bridge", BRIDGE)):
        refuse(f"no-code-{name}", {}, "no contract code",
               lambda a=address: rpc(SEPOLIA, "anvil_setCode", [a, "0x"]))
    refuse("bridge-estimate-revert", {}, "funding gas estimate failed",
           lambda: rpc(SEPOLIA, "anvil_setCode", [BRIDGE, codes["MockFundRevertingFaucet"]]))

    # The faucet keeps the ETH whatever happens on Lasna, so its payout state is read before any request.
    refuse("faucet-max-below", {}, "Sepolia faucet max_payout",
           lambda: set_slot(SEPOLIA, FAUCET, 0, COIN // 10 - 1))
    payer_cases = (
        ("payer-l1", 0, int(BRIDGE, 16), "not wired to the Sepolia faucet"),
        ("payer-chain", 1, 84532, "not wired to the Sepolia faucet"),
        ("payer-max", 2, 10 * COIN - 1, "Lasna payer max_payout"),
        ("payer-rate", 3, 2_000_000, "Lasna payer exchange rate"),
        ("payer-paused", 5, 1, "Lasna payer is paused"),
    )
    for name, slot, value, message in payer_cases:
        refuse(name, {}, message, lambda s=slot, v=value: set_slot(LASNA, PAYER, s, v))
    refuse("payer-balance", {}, "Lasna payer balance", lambda: set_balance(LASNA, 20 * COIN - 1, PAYER))
    refuse("payer-debt", {}, "Lasna payer has system debt", lambda: set_slot(LASNA, SYSTEM, debt_slot, 1))
    refuse("payer-no-code", {}, "Lasna payer", lambda: rpc(LASNA, "anvil_setCode", [PAYER, "0x"]))

    # Nonce guard: a transaction still pending from an earlier run blocks a new one.
    def pending_tx():
        rpc(SEPOLIA, "evm_setAutomine", [False])
        rpc(SEPOLIA, "eth_sendTransaction", [{"from": ACCOUNT, "to": DEAD, "value": "0x1",
                                              "gasPrice": hex(2 * SEPOLIA_BASE_FEE)}])
    refuse("pending-nonce", {}, "still pending", pending_tx)
    refuse("wrong-nonce-input", {"SEPOLIA_NONCE": "1"}, "Sepolia nonce is 0, but sepolia_nonce is 1")

    def skip_payer_checks_when_no_react():
        reset()
        set_slot(LASNA, PAYER, 5, 1)  # paused payer is irrelevant when no lREACT is requested
        _, report = run("skip-faucet-payer-paused", {"REACT_ETH": "0"}, credit="both")
        assert_transaction(assert_sends(1)[0], BRIDGE, COIN // 20, bridge_data, nonce=0)
        require("Faucet: skipped" in report and "Lasna credit observed: skipped" in report, "faucet leg not skipped")
    check("skip-faucet-payer-paused", skip_payer_checks_when_no_react)

    # Estimation succeeds, then the shim installs a reverting faucet immediately before the real broadcast.
    def faucet_receipt_revert():
        reset()
        _, report = run("faucet-receipt-revert", {"FUND_TEST_REVERT_ON_SEND": "1"}, refusal="receipt status is not 1")
        txs = assert_sends(1)
        assert_transaction(txs[0], FAUCET, COIN // 10, request_data, status=0)
        require("Bridge: unsent" in report and txs[0]["hash"] in report, "partial-failure summary missing")
    check("faucet-receipt-revert", faucet_receipt_revert)

    # A send that is never mined: the run stops before the bridge leg, and a re-run is refused while it is pending.
    def receipt_timeout_then_rerun():
        reset()
        rpc(SEPOLIA, "evm_setAutomine", [False])
        _, report = run("receipt-timeout", {"FUND_RECEIPT_TIMEOUT": "5"}, refusal="receipt unknown")
        assert_sends(0)
        require(pending_nonce() == 1, "the faucet transaction should be pending")
        require("Bridge: unsent" in report and "Faucet: receipt unknown" in report, "pending-leg summary missing")
        run("receipt-timeout-rerun", {"FUND_RECEIPT_TIMEOUT": "5"}, refusal="still pending")
        require(pending_nonce() == 1, "the re-run sent another transaction")
    check("receipt-timeout-then-rerun", receipt_timeout_then_rerun)

    def legs(name, react, base, destination, value, data):
        def body():
            reset()
            _, report = run(name, {"REACT_ETH": react, "BASE_ETH": base}, credit="both")
            assert_transaction(assert_sends(1)[0], destination, value, data, nonce=0,
                               gas_price=2 * SEPOLIA_BASE_FEE)
            require("skipped" in report and "WARNING" not in report, "zero leg was not skipped cleanly")
            require("sepolia_nonce for a deliberate next run: 1" in report, "next sepolia_nonce missing")
        check(name, body)
    legs("skip-faucet", "0", "0.05", BRIDGE, COIN // 20, bridge_data)
    legs("skip-bridge", "0.1", "0.000000000000000000", FAUCET, COIN // 10, request_data)
    legs("one-wei", "0", "0.000000000000000001", BRIDGE, 1, bridge_data)

    def caps():
        reset()
        _, report = run("caps", {"REACT_ETH": "2", "BASE_ETH": "0.2"}, credit="both")
        txs = assert_sends(2)
        assert_transaction(txs[0], FAUCET, 2 * COIN, request_data, nonce=0)
        assert_transaction(txs[1], BRIDGE, COIN // 5, bridge_data, nonce=1)
        require(balance(LASNA) == 205 * COIN and "WARNING" not in report, "cap-sized credit not observed")
    check("caps", caps)

    # Credit polling. A Lasna payout normally lands in seconds: missing or short is a failure that says not to
    # resend. A Base deposit can take longer: missing is a warning. Neither ever sends again.
    def no_credit():
        reset()
        output, report = run("no-credit", {"FUND_POLL_TIMEOUT": "16"}, refusal="Lasna credit not observed")
        assert_sends(2)
        require("Lasna credit observed: no" in report and "Base Sepolia credit observed: no" in report,
                "credit lines wrong")
        require("do not resend" in report.lower(), "no-credit summary must say not to resend")
    check("no-credit", no_credit)

    def lasna_only():
        reset()
        _, report = run("lasna-only", {"FUND_POLL_TIMEOUT": "16"}, credit="lasna")
        assert_sends(2)
        require("Lasna credit observed: yes" in report and "Base Sepolia credit observed: no" in report,
                "credit lines wrong")
        require("WARNING: Base Sepolia credit not observed" in report, "missing Base credit must warn")
    check("lasna-only", lasna_only)

    def short_lasna():
        reset()
        _, report = run("short-lasna", {"FUND_POLL_TIMEOUT": "16"}, credit="short",
                        refusal="Lasna credit not observed")
        assert_sends(2)
        require("Lasna credit observed: no" in report, "a short Lasna credit was accepted")
    check("short-lasna", short_lasna)

    def late_credit():
        reset()
        _, report = run("late-credit", {"FUND_POLL_TIMEOUT": "45"}, credit="both", credit_delay=20)
        assert_sends(2)
        require("Lasna credit observed: yes" in report and "Base Sepolia credit observed: yes" in report,
                "a credit after the first poll was missed")
    check("late-credit", late_credit)

    if FAILURES:
        print(f"\nfund dry run: {len(FAILURES)} case(s) failed:", flush=True)
        for failure in FAILURES:
            print(" - " + failure.splitlines()[0], flush=True)
        sys.exit(1)
    print("fund dry run: all transaction, refusal, receipt, nonce, credit and summary checks passed", flush=True)


if __name__ == "__main__":
    main()
