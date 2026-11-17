#!/usr/bin/env bash
# CI dry run of the deploy and loop scripts against two local anvil chains (never a public network).
#   port 8545: chain 84532 (plays Base Sepolia), the mock callback proxy at the real proxy address;
#   port 8546: chain 5318007 (plays Lasna), the mock system contract at 0x8888...8888, the CRON source at 0x...fffFfF;
#   scripts/relay-anvil.py plays the network between them.
# Runs the same deploy-hello.sh, deploy-system.sh, loop-hello.sh and loop-system.sh the testnet workflows run.
# DEPLOY_KEY and RELAY_KEY must be public anvil development keys (set in ci.yml).
set -euo pipefail
cd "$(dirname "$0")/.."

export BASE_RPC=http://127.0.0.1:8545
export LASNA_RPC=http://127.0.0.1:8546
export CALLBACK_PROXY="${CALLBACK_PROXY:-0x476F44b11F5C942c58f4c8E3d0300E5710743585}"
SYSTEM=0x8888888888888888888888888888888888888888
CRON=0x0000000000000000000000000000000000fffFfF
logs="${RUNNER_TEMP:-/tmp}/dry-run"
mkdir -p "$logs"

anvil --chain-id 84532 --port 8545 > "$logs/anvil-base.log" 2>&1 &
pids="$!"
anvil --chain-id 5318007 --port 8546 > "$logs/anvil-lasna.log" 2>&1 &
pids="$pids $!"
relay_pid=""
cleanup() {
  # shellcheck disable=SC2086
  kill $pids $relay_pid 2>/dev/null || true
}
trap cleanup EXIT

for rpc in "$BASE_RPC" "$LASNA_RPC"; do
  for _ in $(seq 1 30); do
    cast chain-id --rpc-url "$rpc" >/dev/null 2>&1 && break
    sleep 1
  done
done

# Self-test of the loop's timing check: it must refuse an exit at or after executableAt.
# shellcheck source=scripts/chain.sh
(source scripts/chain.sh; check_exit_timing 199 200 "self-test early") || { echo "timing check refused an early exit"; exit 1; }
if (source scripts/chain.sh; check_exit_timing 200 200 "self-test late") 2>/dev/null; then
  echo "timing check accepted a late exit"
  exit 1
fi
if (source scripts/chain.sh; check_exit_timing 100 0 "self-test unknown") 2>/dev/null; then
  echo "timing check accepted an unknown executableAt"
  exit 1
fi
echo "timing check self-test passed"

forge build >/dev/null
cast rpc --rpc-url "$LASNA_RPC" anvil_setCode "$SYSTEM" "$(forge inspect test/mocks/MockSystem.sol:MockSystem deployedBytecode)" >/dev/null
cast rpc --rpc-url "$LASNA_RPC" anvil_setCode "$CRON" "$(forge inspect test/mocks/CronSource.sol:CronSource deployedBytecode)" >/dev/null
cast rpc --rpc-url "$BASE_RPC" anvil_setCode "$CALLBACK_PROXY" \
  "$(forge inspect test/mocks/MockCallbackProxy.sol:MockCallbackProxy deployedBytecode)" >/dev/null
echo "mock network contracts in place"

export DEPLOY_OUT="$logs/deployed.env"
: > "$DEPLOY_OUT"
REACTIVE_FUND=1 CALLBACK_FUND=0.002 bash scripts/deploy-hello.sh
REACTIVE_FUND=5 EXIT_FUND=0.005 bash scripts/deploy-system.sh
# shellcheck disable=SC1090
source "$DEPLOY_OUT"
export HELLO_ORIGIN HELLO_REACTIVE HELLO_CALLBACK NP_TOKEN NP_FACTORY NP_EXIT NP_REACTIVE

python3 scripts/relay-anvil.py --base "$BASE_RPC" --lasna "$LASNA_RPC" --proxy "$CALLBACK_PROXY" \
  --reactive "$HELLO_REACTIVE" --reactive "$NP_REACTIVE" --cron 5 > "$logs/relay.log" 2>&1 &
relay_pid="$!"

status=0
bash scripts/loop-hello.sh || status=1
[ "$status" = 0 ] && { LOOP_MODE=0 bash scripts/loop-system.sh || status=1; }
[ "$status" = 0 ] && { LOOP_MODE=1 bash scripts/loop-system.sh || status=1; }

echo "---- relay log"
cat "$logs/relay.log"
kill -0 "$relay_pid" 2>/dev/null || { echo "the relay stopped early"; status=1; }
for what in "strayEvents()(uint256)" "unknownEvents()(uint256)" "activeWatches()(uint256)" "cronFilterRefs()(uint256)"; do
  echo "NoticeReactive.$what = $(cast call --rpc-url "$LASNA_RPC" "$NP_REACTIVE" "$what")"
done
reverts="$(cast call --rpc-url "$LASNA_RPC" "$SYSTEM" 'reverts()(uint256)' | awk '{print $1}')"
echo "react() reverts seen by the mock system: $reverts"
[ "$reverts" = 0 ] || status=1
over="$(cast call --rpc-url "$LASNA_RPC" "$SYSTEM" 'overGasLimit()(uint256)' | awk '{print $1}')"
maxgas="$(cast call --rpc-url "$LASNA_RPC" "$SYSTEM" 'maxReactGas()(uint256)' | awk '{print $1}')"
echo "reactions over the 900,000 gas cap: $over (largest reaction as measured by the mock: $maxgas gas)"
[ "$over" = 0 ] || status=1
exit "$status"
