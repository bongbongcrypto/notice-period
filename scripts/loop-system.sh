#!/usr/bin/env bash
# The visitor journey of the demo and the other evidence runs, against one deployment.
#
# Default (LOOP_ACTION=exit): the curator makes a vault, the depositor mints and deposits demo tokens, approves and
# arms a watch, Lasna subscribes, the curator schedules a change of LOOP_KIND (hash 1), and the script waits for
# ExitRequested on Lasna (hash 2) and WatchEnded on Base Sepolia (hash 3). Prints the three hashes, the seconds
# between hash 1 and hash 3, and the deposit before and after; stops unless the deposit came back in full, before the
# change could run.
#
# Keys: key A is DEPLOY_KEY (the testnet key). Key B is derived from it (scripts/chain.sh derive_key_b), so a run can
# have a depositor that is not the curator. Both keys are ours; every run is labelled as our own.
#
# Environment:
#   BASE_RPC, LASNA_RPC, DEPLOY_KEY, NP_TOKEN, NP_FACTORY (DemoVaultFactory or MorphoVaultMaker: both have create(),
#     lastVaultOf(address) and VaultCreated), NP_EXIT, NP_REACTIVE
#   LOOP_MODE          0 leave now (default), 1 leave if still pending
#   LOOP_KIND          adapter (default) | timelock | allocator | cap: the change the curator schedules
#   LOOP_ACTION        exit (default) | ignored-then-exit | revoke-stays | arm-only | fire | burst | cancel |
#                      expire-stale | topup
#   LOOP_DEPOSITOR     a (default) | b: the key that deposits and owns the watch
#   LOOP_CURATOR       a (default) | b: the key that makes the vault and schedules changes
#   LOOP_VAULT         fire, burst: an existing vault
#   LOOP_WATCH         fire, cancel: an existing watch id
#   LOOP_TOPUP         topup: lREACT moved to NoticeReactive (decimals allowed)
#   LOOP_FACTORY_KIND  demo | maker: label of the vault source; burst needs maker (Vault V2 multicall)
#   LOOP_RUN_ID        part of every scheduled change's target address (default: the Actions run id)
#   LOOP_WATCH_KINDS   kinds the armed watch covers (default 7: new adapter, shorter waiting period, new allocator)
#   LOOP_FUND_B        1: key A tops up key B's Base Sepolia ETH when it is below half of LOOP_B_GAS (default 0)
#   LOOP_B_GAS         ETH key A sends key B (default 0.002)
#   LOOP_NO_KEY_A      1: refuse every transaction from key A (health job)
#   LOOP_AMOUNT        whole demo tokens to deposit (default 100)
#   LOOP_TIMEOUT       seconds per wait (default 300; mode 1 adds the 180 s waiting period)
#   LOOP_IGNORE_WAIT   ignored-then-exit: seconds to watch for any reaction to the unwatched change (default 45)
#   LOOP_REVOKE_AFTER  revoke-stays: seconds between ChangeStored and the revoke (default 30)
#   LOOP_BURST_WAIT    burst: seconds to wait after the burst (default 60)
#   LOOP_SCAN          expire-stale: how many of the latest watch ids to look at (default 200)
#   LOOP_RUN_JSON      where run.json is written (default $RUNNER_TEMP/run.json, or ./run.json)
#   SUBSCRIBE_GRACE    seconds between "subscribed" on Lasna and the curator action (default 15)
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/chain.sh
source scripts/chain.sh

need_env BASE_RPC LASNA_RPC NP_TOKEN NP_FACTORY NP_EXIT NP_REACTIVE
need_key
KEY_A="$DEPLOY_KEY"
ADDR_A="$DEPLOYER"
check_chain "$BASE_RPC" "$BASE_CHAIN_ID" "Base Sepolia"
check_chain "$LASNA_RPC" "$LASNA_CHAIN_ID" "Lasna"

mode="${LOOP_MODE:-0}"
kind="${LOOP_KIND:-adapter}"
action="${LOOP_ACTION:-exit}"
depositor="${LOOP_DEPOSITOR:-a}"
curator="${LOOP_CURATOR:-a}"
factory_kind="${LOOP_FACTORY_KIND:-demo}"
run_id="${LOOP_RUN_ID:-${GITHUB_RUN_ID:-$(date +%s)}}"
watch_kinds="${LOOP_WATCH_KINDS:-7}"
amount_tokens="${LOOP_AMOUNT:-100}"
timeout="${LOOP_TIMEOUT:-300}"
run_json="${LOOP_RUN_JSON:-${RUNNER_TEMP:-.}/run.json}"

