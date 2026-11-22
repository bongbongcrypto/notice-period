#!/usr/bin/env bash
# Deploys the system in the order of SPEC.md section 7:
#   Base Sepolia: DemoToken, MorphoVaultMaker (on Morpho's own VaultV2Factory) -> compute NoticeExit's address ->
#   Lasna: NoticeReactive -> Base Sepolia: NoticeExit with the maker as its vault list, then checks NoticeExit landed on
# the computed address and reads every value back; only then funds both (lREACT for reactions, ETH for callback fees),
# settles any debt they ran up meanwhile, and makes one smoke vault through the maker and checks its shape.
# Last it prints the whole deployment file, deployments/<UTC date>.json, between NP-DEPLOYMENT-JSON-BEGIN and
# NP-DEPLOYMENT-JSON-END (log and job summary): name, sourceCommit, deployRun, addresses, operators (key A, key B),
# values, rules and the build list verify.yml needs. Commit it to main before any loop, verify or health run on this
# deployment: those read only that file. Nothing is sent to a contract before the wiring is checked. The values below are the ones of this deployment; the
# 2026-11-18 deployment used other values (SPEC.md section 9).
#
# Environment: BASE_RPC, LASNA_RPC, CALLBACK_PROXY, MORPHO_FACTORY (Morpho's VaultV2Factory), DEPLOY_KEY,
#   REACTIVE_FUND (lREACT for NoticeReactive, in coins, decimals allowed), EXIT_FUND (Base ETH for NoticeExit; the
#   workflow default 0.007 pays about 1,180 exits that burn the whole callback limit at 0.006 gwei, SPEC.md
#   section 12), BASE_GAS_MARGIN, LASNA_GAS_MARGIN. GITHUB_SHA and GITHUB_RUN_ID (set by Actions) go into the file.
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
derive_key_b # only ADDR_B, for the operators list; key B sends nothing here (called directly, never in $(...))
# Name of the deployment file: the UTC date of this deploy, with -2, -3, ... if a file of that name is already here.
deploy_date="$(date -u +%Y-%m-%d)"
deploy_name="$deploy_date"
n=2
while [ -e "deployments/$deploy_name.json" ]; do
  deploy_name="$deploy_date-$n"
  n=$((n + 1))
done
echo "deployment file name: deployments/$deploy_name.json"
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

# Creation blocks for the build list (informational; no script reads them). The contracts are deployed and funded by
# now, so a failed read leaves the field out and never stops the run before the deployment file is printed.
token_blk="$(tx_block "$BASE_RPC" "$token_tx" 2>/dev/null)" || token_blk=""
maker_blk="$(tx_block "$BASE_RPC" "$maker_tx" 2>/dev/null)" || maker_blk=""
reactive_blk="$(tx_block "$LASNA_RPC" "$reactive_tx" 2>/dev/null)" || reactive_blk=""
exit_blk="$(tx_block "$BASE_RPC" "$exit_tx" 2>/dev/null)" || exit_blk=""

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
deployment_json="$(python3 - "$token" "$maker" "$MORPHO_FACTORY" "$reactive" "$exit_c" "$CALLBACK_PROXY" "$DEPLOYER" \
  "$token_tx" "$maker_tx" "$reactive_tx" "$exit_tx" "$smoke" "$smoke_tx" "${GITHUB_SHA:-unknown}" \
  "$VAULT_TIMELOCK" "$LEAD" "$MAX_WAIT" "$CALLBACK_GAS" "$MAX_ACTIVE" "$MAX_REACTIONS" "$MAX_TIMED_EXPECTED" \
  "$ARMS_PER_ADDRESS_PER_DAY" "$ARMS_PER_DAY" "$TIMED_ARMS_PER_DAY" "$LIFETIME" "$HEALTH_MIN_FLOAT" \
  "$deploy_name" "$CRON10_TOPIC" "$ADDR_B" "$token_blk" "$maker_blk" "$reactive_blk" "$exit_blk" "${GITHUB_RUN_ID:-}" \
  "$BASE_CHAIN_ID" "$LASNA_CHAIN_ID" <<'PY'
