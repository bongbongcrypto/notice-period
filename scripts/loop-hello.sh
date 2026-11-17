#!/usr/bin/env bash
# Fires one Ping on Base Sepolia and waits for the reactive transaction on Lasna and the callback on Base Sepolia.
# Prints the three transaction hashes and the seconds between the first and the last block.
#
# Environment: BASE_RPC, LASNA_RPC, DEPLOY_KEY, HELLO_ORIGIN, HELLO_REACTIVE, HELLO_CALLBACK,
#   LOOP_TIMEOUT (seconds per wait, default 300).
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/chain.sh
source scripts/chain.sh

need_env BASE_RPC LASNA_RPC HELLO_ORIGIN HELLO_REACTIVE HELLO_CALLBACK
need_key
check_chain "$BASE_RPC" "$BASE_CHAIN_ID" "Base Sepolia"
check_chain "$LASNA_RPC" "$LASNA_CHAIN_ID" "Lasna"
check_balance "$BASE_RPC" "Base Sepolia" "$(to_wei 0.0005)"
timeout="${LOOP_TIMEOUT:-300}"

lasna_from="$(block_number "$LASNA_RPC")"
base_from="$(block_number "$BASE_RPC")"
nonce="$(date +%s)"

hash1="$(send "$BASE_RPC" "1. Ping on Base Sepolia" "$HELLO_ORIGIN" "ping(uint256)" "$nonce")"
hash2="$(wait_log "$LASNA_RPC" "2. reactive transaction on Lasna" "$lasna_from" "$HELLO_REACTIVE" \
  "Relayed(uint256,uint256,address)" "$timeout" "$hash1")"
hash3="$(wait_log "$BASE_RPC" "3. callback on Base Sepolia" "$base_from" "$HELLO_CALLBACK" \
  "Ponged(uint256,uint256,address,address)" "$timeout" "$hash1")"

t1="$(tx_block_time "$BASE_RPC" "$hash1")"
t2="$(tx_block_time "$LASNA_RPC" "$hash2")"
t3="$(tx_block_time "$BASE_RPC" "$hash3")"
[ "$t3" -ge "$t1" ] || die "the callback $hash3 is older than the ping $hash1: wrong log"

summary "### Hello-world loop"
summary ""
summary "| Step | Chain | Transaction | Block time |"
summary "|---|---|---|---|"
summary "| 1. Ping | Base Sepolia | \`$hash1\` | $t1 |"
summary "| 2. Reactive transaction | Lasna | \`$hash2\` | $t2 |"
summary "| 3. Callback | Base Sepolia | \`$hash3\` | $t3 |"
summary ""
summary "Seconds from Ping to callback (block times): $((t3 - t1))"
