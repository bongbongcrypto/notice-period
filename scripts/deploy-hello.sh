#!/usr/bin/env bash
# Deploys the hello-world pair: HelloOrigin and HelloCallback on Base Sepolia, HelloReactive on Lasna.
# Order (no setter anywhere): origin -> compute the callback's address -> reactive -> callback, then check the
# callback landed on the computed address.
#
# Environment: BASE_RPC, LASNA_RPC, CALLBACK_PROXY, DEPLOY_KEY,
#   REACTIVE_FUND (lREACT sent to HelloReactive, whole coins), CALLBACK_FUND (Base ETH sent to HelloCallback),
#   BASE_GAS_MARGIN, LASNA_GAS_MARGIN (whole coins kept for gas; checked before anything is sent).
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/chain.sh
source scripts/chain.sh

need_env BASE_RPC LASNA_RPC CALLBACK_PROXY REACTIVE_FUND CALLBACK_FUND
need_key
check_chain "$BASE_RPC" "$BASE_CHAIN_ID" "Base Sepolia"
check_chain "$LASNA_RPC" "$LASNA_CHAIN_ID" "Lasna"
[ -n "$(cast code --rpc-url "$BASE_RPC" "$CALLBACK_PROXY" 2>/dev/null | sed 's/^0x$//')" ] \
  || die "no contract at the callback proxy $CALLBACK_PROXY (or code unknown)"

reactive_fund="$(to_wei "$REACTIVE_FUND")"
callback_fund="$(to_wei "$CALLBACK_FUND")"
check_balance "$BASE_RPC" "Base Sepolia" "$(add_wei "$callback_fund" "$(to_wei "${BASE_GAS_MARGIN:-0.003}")")"
check_balance "$LASNA_RPC" "Lasna" "$(add_wei "$reactive_fund" "$(to_wei "${LASNA_GAS_MARGIN:-1}")")"

forge build >/dev/null

res="$(deploy "$BASE_RPC" "HelloOrigin (Base Sepolia)" src/hello/HelloOrigin.sol:HelloOrigin 0)"
read -r origin origin_tx <<<"$res"

predicted_callback="$(next_address "$BASE_RPC")"
echo "HelloCallback will be at $predicted_callback"

res="$(deploy "$LASNA_RPC" "HelloReactive (Lasna)" src/hello/HelloReactive.sol:HelloReactive "$reactive_fund" \
  --constructor-args "$BASE_CHAIN_ID" "$origin" "$predicted_callback")"
read -r reactive reactive_tx <<<"$res"

res="$(deploy "$BASE_RPC" "HelloCallback (Base Sepolia)" src/hello/HelloCallback.sol:HelloCallback "$callback_fund" \
  --constructor-args "$CALLBACK_PROXY" "$reactive")"
read -r callback callback_tx <<<"$res"

same_address "$callback" "$predicted_callback" \
  || die "HelloCallback landed at $callback, not at the computed $predicted_callback: the reactive contract points elsewhere"

summary "### Hello-world deployment"
summary ""
summary "| Contract | Chain | Address | Transaction |"
summary "|---|---|---|---|"
summary "| HelloOrigin | Base Sepolia | \`$origin\` | \`$origin_tx\` |"
summary "| HelloReactive | Lasna | \`$reactive\` | \`$reactive_tx\` |"
summary "| HelloCallback | Base Sepolia | \`$callback\` | \`$callback_tx\` |"
summary ""
summary "Loop inputs: origin=$origin reactive=$reactive callback=$callback"
output HELLO_ORIGIN "$origin"
output HELLO_REACTIVE "$reactive"
output HELLO_CALLBACK "$callback"