import json, sys
a = sys.argv[1:]
base, lasna = int(a[34]), int(a[35])


def words(*vals):  # ABI encoding of static arguments (addresses and unsigned integers): one 32-byte word each
    out = ""
    for v in vals:
        n = int(v, 16) if v.lower().startswith("0x") else int(v)
        assert 0 <= n < 2 ** 256, v
        out += n.to_bytes(32, "big").hex()
    return "0x" + out


def entry(key, chain, address, artifact, ctor, tx, block):
    e = {"key": key, "chainId": chain, "address": address, "artifact": artifact, "constructorArgs": ctor,
         "creationTx": tx}
    if block.isdigit():
        e["creationBlock"] = int(block)
    return e


names = ["VAULT_TIMELOCK", "LEAD", "MAX_WAIT", "CALLBACK_GAS", "MAX_ACTIVE", "MAX_REACTIONS", "MAX_TIMED",
         "ARMS_PER_ADDRESS_PER_DAY", "ARMS_PER_DAY", "TIMED_ARMS_PER_DAY", "LIFETIME"]
values = {n: int(v) for n, v in zip(names, a[14:25])}
doc = {
    "name": a[26],
    "status": "deployed",
    "note": "Made by the deploy-system workflow run deployRun from sourceCommit; scripts/deploy-system.sh printed this "
            "file. The smoke vault and every vault the maker makes are Morpho Vault V2 bytecode from Morpho's "
            "factory, so they are not in build; their check is isVaultV2 on that factory.",
    "sourceCommit": a[13],
    "commit": a[13],
}
if a[33].isdigit():
    doc["deployRun"] = int(a[33])
doc.update({
    "registryKind": "maker",
    "origin": {"name": "Base Sepolia", "chainId": base},
    "reactive": {"name": "Reactive Lasna", "chainId": lasna},
    "contracts": {"token": a[0], "maker": a[1], "morphoFactory": a[2], "exit": a[4], "reactive": a[3],
                  "callbackProxy": a[5]},
    "deployTxs": {"token": a[7], "maker": a[8], "reactive": a[9], "exit": a[10]},
    "smokeVault": {"address": a[11], "tx": a[12]},
    # Constructor arguments in the order of this script's forge create calls (SPEC.md section 7).
    "build": [
        entry("token", base, a[0], "src/demo/DemoToken.sol:DemoToken", "0x", a[7], a[29]),
        entry("maker", base, a[1], "src/morpho/MorphoVaultMaker.sol:MorphoVaultMaker",
              words(a[2], a[0], a[14]), a[8], a[30]),
        entry("reactive", lasna, a[3], "src/NoticeReactive.sol:NoticeReactive",
              words(str(base), a[4], a[27], a[15], a[16], a[17], a[18], a[19]), a[9], a[31]),
        entry("exit", base, a[4], "src/NoticeExit.sol:NoticeExit",
              words(a[5], a[3], a[1], a[21], a[22], a[24], a[23]), a[10], a[32]),
    ],
    "operators": [a[6], a[28]],
    "values": values,
    "rules": {"leaveNowExpires": False, "timedCap": values["MAX_TIMED"],
              "timedArmsPerDay": values["TIMED_ARMS_PER_DAY"], "vaultSource": "maker"},
    "healthMinFloat": a[25],
})
print(json.dumps(doc, indent=2))
PY
)" || die "could not write the deployment file content"
summary "Deployment file: commit this content to main as \`deployments/$deploy_name.json\` before any loop, verify or"
summary "health run on this deployment (they read only that file), then stamp the page branch with"
summary "\`python3 scripts/stamp.py deployments/$deploy_name.json\` (the path written out)."
summary ""
summary "NP-DEPLOYMENT-JSON-BEGIN deployments/$deploy_name.json"
summary '```json'
while IFS= read -r line; do summary "$line"; done <<<"$deployment_json"
summary '```'
summary "NP-DEPLOYMENT-JSON-END"