[ "$mode" = 0 ] || [ "$mode" = 1 ] || die "LOOP_MODE must be 0 or 1"
case "$kind" in adapter | timelock | allocator | cap) ;; *) die "LOOP_KIND must be adapter, timelock, allocator or cap" ;; esac
case "$action" in
  exit | ignored-then-exit | revoke-stays | arm-only | fire | burst | cancel | expire-stale | topup) ;;
  *) die "LOOP_ACTION '$action' is not one of exit, ignored-then-exit, revoke-stays, arm-only, fire, burst, cancel, expire-stale, topup" ;;
esac
case "$depositor" in a | b) ;; *) die "LOOP_DEPOSITOR must be a or b" ;; esac
case "$curator" in a | b) ;; *) die "LOOP_CURATOR must be a or b" ;; esac
case "$factory_kind" in demo | maker) ;; *) die "LOOP_FACTORY_KIND must be demo or maker" ;; esac
[[ "$run_id" =~ ^[0-9]+$ ]] || die "LOOP_RUN_ID must be a number"
[[ "$watch_kinds" =~ ^[0-9]+$ ]] && [ "$watch_kinds" -ge 1 ] && [ "$watch_kinds" -le 15 ] || die "LOOP_WATCH_KINDS must be 1 to 15"
[[ "$amount_tokens" =~ ^[0-9]+$ ]] && [ "$amount_tokens" -ge 1 ] && [ "$amount_tokens" -le 1000 ] \
  || die "LOOP_AMOUNT must be a whole number of tokens from 1 to 1000"
amount=$((amount_tokens * 1000000)) # 6 decimals
[ "$mode" = 0 ] || timeout=$((timeout + 180))

