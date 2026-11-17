#!/usr/bin/env bash
# Deploys the system in the order of SPEC.md section 7:
#   Base Sepolia: DemoToken, DemoVaultFactory -> compute NoticeExit's address ->
#   Lasna: NoticeReactive -> Base Sepolia: NoticeExit, then checks NoticeExit landed on the computed address and
# only then funds both (lREACT for reactions, ETH for callback fees) and settles any debt they ran up meanwhile.
# Nothing is sent to a contract before the wiring is checked. Caps are the demo values of SPEC.md section 9.
#
# Environment: BASE_RPC, LASNA_RPC, CALLBACK_PROXY, DEPLOY_KEY,
#   REACTIVE_FUND (lREACT for NoticeReactive, whole coins), EXIT_FUND (Base ETH for NoticeExit),
#   BASE_GAS_MARGIN, LASNA_GAS_MARGIN.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/chain.sh
source scripts/chain.sh

# Demo values (SPEC.md sections 4, 6, 9)
VAULT_TIMELOCK=180
LEAD=120 # covers MAX_ACTIVE Cron10 ticks (8 x 10.7 s) plus the callback trip (SPEC.md section 6)
MAX_WAIT=900
CALLBACK_GAS=600000
MAX_ACTIVE=8
MAX_REACTIONS=80
ARMS_PER_ADDRESS_PER_DAY=2
ARMS_PER_DAY=10
LIFETIME=86400 # anyone can expire a watch after one day (SPEC.md section 9)

need_env BASE_RPC LASNA_RPC CALLBACK_PROXY REACTIVE_FUND EXIT_FUND
need_key
check_chain "$BASE_RPC" "$BASE_CHAIN_ID" "Base Sepolia"
check_chain "$LASNA_RPC" "$LASNA_CHAIN_ID" "Lasna"
[ -n "$(cast code --rpc-url "$BASE_RPC" "$CALLBACK_PROXY" 2>/dev/null | sed 's/^0x$//')" ] \
  || die "no contract at the callback proxy $CALLBACK_PROXY (or code unknown)"

reactive_fund="$(to_wei "$REACTIVE_FUND")"
exit_fund="$(to_wei "$EXIT_FUND")"
check_balance "$BASE_RPC" "Base Sepolia" "$(add_wei "$exit_fund" "$(to_wei "${BASE_GAS_MARGIN:-0.005}")")"
check_balance "$LASNA_RPC" "Lasna" "$(add_wei "$reactive_fund" "$(to_wei "${LASNA_GAS_MARGIN:-1}")")"

forge build >/dev/null

res="$(deploy "$BASE_RPC" "DemoToken (Base Sepolia)" src/demo/DemoToken.sol:DemoToken 0)"
read -r token token_tx <<<"$res"
res="$(deploy "$BASE_RPC" "DemoVaultFactory (Base Sepolia)" src/demo/DemoVaultFactory.sol:DemoVaultFactory 0 \
  --constructor-args "$token" "$VAULT_TIMELOCK")"
read -r factory factory_tx <<<"$res"

predicted_exit="$(next_address "$BASE_RPC")"
echo "NoticeExit will be at $predicted_exit"

res="$(deploy "$LASNA_RPC" "NoticeReactive (Lasna)" src/NoticeReactive.sol:NoticeReactive 0 \
  --constructor-args "$BASE_CHAIN_ID" "$predicted_exit" "$CRON10_TOPIC" "$LEAD" "$MAX_WAIT" "$CALLBACK_GAS" \
  "$MAX_ACTIVE" "$MAX_REACTIONS")"
read -r reactive reactive_tx <<<"$res"

res="$(deploy "$BASE_RPC" "NoticeExit (Base Sepolia)" src/NoticeExit.sol:NoticeExit 0 \
  --constructor-args "$CALLBACK_PROXY" "$reactive" "$factory" "$ARMS_PER_ADDRESS_PER_DAY" "$ARMS_PER_DAY" \
  "$LIFETIME")"
read -r exit_c exit_tx <<<"$res"

same_address "$exit_c" "$predicted_exit" \
  || die "NoticeExit landed at $exit_c, not at the computed $predicted_exit: the reactive contract watches another address"

# Read back the wiring (read-only calls)
same_address "$(cast call --rpc-url "$LASNA_RPC" "$reactive" 'EXIT()(address)')" "$exit_c" || die "NoticeReactive.EXIT mismatch"
same_address "$(cast call --rpc-url "$BASE_RPC" "$exit_c" 'REGISTRY()(address)')" "$factory" || die "NoticeExit.REGISTRY mismatch"
[ "$(cast call --rpc-url "$BASE_RPC" "$exit_c" 'LIFETIME()(uint256)' | awk '{print $1}')" = "$LIFETIME" ] \
  || die "NoticeExit.LIFETIME mismatch"

# Wiring checked: fund both, then settle whatever debt they ran up while empty (a debt blocks delivery).
send "$LASNA_RPC" "fund NoticeReactive" "$reactive" --value "$reactive_fund" >/dev/null
send "$BASE_RPC" "fund NoticeExit" "$exit_c" --value "$exit_fund" >/dev/null
send "$LASNA_RPC" "NoticeReactive.coverDebt" "$reactive" 'coverDebt()' >/dev/null
send "$BASE_RPC" "NoticeExit.coverDebt" "$exit_c" 'coverDebt()' >/dev/null

summary "### Notice Period deployment"
summary ""
summary "| Contract | Chain | Address | Transaction |"
summary "|---|---|---|---|"
summary "| DemoToken (ours, test only) | Base Sepolia | \`$token\` | \`$token_tx\` |"
summary "| DemoVaultFactory (ours, test only) | Base Sepolia | \`$factory\` | \`$factory_tx\` |"
summary "| NoticeReactive | Lasna | \`$reactive\` | \`$reactive_tx\` |"
summary "| NoticeExit | Base Sepolia | \`$exit_c\` | \`$exit_tx\` |"
summary ""
summary "Loop inputs: token=$token factory=$factory exit=$exit_c reactive=$reactive"
output NP_TOKEN "$token"
output NP_FACTORY "$factory"
output NP_EXIT "$exit_c"
output NP_REACTIVE "$reactive"
