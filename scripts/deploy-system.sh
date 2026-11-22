#!/usr/bin/env bash
# Deploys the system in the order of SPEC.md section 7:
#   Base Sepolia: DemoToken, MorphoVaultMaker (on Morpho's own VaultV2Factory) -> compute NoticeExit's address ->
#   Lasna: NoticeReactive -> Base Sepolia: NoticeExit with the maker as its vault list, then checks NoticeExit landed on
# the computed address and reads every value back; only then funds both (lREACT for reactions, ETH for callback fees),
# settles any debt they ran up meanwhile, and makes one smoke vault through the maker and checks its shape.
# Nothing is sent to a contract before the wiring is checked. The values below are the ones of this deployment; the
# 2026-11-18 deployment used other values (SPEC.md section 9).
#
# Environment: BASE_RPC, LASNA_RPC, CALLBACK_PROXY, MORPHO_FACTORY (Morpho's VaultV2Factory), DEPLOY_KEY,
#   REACTIVE_FUND (lREACT for NoticeReactive, in coins, decimals allowed), EXIT_FUND (Base ETH for NoticeExit),
#   BASE_GAS_MARGIN, LASNA_GAS_MARGIN.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/chain.sh
source scripts/chain.sh

# Values of this deployment (SPEC.md sections 4, 6, 9)
VAULT_TIMELOCK=180 # waiting period the maker sets on the four watched kinds of change
LEAD=120 # covers MAX_TIMED (8) Cron10 ticks of 10.7 s plus the callback trip (SPEC.md section 6)
MAX_WAIT=200
CALLBACK_GAS=1000000 # about 809,700 reaches exit() on Base Sepolia (600,000 gives about 416,000); SPEC.md section 12
MAX_ACTIVE=1000
MAX_REACTIONS=16
ARMS_PER_ADDRESS_PER_DAY=4
ARMS_PER_DAY=50
LIFETIME=86400 # anyone can expire a timer watch after one day; a leave-now watch has no expiry (SPEC.md section 9)
TIMED_ARMS_PER_DAY=4 # timer-mode arms per UTC day, all addresses together (SPEC.md section 9)
HEALTH_MIN_FLOAT=4 # lREACT; the health check's float threshold, written to the deployment file
MAX_TIMED_EXPECTED=8
MIN_CALLBACK_GAS_EXPECTED=400000
NOBODY=0x000000000000000000000000000000000000dEaD

need_env BASE_RPC LASNA_RPC CALLBACK_PROXY MORPHO_FACTORY REACTIVE_FUND EXIT_FUND
need_key
check_chain "$BASE_RPC" "$BASE_CHAIN_ID" "Base Sepolia"
check_chain "$LASNA_RPC" "$LASNA_CHAIN_ID" "Lasna"
[ -n "$(cast code --rpc-url "$BASE_RPC" "$CALLBACK_PROXY" 2>/dev/null | sed 's/^0x$//')" ] \
  || die "no contract at the callback proxy $CALLBACK_PROXY (or code unknown)"
[ -n "$(cast code --rpc-url "$BASE_RPC" "$MORPHO_FACTORY" 2>/dev/null | sed 's/^0x$//')" ] \
  || die "no contract at Morpho's factory $MORPHO_FACTORY (or code unknown)"
listed="$(cast call --rpc-url "$BASE_RPC" "$MORPHO_FACTORY" 'isVaultV2(address)(bool)' "$NOBODY" 2>/dev/null)" \
  || die "Morpho's factory did not answer isVaultV2 (unknown)"
[ "$listed" = false ] || die "Morpho's factory answered isVaultV2($NOBODY) = '$listed', expected false"

reactive_fund="$(to_wei "$REACTIVE_FUND")"
exit_fund="$(to_wei "$EXIT_FUND")"
check_balance "$BASE_RPC" "Base Sepolia" "$(add_wei "$exit_fund" "$(to_wei "${BASE_GAS_MARGIN:-0.005}")")"
check_balance "$LASNA_RPC" "Lasna" "$(add_wei "$reactive_fund" "$(to_wei "${LASNA_GAS_MARGIN:-1}")")"

