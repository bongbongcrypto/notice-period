#!/usr/bin/env bash
# The visitor journey of the demo, run with the testnet key as both depositor and curator:
#   create a vault, mint and deposit demo tokens, approve and arm a watch, wait until Lasna has subscribed,
#   schedule a new adapter (hash 1), wait for ExitRequested on Lasna (hash 2) and WatchEnded on Base Sepolia (hash 3).
# Prints the three hashes, the seconds between hash 1 and hash 3, and the deposit before and after.
#
# Environment: BASE_RPC, LASNA_RPC, DEPLOY_KEY, NP_TOKEN, NP_FACTORY, NP_EXIT, NP_REACTIVE,
#   LOOP_MODE (0 leave now, 1 leave if still pending; default 0), LOOP_AMOUNT (whole demo tokens, default 100),
#   LOOP_TIMEOUT (seconds per wait, default 300; mode 1 adds the 180 s timelock), SUBSCRIBE_GRACE (seconds
#   between "subscribed" on Lasna and the curator action, default 15).
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/chain.sh
source scripts/chain.sh

need_env BASE_RPC LASNA_RPC NP_TOKEN NP_FACTORY NP_EXIT NP_REACTIVE
need_key
check_chain "$BASE_RPC" "$BASE_CHAIN_ID" "Base Sepolia"
check_chain "$LASNA_RPC" "$LASNA_CHAIN_ID" "Lasna"
check_balance "$BASE_RPC" "Base Sepolia" "$(to_wei 0.002)"

mode="${LOOP_MODE:-0}"
[ "$mode" = 0 ] || [ "$mode" = 1 ] || die "LOOP_MODE must be 0 or 1"
amount_tokens="${LOOP_AMOUNT:-100}"
[[ "$amount_tokens" =~ ^[0-9]+$ ]] && [ "$amount_tokens" -ge 1 ] && [ "$amount_tokens" -le 1000 ] \
  || die "LOOP_AMOUNT must be a whole number of tokens from 1 to 1000"
amount=$((amount_tokens * 1000000)) # 6 decimals
timeout="${LOOP_TIMEOUT:-300}"
[ "$mode" = 0 ] || timeout=$((timeout + 180))
kinds=7 # default kinds: new adapter, shorter timelock, allocator

lasna_from="$(block_number "$LASNA_RPC")"
base_from="$(block_number "$BASE_RPC")"

# 1. own vault
send "$BASE_RPC" "create vault" "$NP_FACTORY" "create()" >/dev/null
vault="$(cast call --rpc-url "$BASE_RPC" "$NP_FACTORY" 'lastVaultOf(address)(address)' "$DEPLOYER")" \
  || die "vault address unknown"
[ "$vault" != "0x0000000000000000000000000000000000000000" ] || die "factory reports no vault for the deployer"
echo "vault: $vault"

# 2. deposit
send "$BASE_RPC" "mint demo tokens" "$NP_TOKEN" "mint(address,uint256)" "$DEPLOYER" "$amount" >/dev/null
send "$BASE_RPC" "approve vault" "$NP_TOKEN" "approve(address,uint256)" "$vault" "$amount" >/dev/null
send "$BASE_RPC" "deposit" "$vault" "deposit(uint256,address)" "$amount" "$DEPLOYER" >/dev/null
shares="$(cast call --rpc-url "$BASE_RPC" "$vault" 'balanceOf(address)(uint256)' "$DEPLOYER" | awk '{print $1}')"
tokens_before="$(cast call --rpc-url "$BASE_RPC" "$NP_TOKEN" 'balanceOf(address)(uint256)' "$DEPLOYER" | awk '{print $1}')"
echo "shares: $shares, wallet tokens before: $tokens_before"

# 3. arm
send "$BASE_RPC" "approve NoticeExit for the shares" "$vault" "approve(address,uint256)" "$NP_EXIT" "$shares" >/dev/null
arm_tx="$(send "$BASE_RPC" "arm" "$NP_EXIT" "arm(address,uint8,uint8,uint256)" "$vault" "$kinds" "$mode" "$shares")"
watch_id="$(cast call --rpc-url "$BASE_RPC" "$NP_EXIT" 'activeWatchOf(address,address)(uint256)' "$DEPLOYER" "$vault" | awk '{print $1}')"
[ -n "$watch_id" ] && [ "$watch_id" != 0 ] || die "watch id unknown after arm $arm_tx"
watch_topic="$(cast to-uint256 "$watch_id")"
echo "watch: $watch_id"

wait_log "$LASNA_RPC" "subscribed on Lasna" "$lasna_from" "$NP_REACTIVE" \
  "WatchSubscribed(uint256,address,uint8,uint8)" "$timeout" "$watch_topic" >/dev/null
# How soon a subscription made inside react() catches events is not documented (SPEC.md section 12).
sleep "${SUBSCRIBE_GRACE:-15}"

# 4. curator action: hash 1
adapter="$(cast compute-address --nonce 0 "$vault" | awk '{print $NF}')" # any address; only the event matters
data="$(cast calldata 'addAdapter(address)' "$adapter")"
hash1="$(send "$BASE_RPC" "1. curator schedules a new adapter (Base Sepolia)" "$vault" "submit(bytes)" "$data")"

# 5. reactive transaction: hash 2; 6. callback: hash 3
hash2="$(wait_log "$LASNA_RPC" "2. ExitRequested on Lasna" "$lasna_from" "$NP_REACTIVE" \
  "ExitRequested(uint256,uint256,uint8,bytes32)" "$timeout" "$watch_topic" "$hash1")"
hash3="$(wait_log "$BASE_RPC" "3. WatchEnded on Base Sepolia" "$base_from" "$NP_EXIT" \
  "WatchEnded(uint256,uint256,uint8,uint8,uint256,uint256)" "$timeout" "$watch_topic" "$hash1")"

t1="$(tx_block_time "$BASE_RPC" "$hash1")"
t3="$(tx_block_time "$BASE_RPC" "$hash3")"
tokens_after="$(cast call --rpc-url "$BASE_RPC" "$NP_TOKEN" 'balanceOf(address)(uint256)' "$DEPLOYER" | awk '{print $1}')"
shares_after="$(cast call --rpc-url "$BASE_RPC" "$vault" 'balanceOf(address)(uint256)' "$DEPLOYER" | awk '{print $1}')"

summary "### Notice Period loop (mode $mode)"
summary ""
summary "| Step | Chain | Transaction |"
summary "|---|---|---|"
summary "| 1. Curator schedules a new adapter | Base Sepolia | \`$hash1\` |"
summary "| 2. Reactive transaction (ExitRequested) | Lasna | \`$hash2\` |"
summary "| 3. Exit (WatchEnded, shares redeemed) | Base Sepolia | \`$hash3\` |"
summary ""
summary "Seconds from 1 to 3 (block times): $((t3 - t1))"
summary "Vault: $vault, watch $watch_id. Shares $shares -> $shares_after. Wallet demo tokens $tokens_before -> $tokens_after (6 decimals)."
[ "$shares_after" = 0 ] || die "shares are still in the vault after the exit"
