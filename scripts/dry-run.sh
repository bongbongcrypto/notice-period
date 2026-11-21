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
  --reactive "$HELLO_REACTIVE" --reactive "$NP_REACTIVE" --cron 5 --duration 3000 > "$logs/relay.log" 2>&1 &
relay_pid="$!"

status=0
bash scripts/loop-hello.sh || status=1
[ "$status" = 0 ] && { LOOP_MODE=0 LOOP_RUN_JSON="$logs/run-mode0.json" bash scripts/loop-system.sh || status=1; }
[ "$status" = 0 ] && { LOOP_MODE=1 LOOP_RUN_JSON="$logs/run-mode1.json" bash scripts/loop-system.sh || status=1; }

# ---------------------------------------------------------------- every other action and kind of loop-system.sh
# NoticeExit allows two arms per address per day, so the runs are spread over key A and key B and over several days:
# both chains move forward by the same time between groups. Key B needs gas once (key A sends it; anvil keys are rich).
# A miner keeps Base blocks coming, so waits on Base block time (revoke-stays) end on an idle chain too.
(while :; do cast rpc --rpc-url "$BASE_RPC" evm_mine >/dev/null 2>&1 || true; sleep 3; done) &
miner_pid="$!"
pids="$pids $miner_pid"
warp() { # seconds: the same jump on both chains
  for rpc in "$BASE_RPC" "$LASNA_RPC"; do
    cast rpc --rpc-url "$rpc" evm_increaseTime "$1" >/dev/null
    cast rpc --rpc-url "$rpc" evm_mine >/dev/null
  done
  echo "---- both chains moved $1 s forward"
}
twin() { # name [VAR=value ...]: one loop-system.sh run; its run.json is $logs/run-<name>.json
  local name="$1"
  shift
  [ "$status" = 0 ] || return 0
  echo "---- twin: $name"
  env LOOP_RUN_JSON="$logs/run-$name.json" "$@" bash scripts/loop-system.sh || { echo "twin $name failed"; status=1; }
}
field() { # name key -> value from run-<name>.json
  python3 -c 'import json, sys; v = json.load(open(sys.argv[1])).get(sys.argv[2], ""); print(v[-1] if isinstance(v, list) else v)' \
    "$logs/run-$1.json" "$2"
}
B=(LOOP_DEPOSITOR=b LOOP_FUND_B=1 LOOP_B_GAS=1)

# Day 0 (key A has used its two arms above): key B.
twin ignored LOOP_ACTION=ignored-then-exit "${B[@]}"
twin armonly LOOP_ACTION=arm-only "${B[@]}"
[ "$status" = 0 ] && twin fire LOOP_ACTION=fire LOOP_VAULT="$(field armonly vault)" LOOP_WATCH="$(field armonly watchId)"
warp 86460
# Day 1: the other three kinds in mode 0, and a revoked change in mode 1.
twin timelock LOOP_KIND=timelock
twin allocator LOOP_KIND=allocator
twin cap LOOP_KIND=cap LOOP_WATCH_KINDS=15 "${B[@]}"
twin revoke LOOP_ACTION=revoke-stays LOOP_MODE=1 "${B[@]}"
warp 86460
# Day 2: a timer watch left on past its lease, then expired by anyone (here key A).
twin timer LOOP_ACTION=arm-only LOOP_MODE=1
warp 86460
twin expire LOOP_ACTION=expire-stale
if [ "$status" = 0 ]; then
  timer_watch="$(field timer watchId)"
  expired="$(field expire expiredWatch)"
  [ "$expired" = "$timer_watch" ] || { echo "expire-stale expired '$expired', expected the timer watch $timer_watch"; status=1; }
fi
# Day 3: a top-up from key A, then the health job (key B only) green, then red with a forced debt.
twin topup LOOP_ACTION=topup LOOP_TOPUP=1
if [ "$status" = 0 ]; then
  echo "---- twin: health (green)"
  HEALTH_MIN_FLOAT=1 LOOP_FACTORY_KIND=demo RUNNER_TEMP="$logs" bash scripts/health.sh || { echo "health failed on a healthy system"; status=1; }
fi
if [ "$status" = 0 ]; then
  echo "---- twin: health with a forced debt (must fail)"
  cast send --rpc-url "$LASNA_RPC" --private-key "$DEPLOY_KEY" "$SYSTEM" 'setDebt(address,uint256)' "$NP_REACTIVE" 1 >/dev/null
  if HEALTH_MIN_FLOAT=1 LOOP_FACTORY_KIND=demo RUNNER_TEMP="$logs" bash scripts/health.sh; then
    echo "health passed although NoticeReactive owes the system contract"
    status=1
  else
    echo "health failed on the forced debt, as it must"
  fi
  cast send --rpc-url "$LASNA_RPC" --private-key "$DEPLOY_KEY" "$SYSTEM" 'setDebt(address,uint256)' "$NP_REACTIVE" 0 >/dev/null
fi
echo "burst: not run here (the demo vault has no multicall; it runs against maker vaults on the next branch)"

# The run records of these runs, checked from receipts by scripts/runs.py exactly as the testnet records are.
if [ "$status" = 0 ]; then
  echo "---- run records (scripts/runs.py --add and --check against the local chains)"
  rroot="$logs/records-root"
  mkdir -p "$rroot/deployments"
  python3 - "$rroot/deployments/dry.json" <<PY
import json, sys
json.dump({"name": "dry", "status": "deployed", "contracts": {"token": "$NP_TOKEN", "factory": "$NP_FACTORY",
           "exit": "$NP_EXIT", "reactive": "$NP_REACTIVE"}}, open(sys.argv[1], "w"))
PY
  BASE_RPC_READ="$BASE_RPC" LASNA_RPC_READ="$LASNA_RPC" python3 - "$rroot" "$logs" <<'PY' || status=1
import sys
sys.path.insert(0, "scripts")
import runs
root, logs = sys.argv[1], sys.argv[2]
names = ["mode0", "mode1", "ignored", "armonly", "fire", "timelock", "allocator", "cap", "revoke"]
runs.add("dry", [f"{logs}/run-{n}.json" for n in names], root=root)
sys.exit(runs.check(["dry"], root=root))
PY
fi

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