forge build >/dev/null

res="$(deploy "$BASE_RPC" "DemoToken (Base Sepolia)" src/demo/DemoToken.sol:DemoToken 0)"
read -r token token_tx <<<"$res"
res="$(deploy "$BASE_RPC" "MorphoVaultMaker (Base Sepolia)" src/morpho/MorphoVaultMaker.sol:MorphoVaultMaker 0 \
  --constructor-args "$MORPHO_FACTORY" "$token" "$VAULT_TIMELOCK")"
read -r maker maker_tx <<<"$res"

predicted_exit="$(next_address "$BASE_RPC")"
echo "NoticeExit will be at $predicted_exit"

res="$(deploy "$LASNA_RPC" "NoticeReactive (Lasna)" src/NoticeReactive.sol:NoticeReactive 0 \
  --constructor-args "$BASE_CHAIN_ID" "$predicted_exit" "$CRON10_TOPIC" "$LEAD" "$MAX_WAIT" "$CALLBACK_GAS" \
  "$MAX_ACTIVE" "$MAX_REACTIONS")"
read -r reactive reactive_tx <<<"$res"

res="$(deploy "$BASE_RPC" "NoticeExit (Base Sepolia)" src/NoticeExit.sol:NoticeExit 0 \
  --constructor-args "$CALLBACK_PROXY" "$reactive" "$maker" "$ARMS_PER_ADDRESS_PER_DAY" "$ARMS_PER_DAY" \
  "$LIFETIME" "$TIMED_ARMS_PER_DAY")"
read -r exit_c exit_tx <<<"$res"

same_address "$exit_c" "$predicted_exit" \
  || die "NoticeExit landed at $exit_c, not at the computed $predicted_exit: the reactive contract watches another address"

# Read back the wiring and every value (read-only calls). An empty or failed read stops the script.
read_uint() { # rpc address signature [args...] -> first word of the answer
  local v
  v="$(cast call --rpc-url "$1" "$2" "$3" "${@:4}" 2>/dev/null | awk '{print $1}')" || die "$3 on $2 unknown (RPC error)"
  [ -n "$v" ] || die "$3 on $2 unknown (empty answer)"
  echo "$v"
}
expect_uint() { # label got expected
  [ "$2" = "$3" ] || die "$1 is $2, expected $3"
  echo "read back $1 = $2"
}
same_address "$(cast call --rpc-url "$LASNA_RPC" "$reactive" 'EXIT()(address)')" "$exit_c" || die "NoticeReactive.EXIT mismatch"
same_address "$(cast call --rpc-url "$BASE_RPC" "$exit_c" 'REGISTRY()(address)')" "$maker" || die "NoticeExit.REGISTRY is not the maker"
same_address "$(cast call --rpc-url "$BASE_RPC" "$maker" 'FACTORY()(address)')" "$MORPHO_FACTORY" || die "MorphoVaultMaker.FACTORY mismatch"
same_address "$(cast call --rpc-url "$BASE_RPC" "$maker" 'ASSET()(address)')" "$token" || die "MorphoVaultMaker.ASSET mismatch"
expect_uint "MorphoVaultMaker.TIMELOCK" "$(read_uint "$BASE_RPC" "$maker" 'TIMELOCK()(uint256)')" "$VAULT_TIMELOCK"
expect_uint "NoticeExit.MAX_ARMS_PER_ADDRESS_PER_DAY" \
  "$(read_uint "$BASE_RPC" "$exit_c" 'MAX_ARMS_PER_ADDRESS_PER_DAY()(uint256)')" "$ARMS_PER_ADDRESS_PER_DAY"
expect_uint "NoticeExit.MAX_ARMS_PER_DAY" "$(read_uint "$BASE_RPC" "$exit_c" 'MAX_ARMS_PER_DAY()(uint256)')" "$ARMS_PER_DAY"
expect_uint "NoticeExit.LIFETIME" "$(read_uint "$BASE_RPC" "$exit_c" 'LIFETIME()(uint256)')" "$LIFETIME"
expect_uint "NoticeExit.MAX_TIMED_ARMS_PER_DAY" \
  "$(read_uint "$BASE_RPC" "$exit_c" 'MAX_TIMED_ARMS_PER_DAY()(uint256)')" "$TIMED_ARMS_PER_DAY"