# ---------------------------------------------------------------- run record (run.json), written on every exit
rec_file="$(mktemp)"
rec() { printf '%s\t%s\n' "$1" "$2" >> "$rec_file"; }
finish() {
  local code=$?
  python3 - "$rec_file" "$run_json" "$code" <<'PY' || true
import json, sys
src, out, code = sys.argv[1], sys.argv[2], int(sys.argv[3])
doc = {"result": "ok" if code == 0 else "failed", "exitCode": code}
for line in open(src, encoding="utf-8"):
    k, _, v = line.rstrip("\n").partition("\t")
    if v.isdigit() and len(v) < 16:
        v = int(v)
    if k in doc and not isinstance(doc[k], list):
        doc[k] = [doc[k], v]
    elif k in doc:
        doc[k].append(v)
    else:
        doc[k] = v
with open(out, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
print(f"run record written to {out} ({doc['result']})")
PY
  rm -f "$rec_file" "$rec_file.last"
}
trap finish EXIT

# ---------------------------------------------------------------- keys
key_of() { if [ "$1" = a ]; then echo "$KEY_A"; else echo "$KEY_B"; fi; }
addr_of() { if [ "$1" = a ]; then echo "$ADDR_A"; else echo "$ADDR_B"; fi; }
if [ "$depositor" = b ] || [ "$curator" = b ]; then
  derive_key_b
fi
if [ "${LOOP_NO_KEY_A:-0}" = 1 ] && { [ "$depositor" = a ] || [ "$curator" = a ] || [ "$action" = topup ]; }; then
  die "LOOP_NO_KEY_A=1: depositor and curator must both be key B, and topup is not allowed"
fi
if [ "${LOOP_FUND_B:-0}" = 1 ] && [ -n "${ADDR_B:-}" ]; then
  [ "${LOOP_NO_KEY_A:-0}" = 1 ] && die "LOOP_FUND_B=1 needs key A, which LOOP_NO_KEY_A=1 forbids"
  b_gas="$(to_wei "${LOOP_B_GAS:-0.002}")"
  b_bal="$(cast balance --rpc-url "$BASE_RPC" "$ADDR_B" 2>/dev/null)" || die "key B balance unknown (RPC error)"
  if python3 -c 'import sys; sys.exit(0 if int(sys.argv[1]) * 2 < int(sys.argv[2]) else 1)' "$b_bal" "$b_gas"; then
    send_as "$KEY_A" "$BASE_RPC" "key A tops up key B's gas" "$ADDR_B" --value "$b_gas" >/dev/null
    rec fundB "$b_gas"
  fi
fi
DEP_KEY="$(key_of "$depositor")"
DEP="$(addr_of "$depositor")"
CUR_KEY="$(key_of "$curator")"
CUR="$(addr_of "$curator")"
[ "$action" = topup ] || [ "$action" = expire-stale ] || check_balance_of "$BASE_RPC" "Base Sepolia" "$DEP" "$(to_wei 0.0005)"
rec kind "$kind"; rec mode "$mode"; rec action "$action"; rec factoryKind "$factory_kind"; rec runId "$run_id"
rec depositorKey "$depositor"; rec depositor "$DEP"; rec curatorKey "$curator"; rec curator "$CUR"
rec exit "$NP_EXIT"; rec reactive "$NP_REACTIVE"; rec factory "$NP_FACTORY"

lasna_from="$(block_number "$LASNA_RPC")"
base_from="$(block_number "$BASE_RPC")"
rec baseFrom "$base_from"; rec lasnaFrom "$lasna_from"

# ---------------------------------------------------------------- building blocks
submits=0
kind_bit() {
  case "$1" in adapter) echo 1 ;; timelock) echo 2 ;; allocator) echo 4 ;; cap) echo 8 ;; esac
}
# Calldata of the n-th change of this run on a vault: a distinct target per Submit.
kind_calldata() { # kind vault n
  local t
  t="$(keccak_target "$run_id" "$2" "$3")"
  case "$1" in
    adapter) cast calldata 'addAdapter(address)' "$t" ;;
    timelock) cast calldata 'decreaseTimelock(bytes4,uint256)' "$(cast sig 'addAdapter(address)')" 60 ;;
    allocator) cast calldata 'setIsAllocator(address,bool)' "$t" true ;;
    cap) cast calldata 'increaseAbsoluteCap(bytes,uint256)' "$(cast abi-encode 'f(address)' "$t")" 1 ;;
  esac
}
make_vault() { # -> vault address (curator key makes it)
  local v tx
  tx="$(send_as "$CUR_KEY" "$BASE_RPC" "create vault" "$NP_FACTORY" "create()")"
  v="$(cast call --rpc-url "$BASE_RPC" "$NP_FACTORY" 'lastVaultOf(address)(address)' "$CUR")" || die "vault address unknown"
  [ "$v" != "0x0000000000000000000000000000000000000000" ] || die "the vault source reports no vault for the curator"
  rec createTx "$tx"
  echo "$v"
}
uint_of() { # rpc address signature [args...] -> first word
  local v
  v="$(cast call --rpc-url "$1" "$2" "$3" "${@:4}" 2>/dev/null | awk '{print $1}')" || die "$3 on $2 unknown"
  [ -n "$v" ] || die "$3 on $2 unknown (empty answer)"
  echo "$v"
}
shares_of() { uint_of "$BASE_RPC" "$1" 'balanceOf(address)(uint256)' "$2"; }
tokens_of() { uint_of "$BASE_RPC" "$NP_TOKEN" 'balanceOf(address)(uint256)' "$1"; }
deposit_and_arm() { # vault -> sets shares, watch_id, watch_topic, arm_tx
  local v="$1"
  send_as "$DEP_KEY" "$BASE_RPC" "mint demo tokens" "$NP_TOKEN" "mint(address,uint256)" "$DEP" "$amount" >/dev/null
  send_as "$DEP_KEY" "$BASE_RPC" "approve vault" "$NP_TOKEN" "approve(address,uint256)" "$v" "$amount" >/dev/null
  send_as "$DEP_KEY" "$BASE_RPC" "deposit" "$v" "deposit(uint256,address)" "$amount" "$DEP" >/dev/null
  shares="$(shares_of "$v" "$DEP")"
  send_as "$DEP_KEY" "$BASE_RPC" "approve NoticeExit for the shares" "$v" "approve(address,uint256)" "$NP_EXIT" "$shares" >/dev/null
  arm_tx="$(send_as "$DEP_KEY" "$BASE_RPC" "arm" "$NP_EXIT" "arm(address,uint8,uint8,uint256)" "$v" "$watch_kinds" "$mode" "$shares")"
  watch_id="$(uint_of "$BASE_RPC" "$NP_EXIT" 'activeWatchOf(address,address)(uint256)' "$DEP" "$v")"
  [ "$watch_id" != 0 ] || die "watch id unknown after arm $arm_tx"
  watch_topic="$(cast to-uint256 "$watch_id")"
  echo "watch: $watch_id (owner $DEP, vault $v, kinds $watch_kinds, mode $mode)"
  rec shares "$shares"; rec watchId "$watch_id"; rec armTx "$arm_tx"; rec armBlock "$(tx_block "$BASE_RPC" "$arm_tx")"
}
wait_subscribed() {
  local tx
  tx="$(wait_log "$LASNA_RPC" "subscribed on Lasna" "$lasna_from" "$NP_REACTIVE" \
    "WatchSubscribed(uint256,address,uint8,uint8)" "$timeout" "$watch_topic")"
  rec subscribedTx "$tx"; rec subscribedBlock "$(tx_block "$LASNA_RPC" "$tx")"
  # How soon a subscription made inside react() catches events is not documented (SPEC.md section 12).
  sleep "${SUBSCRIBE_GRACE:-15}"
}
schedule() { # vault kind label -> hash; sets data, executable_at
  submits=$((submits + 1))
  data="$(kind_calldata "$2" "$1" "$submits")"
  local h
  h="$(send_as "$CUR_KEY" "$BASE_RPC" "$3" "$1" "submit(bytes)" "$data")"
  executable_at="$(uint_of "$BASE_RPC" "$1" 'executableAt(bytes)(uint256)' "$data")"
  echo "the change can run from $executable_at"
  rec submitTx "$h"; rec submitKind "$2"; rec submitData "$data"; rec executableAt "$executable_at"
  echo "$h" > "$rec_file.last"
}
reactive_counter() { uint_of "$LASNA_RPC" "$NP_REACTIVE" "$1()(uint256)"; }
lasna_logs() { # from to [topic0 [topic1]] -> JSON
  python3 scripts/logs.py "$LASNA_RPC" "$NP_REACTIVE" "$1" "$2" "${@:3}" || die "Lasna logs $1..$2 unknown"
}
json_count() { python3 -c 'import json, sys; print(json.loads(sys.argv[1])["count"])' "$1"; }
wait_until_base_time() { # unix seconds
  local now
  for _ in $(seq 1 600); do
    now="$(block_time "$BASE_RPC")"
    [ "$now" -ge "$1" ] && return 0
    sleep 2
  done
  die "Base Sepolia time did not reach $1"
}

