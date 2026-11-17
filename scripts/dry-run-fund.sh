#!/usr/bin/env bash
# CI only: the real fund.sh against three local anvil chains. No public RPCs, no environment secrets.
set -euo pipefail
cd "$(dirname "$0")/.."
export SEPOLIA_RPC=http://127.0.0.1:8547
export BASE_RPC=http://127.0.0.1:8548
export LASNA_RPC=http://127.0.0.1:8549
logs="${RUNNER_TEMP:-/tmp}/dry-run-fund"
mkdir -p "$logs"
pids=""
cleanup() {
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null || true
}
trap cleanup EXIT

anvil --host 127.0.0.1 --chain-id 11155111 --port 8547 > "$logs/anvil-sepolia.log" 2>&1 &
pids="$!"
anvil --host 127.0.0.1 --chain-id 84532 --port 8548 > "$logs/anvil-base.log" 2>&1 &
pids="$pids $!"
anvil --host 127.0.0.1 --chain-id 5318007 --port 8549 > "$logs/anvil-lasna.log" 2>&1 &
pids="$pids $!"
for rpc in "$SEPOLIA_RPC" "$BASE_RPC" "$LASNA_RPC"; do
  ready=0
  for _ in $(seq 1 30); do
    if cast chain-id --rpc-url "$rpc" >/dev/null 2>&1; then ready=1; break; fi
    sleep 1
  done
  [ "$ready" = 1 ] || { echo "local anvil failed to start: $rpc"; exit 1; }
done

forge build >/dev/null
python3 scripts/dry-run-fund.py "$logs"