expect_uint "NoticeReactive.ORIGIN_CHAIN_ID" "$(read_uint "$LASNA_RPC" "$reactive" 'ORIGIN_CHAIN_ID()(uint256)')" "$BASE_CHAIN_ID"
expect_uint "NoticeReactive.LEAD" "$(read_uint "$LASNA_RPC" "$reactive" 'LEAD()(uint256)')" "$LEAD"
expect_uint "NoticeReactive.MAX_WAIT" "$(read_uint "$LASNA_RPC" "$reactive" 'MAX_WAIT()(uint256)')" "$MAX_WAIT"
expect_uint "NoticeReactive.CALLBACK_GAS" "$(read_uint "$LASNA_RPC" "$reactive" 'CALLBACK_GAS()(uint64)')" "$CALLBACK_GAS"
expect_uint "NoticeReactive.MAX_ACTIVE" "$(read_uint "$LASNA_RPC" "$reactive" 'MAX_ACTIVE()(uint256)')" "$MAX_ACTIVE"
expect_uint "NoticeReactive.MAX_REACTIONS" "$(read_uint "$LASNA_RPC" "$reactive" 'MAX_REACTIONS()(uint256)')" "$MAX_REACTIONS"
expect_uint "NoticeReactive.MAX_TIMED" "$(read_uint "$LASNA_RPC" "$reactive" 'MAX_TIMED()(uint256)')" "$MAX_TIMED_EXPECTED"
expect_uint "NoticeReactive.MIN_CALLBACK_GAS" \
  "$(read_uint "$LASNA_RPC" "$reactive" 'MIN_CALLBACK_GAS()(uint64)')" "$MIN_CALLBACK_GAS_EXPECTED"

# Wiring checked: fund both, then settle whatever debt they ran up while empty (a debt blocks delivery).
send "$LASNA_RPC" "fund NoticeReactive" "$reactive" --value "$reactive_fund" >/dev/null
send "$BASE_RPC" "fund NoticeExit" "$exit_c" --value "$exit_fund" >/dev/null
send "$LASNA_RPC" "NoticeReactive.coverDebt" "$reactive" 'coverDebt()' >/dev/null
send "$BASE_RPC" "NoticeExit.coverDebt" "$exit_c" 'coverDebt()' >/dev/null

# Smoke: one vault through the maker, on Morpho's factory, and its shape.
smoke_tx="$(send "$BASE_RPC" "smoke: MorphoVaultMaker.create" "$maker" 'create()')"
smoke="$(cast call --rpc-url "$BASE_RPC" "$maker" 'lastVaultOf(address)(address)' "$DEPLOYER")" || die "smoke vault unknown"
[ "$smoke" != "0x0000000000000000000000000000000000000000" ] || die "the maker reports no vault for the deployer"
[ "$(cast call --rpc-url "$BASE_RPC" "$maker" 'isVault(address)(bool)' "$smoke")" = true ] \
  || die "smoke vault $smoke is not listed by the maker"
[ "$(cast call --rpc-url "$BASE_RPC" "$MORPHO_FACTORY" 'isVaultV2(address)(bool)' "$smoke")" = true ] \
  || die "smoke vault $smoke is not listed by Morpho's factory"
same_address "$(cast call --rpc-url "$BASE_RPC" "$smoke" 'curator()(address)')" "$DEPLOYER" || die "smoke vault curator is not the caller"
same_address "$(cast call --rpc-url "$BASE_RPC" "$smoke" 'owner()(address)')" "$DEPLOYER" || die "smoke vault owner is not the caller"
for f in 'addAdapter(address)' 'setIsAllocator(address,bool)' 'increaseAbsoluteCap(bytes,uint256)' \
  'increaseRelativeCap(bytes,uint256)'; do
  expect_uint "smoke vault timelock of $f" \
    "$(read_uint "$BASE_RPC" "$smoke" 'timelock(bytes4)(uint256)' "$(cast sig "$f")")" "$VAULT_TIMELOCK"