# Waits for the exit of watch_topic caused by hash1, then checks it (owner = $1, the watch owner).
exit_and_check() { # owner vault hash1
  local owner="$1" v="$2" hash1="$3" hash2 hash3 t1 t3 outcome reason ended_shares ended_assets tokens_after shares_after received
  hash2="$(wait_log "$LASNA_RPC" "2. ExitRequested on Lasna" "$lasna_from" "$NP_REACTIVE" \
    "ExitRequested(uint256,uint256,uint8,bytes32)" "$timeout" "$watch_topic" "$hash1")"
  hash3="$(wait_log "$BASE_RPC" "3. WatchEnded on Base Sepolia" "$base_from" "$NP_EXIT" \
    "WatchEnded(uint256,uint256,uint8,uint8,uint256,uint256)" "$timeout" "$watch_topic" "$hash1")"
  t1="$(tx_block_time "$BASE_RPC" "$hash1")"
  t3="$(tx_block_time "$BASE_RPC" "$hash3")"
  [ "$t3" -ge "$t1" ] || die "the exit $hash3 is older than the curator action $hash1: wrong log"
  check_exit_timing "$t3" "$executable_at" "exit timing"
  read -r outcome reason ended_shares ended_assets <<<"$(watch_ended_fields "$BASE_RPC" "$hash3" "$NP_EXIT" "$watch_topic")"
  tokens_after="$(tokens_of "$owner")"
  shares_after="$(shares_of "$v" "$owner")"
  rec hash1 "$hash1"; rec hash2 "$hash2"; rec hash3 "$hash3"; rec seconds "$((t3 - t1))"
  rec noticeLeft "$((executable_at - t3))"; rec outcome "$outcome"; rec reason "$reason"
  rec endedShares "$ended_shares"; rec endedAssets "$ended_assets"
  summary "| 1. Curator schedules a change ($kind) | Base Sepolia | \`$hash1\` |"
  summary "| 2. Reactive transaction (ExitRequested) | Lasna | \`$hash2\` |"
  summary "| 3. Exit (WatchEnded, shares redeemed) | Base Sepolia | \`$hash3\` |"
  summary ""
  summary "Seconds from 1 to 3 (block times): $((t3 - t1)); the change could run $((executable_at - t3)) s after the exit."
  summary "WatchEnded: outcome $outcome (0 = redeemed), reason $reason, shares $ended_shares, assets $ended_assets."
  summary "Vault: $v, watch $watch_id, owner $owner. Shares $exp_shares -> $shares_after. Owner demo tokens $tokens_before -> $tokens_after (6 decimals)."
  [ "$outcome" = 0 ] || die "the exit did not redeem (outcome $outcome)"
  [ "$ended_shares" = "$exp_shares" ] || die "WatchEnded reports $ended_shares shares, the watch covered $exp_shares"
  received="$(python3 -c 'import sys; print(int(sys.argv[2]) - int(sys.argv[1]))' "$tokens_before" "$tokens_after")"
  [ "$received" = "$ended_assets" ] || die "the owner received $received, WatchEnded reports $ended_assets"
  [ "$shares_after" = 0 ] || die "shares are still in the vault after the exit"
}
last_submit() { cat "$rec_file.last"; }
lasna_status() { # watch id -> status on Lasna (1 armed, 2 exited, 3 cancelled, 4 refused)
  cast call --rpc-url "$LASNA_RPC" "$NP_REACTIVE" 'watches(uint256)(address,uint8,uint8,uint8,uint8,uint32)' "$1"     | sed -n 4p | awk '{print $1}'
}