# The printed file must load in the readers that will use it (deployment.py for loop, verify and health; stamp.py for
# the page) and list exactly our four contracts in build. A failure here is a defect of this script: the contracts
# stay deployed, and the content above is still the hand-off once corrected by hand.
check_dir="$(mktemp -d)"
mkdir -p "$check_dir/deployments"
printf '%s\n' "$deployment_json" > "$check_dir/deployments/$deploy_name.json"
python3 - "$check_dir" "$deploy_name" "$DEPLOYER" "$ADDR_B" <<'PY' || die "the printed deployment file does not pass its own readers"
import re, sys
from pathlib import Path
sys.path.insert(0, "scripts")
import deployment, stamp
root, name, key_a, key_b = sys.argv[1:5]
doc, out = deployment.load(name, root=root)
stamp.load(str(Path(root) / "deployments" / f"{name}.json"))
assert out["factory_kind"] == "maker", out
assert [x.lower() for x in doc["operators"]] == [key_a.lower(), key_b.lower()], "operators must be key A, key B"
build = doc["build"]
assert [b["key"] for b in build] == ["token", "maker", "reactive", "exit"], "build: our four contracts only"
for b in build:
    assert b["address"].lower() == doc["contracts"][b["key"]].lower(), b["key"]
    assert b["chainId"] == (doc["reactive"] if b["key"] == "reactive" else doc["origin"])["chainId"], b["key"]
    src, _, contract = b["artifact"].partition(":")
    assert contract and Path(src).is_file(), b["artifact"]
    assert re.fullmatch(r"0x([0-9a-f]{64})*", b["constructorArgs"]), b["key"]
print(f"deployment file check passed: deployment.py and stamp.py load it; build lists {len(build)} contracts")
PY
rm -rf "$check_dir"

# Each creation input must end with its recorded constructor arguments (what Sourcify will be given). An unreadable
# input is "unknown" and only warned about; a readable one that differs stops the run (red, contracts deployed).
while read -r key rpc tx ctor; do
  input="$(cast tx --rpc-url "$rpc" "$tx" input 2>/dev/null)" || input=""
  if [ -z "$input" ]; then
    summary "WARNING: creation input of $key unknown (RPC error); its constructorArgs are not checked"
    continue
  fi
  case "$(echo "$input" | tr 'A-F' 'a-f')" in
    *"${ctor#0x}") echo "constructor arguments of $key: the end of its creation input (checked)" ;;
    *) die "the creation input of $key does not end with the recorded constructorArgs" ;;
  esac
done < <(python3 -c '
import json, sys
d = json.loads(sys.argv[1])
rpc = {d["origin"]["chainId"]: sys.argv[2], d["reactive"]["chainId"]: sys.argv[3]}
for b in d["build"]:
    if b["constructorArgs"] != "0x":
        print(b["key"], rpc[b["chainId"]], b["creationTx"], b["constructorArgs"])
' "$deployment_json" "$BASE_RPC" "$LASNA_RPC")

# The float is staged: 1 lREACT at deployment, 8 more after the first loop on this pair, so health on this deployment
# is red until that top-up. Said here so nobody reads a red health run as a broken deployment.
if python3 -c 'import sys; sys.exit(0 if int(sys.argv[1]) < int(sys.argv[2]) else 1)' "$reactive_fund" \
  "$(to_wei "$HEALTH_MIN_FLOAT")"; then
  summary ""
  summary "Float $REACTIVE_FUND lREACT is under this deployment's health threshold $HEALTH_MIN_FLOAT lREACT: health.yml on"
  summary "this deployment is RED until a loop.yml topup (deployment input $deploy_name, never the 2026-11-18 default)"
  summary "brings the float to at least $HEALTH_MIN_FLOAT plus what the runs before it spend."
fi
output NP_TOKEN "$token"
output NP_FACTORY "$maker"
output NP_EXIT "$exit_c"
output NP_REACTIVE "$reactive"