done
for f in 'setReceiveSharesGate(address)' 'setSendSharesGate(address)' 'setReceiveAssetsGate(address)' \
  'setSendAssetsGate(address)' 'setPerformanceFee(uint256)' 'setManagementFee(uint256)'; do
  [ "$(cast call --rpc-url "$BASE_RPC" "$smoke" 'abdicated(bytes4)(bool)' "$(cast sig "$f")")" = true ] \
    || die "smoke vault: $f is not abdicated"
  echo "read back smoke: $f abdicated"
done

summary "### Notice Period deployment"
summary ""
summary "| Contract | Chain | Address | Transaction |"
summary "|---|---|---|---|"
summary "| DemoToken (ours, test only) | Base Sepolia | \`$token\` | \`$token_tx\` |"
summary "| MorphoVaultMaker (ours; vaults from Morpho's factory \`$MORPHO_FACTORY\`) | Base Sepolia | \`$maker\` | \`$maker_tx\` |"
summary "| NoticeReactive | Lasna | \`$reactive\` | \`$reactive_tx\` |"
summary "| NoticeExit | Base Sepolia | \`$exit_c\` | \`$exit_tx\` |"
summary "| Smoke vault (Morpho Vault V2) | Base Sepolia | \`$smoke\` | \`$smoke_tx\` |"
summary ""
summary "Loop inputs: token=$token factory=$maker exit=$exit_c reactive=$reactive"
summary ""
summary "Content of \`deployments/current.json\` (commit it with the page change, then run \`python3 scripts/stamp.py\`):"
summary ""
summary '```json'
deployment_json="$(python3 - "$token" "$maker" "$MORPHO_FACTORY" "$reactive" "$exit_c" "$CALLBACK_PROXY" "$DEPLOYER" \
  "$token_tx" "$maker_tx" "$reactive_tx" "$exit_tx" "$smoke" "$smoke_tx" "${GITHUB_SHA:-unknown}" \
  "$VAULT_TIMELOCK" "$LEAD" "$MAX_WAIT" "$CALLBACK_GAS" "$MAX_ACTIVE" "$MAX_REACTIONS" "$MAX_TIMED_EXPECTED" \
  "$ARMS_PER_ADDRESS_PER_DAY" "$ARMS_PER_DAY" "$TIMED_ARMS_PER_DAY" "$LIFETIME" "$HEALTH_MIN_FLOAT" <<'PY'
import json, sys
a = sys.argv[1:]
names = ["VAULT_TIMELOCK", "LEAD", "MAX_WAIT", "CALLBACK_GAS", "MAX_ACTIVE", "MAX_REACTIONS", "MAX_TIMED",
         "ARMS_PER_ADDRESS_PER_DAY", "ARMS_PER_DAY", "TIMED_ARMS_PER_DAY", "LIFETIME"]
doc = {
    "name": "current",
    "status": "deployed",
    "commit": a[13],
    "origin": {"name": "Base Sepolia", "chainId": 84532},
    "reactive": {"name": "Reactive Lasna", "chainId": 5318007},
    "contracts": {"token": a[0], "maker": a[1], "morphoFactory": a[2], "reactive": a[3], "exit": a[4],
                  "callbackProxy": a[5]},
    "deployTxs": {"token": a[7], "maker": a[8], "reactive": a[9], "exit": a[10]},
    "smokeVault": {"address": a[11], "tx": a[12]},
    "operators": [a[6]],
    "values": {n: int(v) for n, v in zip(names, a[14:25])},
    "healthMinFloat": a[25],
}
print(json.dumps(doc, indent=2))
PY
)" || die "could not write the deployment file content"
while IFS= read -r line; do summary "$line"; done <<<"$deployment_json"
summary '```'
output NP_TOKEN "$token"
output NP_FACTORY "$maker"
output NP_EXIT "$exit_c"
output NP_REACTIVE "$reactive"