summary "### Notice Period loop: $action, kind $kind, mode $mode, depositor key $depositor, curator key $curator ($factory_kind vaults)"
summary ""
summary "| Step | Chain | Transaction |"
summary "|---|---|---|"

case "$action" in
  exit | ignored-then-exit | revoke-stays | arm-only)
    if [ "$action" = exit ] && [ $(( $(kind_bit "$kind") & watch_kinds )) = 0 ]; then
      die "the watch (kinds $watch_kinds) does not cover $kind: use ignored-then-exit, or LOOP_WATCH_KINDS"
    fi
    [ "$action" != revoke-stays ] || [ "$mode" = 1 ] || die "revoke-stays is a mode 1 run (LOOP_MODE=1)"
    vault="$(make_vault)"
    echo "vault: $vault"
    rec vault "$vault"
    deposit_and_arm "$vault"
    exp_shares="$shares"
    tokens_before="$(tokens_of "$DEP")"
    wait_subscribed
    ;;
esac

case "$action" in
  exit)
    schedule "$vault" "$kind" "1. curator schedules: $kind (Base Sepolia)"
    exit_and_check "$DEP" "$vault" "$(last_submit)"
    ;;

  ignored-then-exit)
    # A change the watch does not cover (a cap increase) must cause nothing at all on Lasna for this watch.
    [ $((8 & watch_kinds)) = 0 ] || die "ignored-then-exit needs a watch without the cap kind"
    stray0="$(reactive_counter strayEvents)"; unknown0="$(reactive_counter unknownEvents)"
    l0="$(block_number "$LASNA_RPC")"
    schedule "$vault" cap "1a. curator schedules a cap increase (not watched)"
    ignored_tx="$(last_submit)"
    sleep "${LOOP_IGNORE_WAIT:-45}"
    l1="$(block_number "$LASNA_RPC")"
    seen="$(lasna_logs "$l0" "$l1" - "$watch_topic")"
    n_seen="$(json_count "$seen")"
    stray1="$(reactive_counter strayEvents)"; unknown1="$(reactive_counter unknownEvents)"
    st_exit="$(cast call --rpc-url "$BASE_RPC" "$NP_EXIT" 'watches(uint256)(address,uint8,uint8,uint8,address,uint256)' "$watch_id" | sed -n 4p | awk '{print $1}')"
    st_lasna="$(lasna_status "$watch_id")"
    rec ignoredTx "$ignored_tx"; rec ignoredLasnaFrom "$l0"; rec ignoredLasnaTo "$l1"; rec ignoredLogsForWatch "$n_seen"
    rec strayBefore "$stray0"; rec strayAfter "$stray1"; rec unknownBefore "$unknown0"; rec unknownAfter "$unknown1"
    summary "| 1a. Curator schedules a cap increase (not watched): nothing may move | Base Sepolia | \`$ignored_tx\` |"
    summary ""
    summary "Lasna blocks $l0 to $l1: $n_seen logs of NoticeReactive for watch $watch_id; strayEvents $stray0 -> $stray1, unknownEvents $unknown0 -> $unknown1; status on Base $st_exit (1 = active), on Lasna $st_lasna (1 = armed)."
    summary ""
    [ "$n_seen" = 0 ] || die "NoticeReactive logged $n_seen events for watch $watch_id after a change it does not cover"
    [ "$stray0" = "$stray1" ] && [ "$unknown0" = "$unknown1" ] || die "stray or unknown counters moved after the cap increase"
    [ "$st_exit" = 1 ] && [ "$st_lasna" = 1 ] || die "the watch is no longer active after the cap increase (Base $st_exit, Lasna $st_lasna)"
    summary "| Step | Chain | Transaction |"
    summary "|---|---|---|"
    schedule "$vault" "$kind" "1. curator schedules: $kind (Base Sepolia)"
    exit_and_check "$DEP" "$vault" "$(last_submit)"
    ;;

  revoke-stays)
    schedule "$vault" "$kind" "1. curator schedules: $kind (Base Sepolia)"
    hash1="$(last_submit)"
    stored="$(wait_log "$LASNA_RPC" "change stored on Lasna" "$lasna_from" "$NP_REACTIVE" \
      "ChangeStored(uint256,bytes32,uint256,uint256)" "$timeout" "$watch_topic")"
    sleep "${LOOP_REVOKE_AFTER:-30}"
    revoke_tx="$(send_as "$CUR_KEY" "$BASE_RPC" "2. curator revokes the change (Base Sepolia)" "$vault" "revoke(bytes)" "$data")"
    revoked="$(wait_log "$LASNA_RPC" "change revoked on Lasna" "$lasna_from" "$NP_REACTIVE" \
      "ChangeRevoked(uint256,bytes32)" "$timeout" "$watch_topic")"
    wait_until_base_time "$((executable_at + 30))"
    l1="$(block_number "$LASNA_RPC")"
    asked="$(lasna_logs "$lasna_from" "$l1" "$(cast keccak 'ExitRequested(uint256,uint256,uint8,bytes32)')" "$watch_topic")"
    n_asked="$(json_count "$asked")"
    shares_now="$(shares_of "$vault" "$DEP")"
    st_exit="$(cast call --rpc-url "$BASE_RPC" "$NP_EXIT" 'watches(uint256)(address,uint8,uint8,uint8,address,uint256)' "$watch_id" | sed -n 4p | awk '{print $1}')"
    rec hash1 "$hash1"; rec changeStoredTx "$stored"; rec revokeTx "$revoke_tx"; rec changeRevokedTx "$revoked"
    rec exitRequestedForWatch "$n_asked"; rec sharesAfterDeadline "$shares_now"; rec lasnaTo "$l1"
    summary "| 1. Curator schedules: $kind | Base Sepolia | \`$hash1\` |"
    summary "| ChangeStored | Lasna | \`$stored\` |"
    summary "| 2. Curator revokes the change | Base Sepolia | \`$revoke_tx\` |"
    summary "| ChangeRevoked | Lasna | \`$revoked\` |"
    summary ""
    summary "30 s past the time the change could have run ($executable_at): $n_asked ExitRequested for watch $watch_id on Lasna blocks $lasna_from to $l1; shares in the vault $shares_now of $exp_shares; status on Base $st_exit (1 = active)."
    [ "$n_asked" = 0 ] || die "an exit was asked for after the change was revoked"
    [ "$shares_now" = "$exp_shares" ] || die "the deposit moved although the change was revoked"
    [ "$st_exit" = 1 ] || die "the watch is not active any more (status $st_exit)"
    cancel_tx="$(send_as "$DEP_KEY" "$BASE_RPC" "3. depositor turns the watch off" "$NP_EXIT" "cancel(uint256)" "$watch_id")"
    closed="$(wait_log "$LASNA_RPC" "watch closed on Lasna" "$lasna_from" "$NP_REACTIVE" "WatchClosed(uint256,uint8)" "$timeout" "$watch_topic")"
    closed_status="$(lasna_status "$watch_id")"
    rec cancelTx "$cancel_tx"; rec watchClosedTx "$closed"; rec lasnaStatus "$closed_status"
    [ "$closed_status" = 3 ] || die "watch $watch_id has status $closed_status on Lasna after the cancel, expected 3 (cancelled)"
    summary "| 3. Depositor turns the watch off | Base Sepolia | \`$cancel_tx\` |"
    summary "| WatchClosed | Lasna | \`$closed\` |"
    ;;

  arm-only)
    summary "| Arm (WatchArmed) | Base Sepolia | \`$arm_tx\` |"
    summary ""
    summary "Watch $watch_id on vault $vault is on and left on. Base Sepolia block $(tx_block "$BASE_RPC" "$arm_tx"), Lasna from block $lasna_from. Fire it later with LOOP_ACTION=fire LOOP_VAULT=$vault LOOP_WATCH=$watch_id."
    ;;

  fire)
    need_env LOOP_VAULT LOOP_WATCH
    vault="$LOOP_VAULT"; watch_id="$LOOP_WATCH"
    [[ "$watch_id" =~ ^[0-9]+$ ]] || die "LOOP_WATCH must be a watch id"
    watch_topic="$(cast to-uint256 "$watch_id")"
    mapfile -t w < <(cast call --rpc-url "$BASE_RPC" "$NP_EXIT" 'watches(uint256)(address,uint8,uint8,uint8,address,uint256)' "$watch_id" | awk '{print $1}')
    [ "${#w[@]}" = 6 ] || die "watch $watch_id unknown"
    owner="${w[0]}"; w_kinds="${w[1]}"; mode="${w[2]}"; [ "${w[3]}" = 1 ] || die "watch $watch_id is not active (status ${w[3]})"
    same_address "${w[4]}" "$vault" || die "watch $watch_id is on ${w[4]}, not on $vault"
    [ $(( $(kind_bit "$kind") & w_kinds )) != 0 ] || die "watch $watch_id (kinds $w_kinds) does not cover $kind"
    v_cur="$(cast call --rpc-url "$BASE_RPC" "$vault" 'curator()(address)')" || die "curator of $vault unknown"
    if same_address "$v_cur" "$ADDR_A"; then CUR_KEY="$KEY_A"; CUR="$ADDR_A"
    elif [ -n "${ADDR_B:-}" ] && same_address "$v_cur" "$ADDR_B"; then CUR_KEY="$KEY_B"; CUR="$ADDR_B"
    else die "the curator of $vault ($v_cur) is not one of our keys (set LOOP_CURATOR=b for a key B vault)"; fi
    armed_at="$(uint_of "$BASE_RPC" "$NP_EXIT" 'armedAt(uint256)(uint256)' "$watch_id")"
    exp_shares="$(uint_of "$BASE_RPC" "$NP_EXIT" 'redeemableShares(uint256)(uint256)' "$watch_id")"
    tokens_before="$(tokens_of "$owner")"
    rec vault "$vault"; rec watchId "$watch_id"; rec owner "$owner"; rec armedAt "$armed_at"
    [ "$mode" = 0 ] || timeout=$((timeout + 180))
    schedule "$vault" "$kind" "1. curator schedules: $kind on the held watch's vault (Base Sepolia)"
    exit_and_check "$owner" "$vault" "$(last_submit)"
    held=$(( $(tx_block_time "$BASE_RPC" "$(last_submit)") - armed_at ))
    rec heldSeconds "$held"
    summary "Watch $watch_id was on for $held s before the change was scheduled."
    ;;

  burst)
    need_env LOOP_VAULT
    [ "$factory_kind" = maker ] || die "burst needs Vault V2's multicall (maker vaults); the demo vault has none"
    vault="$LOOP_VAULT"
    stray0="$(reactive_counter strayEvents)"
    float0="$(cast balance --rpc-url "$LASNA_RPC" "$NP_REACTIVE")" || die "float unknown"
    l0="$(block_number "$LASNA_RPC")"
    calls=()
    for n in 1 2 3; do
      submits=$((submits + 1))
      d="$(kind_calldata adapter "$vault" "$submits")"
      calls+=("$(cast calldata 'submit(bytes)' "$d")")
      rec burstData "$d"
    done
    [ "${calls[0]}" != "${calls[1]}" ] && [ "${calls[1]}" != "${calls[2]}" ] && [ "${calls[0]}" != "${calls[2]}" ] \
      || die "the three scheduled changes are not distinct"
    arr="[$(IFS=,; echo "${calls[*]}")]"
    burst_tx="$(send_as "$CUR_KEY" "$BASE_RPC" "three watched changes in one multicall" "$vault" "multicall(bytes[])" "$arr")"
    sleep "${LOOP_BURST_WAIT:-60}"
    l1="$(block_number "$LASNA_RPC")"
    all="$(lasna_logs "$l0" "$l1")"
    strays="$(lasna_logs "$l0" "$l1" "$(cast keccak 'StrayEvent(uint256,address,uint256,uint256)')")"
    stray1="$(reactive_counter strayEvents)"
    float1="$(cast balance --rpc-url "$LASNA_RPC" "$NP_REACTIVE")" || die "float unknown"
    n_tx="$(python3 -c 'import json, sys; print(len(json.loads(sys.argv[1])["txs"]))' "$all")"
    rec vault "$vault"; rec burstTx "$burst_tx"; rec lasnaFrom "$l0"; rec lasnaTo "$l1"; rec reactiveTxs "$n_tx"
    rec strayLogs "$(json_count "$strays")"; rec strayBefore "$stray0"; rec strayAfter "$stray1"
    rec floatBefore "$float0"; rec floatAfter "$float1"
    summary "| Three watched changes in one multicall | Base Sepolia | \`$burst_tx\` |"
    summary ""
    summary "Lasna blocks $l0 to $l1: $n_tx transactions of NoticeReactive, $(json_count "$strays") StrayEvent logs; strayEvents $stray0 -> $stray1; float $float0 -> $float1 wei. Recorded, not required."
    ;;

  cancel)
    need_env LOOP_WATCH
    watch_id="$LOOP_WATCH"; watch_topic="$(cast to-uint256 "$watch_id")"
    owner="$(cast call --rpc-url "$BASE_RPC" "$NP_EXIT" 'watches(uint256)(address,uint8,uint8,uint8,address,uint256)' "$watch_id" | sed -n 1p)"
    if same_address "$owner" "$DEP"; then :; else die "watch $watch_id belongs to $owner, not to the depositor key $DEP"; fi
    cancel_tx="$(send_as "$DEP_KEY" "$BASE_RPC" "depositor turns the watch off" "$NP_EXIT" "cancel(uint256)" "$watch_id")"
    closed="$(wait_log "$LASNA_RPC" "watch closed on Lasna" "$lasna_from" "$NP_REACTIVE" "WatchClosed(uint256,uint8)" "$timeout" "$watch_topic")"
    closed_status="$(lasna_status "$watch_id")"
    rec watchId "$watch_id"; rec cancelTx "$cancel_tx"; rec watchClosedTx "$closed"; rec lasnaStatus "$closed_status"
    [ "$closed_status" = 3 ] || die "watch $watch_id has status $closed_status on Lasna after the cancel, expected 3 (cancelled)"
    summary "| Depositor turns watch $watch_id off | Base Sepolia | \`$cancel_tx\` |"
    summary "| WatchClosed | Lasna | \`$closed\` |"
    ;;

  expire-stale)
    # Only timer watches (mode 1) past their lease; a "leave now" watch is never expired here.
    lifetime="$(uint_of "$BASE_RPC" "$NP_EXIT" 'LIFETIME()(uint256)')"
    next_id="$(uint_of "$BASE_RPC" "$NP_EXIT" 'nextWatchId()(uint256)')"
    now="$(block_time "$BASE_RPC")"
    first=$(( next_id > ${LOOP_SCAN:-200} ? next_id - ${LOOP_SCAN:-200} : 1 ))
    expired=0; looked=0
    for ((id = first; id < next_id; id++)); do
      mapfile -t w < <(cast call --rpc-url "$BASE_RPC" "$NP_EXIT" 'watches(uint256)(address,uint8,uint8,uint8,address,uint256)' "$id" | awk '{print $1}')
      [ "${#w[@]}" = 6 ] || die "watch $id unknown"
      looked=$((looked + 1))
      [ "${w[3]}" = 1 ] && [ "${w[2]}" = 1 ] || continue
      at="$(uint_of "$BASE_RPC" "$NP_EXIT" 'armedAt(uint256)(uint256)' "$id")"
      [ $((at + lifetime)) -le "$now" ] || continue
      tx="$(send_as "$DEP_KEY" "$BASE_RPC" "expire timer watch $id (armed $at, lease $lifetime s)" "$NP_EXIT" "expire(uint256)" "$id")"
      rec expiredWatch "$id"; rec expireTx "$tx"
      summary "| Expire timer watch $id (past its lease) | Base Sepolia | \`$tx\` |"
      expired=$((expired + 1))
    done
    rec looked "$looked"; rec expired "$expired"
    summary ""
    summary "Looked at watches $first to $((next_id - 1)): $expired timer watches past their lease expired. Leave-now watches are never expired."
    ;;

  topup)
    [ "$depositor" = a ] || die "topup sends from key A only (LOOP_DEPOSITOR=a)"
    need_env LOOP_TOPUP
    value="$(to_wei "$LOOP_TOPUP")"
    check_balance "$LASNA_RPC" "Lasna" "$(add_wei "$value" "$(to_wei 0.05)")"
    float0="$(cast balance --rpc-url "$LASNA_RPC" "$NP_REACTIVE")" || die "float unknown"
    t1="$(send_as "$KEY_A" "$LASNA_RPC" "top up NoticeReactive" "$NP_REACTIVE" --value "$value")"
    t2="$(send_as "$KEY_A" "$LASNA_RPC" "NoticeReactive.coverDebt" "$NP_REACTIVE" 'coverDebt()')"
    float1="$(cast balance --rpc-url "$LASNA_RPC" "$NP_REACTIVE")" || die "float unknown"
    debt="$(debt_of "$LASNA_RPC" "$NP_REACTIVE")"
    rec topupTx "$t1"; rec coverDebtTx "$t2"; rec floatBefore "$float0"; rec floatAfter "$float1"; rec debtAfter "$debt"
    summary "| Top up NoticeReactive ($LOOP_TOPUP lREACT) | Lasna | \`$t1\` |"
    summary "| coverDebt | Lasna | \`$t2\` |"
    summary ""
    summary "Float $float0 -> $float1 wei; debt to the system contract after coverDebt: $debt wei."
    [ "$debt" = 0 ] || die "NoticeReactive still owes $debt wei after coverDebt"
    ;;
esac
