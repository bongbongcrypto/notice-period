#!/usr/bin/env bash
# Health check of one deployment, with key B only (it never sends from key A, so it never moves key A's nonce and
# never tops anything up by itself). In order:
#   1. reads: the float of NoticeReactive (lREACT), both debts, the exit reserve (ETH in NoticeExit), strayEvents,
#      unknownEvents;
#   2. cancels key B's own leftover health watches: active watches owned by key B on vaults whose curator is key B
#      (long-held evidence watches have key A as curator, so they are never touched);
#   3. one "leave now" loop on a fresh vault, key B as depositor and curator (scripts/loop-system.sh);
#   4. expires timer watches past their lease (never a "leave now" watch).
# Fails (exit 1) when the float is under HEALTH_MIN_FLOAT lREACT, when either debt is above 0, when the loop does not
# return the deposit, or when a stale timer watch could not be expired. When a read already fails the thresholds, the
# loop is skipped: a contract in debt is refused every delivery, so the loop could only time out.
#
# Environment: BASE_RPC, LASNA_RPC, DEPLOY_KEY (only to derive key B), NP_TOKEN, NP_FACTORY, NP_EXIT, NP_REACTIVE,
#   LOOP_FACTORY_KIND, HEALTH_MIN_FLOAT (lREACT, decimals allowed).
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/chain.sh
source scripts/chain.sh

need_env BASE_RPC LASNA_RPC NP_TOKEN NP_FACTORY NP_EXIT NP_REACTIVE HEALTH_MIN_FLOAT
export LOOP_NO_KEY_A=1 LOOP_FUND_B=0 LOOP_DEPOSITOR=b LOOP_CURATOR=b
derive_key_b
min_float="$(to_wei "$HEALTH_MIN_FLOAT")"

problems=()
read_state() { # label
  float="$(cast balance --rpc-url "$LASNA_RPC" "$NP_REACTIVE" 2>/dev/null)" || die "float unknown"
  reserve="$(cast balance --rpc-url "$BASE_RPC" "$NP_EXIT" 2>/dev/null)" || die "exit reserve unknown"
  debt_r="$(debt_of "$LASNA_RPC" "$NP_REACTIVE")"
  debt_e="$(debt_of "$BASE_RPC" "$NP_EXIT")"
  stray="$(cast call --rpc-url "$LASNA_RPC" "$NP_REACTIVE" 'strayEvents()(uint256)' | awk '{print $1}')"
  unknown="$(cast call --rpc-url "$LASNA_RPC" "$NP_REACTIVE" 'unknownEvents()(uint256)' | awk '{print $1}')"
  summary "| $1 | $float | $debt_r | $reserve | $debt_e | $stray | $unknown |"
}
check_state() {
  python3 -c 'import sys; sys.exit(0 if int(sys.argv[1]) >= int(sys.argv[2]) else 1)' "$float" "$min_float" \
    || problems+=("float $float wei is under the threshold $min_float wei ($HEALTH_MIN_FLOAT lREACT)")
  [ "$debt_r" = 0 ] || problems+=("NoticeReactive owes the system contract $debt_r wei")
  [ "$debt_e" = 0 ] || problems+=("NoticeExit owes the callback proxy $debt_e wei")
}

summary "### Notice Period health (key B: $ADDR_B)"
summary ""
summary "| When | Float (wei, Lasna) | Reactive debt | Exit reserve (wei, Base) | Exit debt | strayEvents | unknownEvents |"
summary "|---|---|---|---|---|---|---|"
read_state "before"
check_state

if [ "${#problems[@]}" = 0 ]; then
  # Key B's own leftover health watches (vault curator = key B), oldest first.
  next_id="$(cast call --rpc-url "$BASE_RPC" "$NP_EXIT" 'nextWatchId()(uint256)' | awk '{print $1}')"
  first=$(( next_id > 200 ? next_id - 200 : 1 ))
  for ((id = first; id < next_id; id++)); do
    mapfile -t w < <(cast call --rpc-url "$BASE_RPC" "$NP_EXIT" 'watches(uint256)(address,uint8,uint8,uint8,address,uint256)' "$id" | awk '{print $1}')
    [ "${#w[@]}" = 6 ] || die "watch $id unknown"
    [ "${w[3]}" = 1 ] && same_address "${w[0]}" "$ADDR_B" || continue
    cur="$(cast call --rpc-url "$BASE_RPC" "${w[4]}" 'curator()(address)')" || die "curator of ${w[4]} unknown"
    same_address "$cur" "$ADDR_B" || continue
    LOOP_ACTION=cancel LOOP_WATCH="$id" LOOP_RUN_JSON="${RUNNER_TEMP:-.}/health-cancel-$id.json" \
      bash scripts/loop-system.sh || problems+=("could not turn off key B's leftover watch $id")
  done
  LOOP_ACTION=exit LOOP_MODE=0 LOOP_KIND=adapter LOOP_RUN_JSON="${RUNNER_TEMP:-.}/health-loop.json" \
    bash scripts/loop-system.sh || problems+=("the leave-now loop did not return the deposit")
else
  summary ""
  summary "Loop skipped: the readings above already fail (a contract in debt is refused every delivery)."
fi
LOOP_ACTION=expire-stale LOOP_RUN_JSON="${RUNNER_TEMP:-.}/health-expire.json" \
  bash scripts/loop-system.sh || problems+=("a timer watch past its lease could not be expired")

summary ""
summary "| When | Float (wei, Lasna) | Reactive debt | Exit reserve (wei, Base) | Exit debt | strayEvents | unknownEvents |"
summary "|---|---|---|---|---|---|---|"
read_state "after"
check_state
summary ""
if [ "${#problems[@]}" = 0 ]; then
  summary "Health: green (threshold $HEALTH_MIN_FLOAT lREACT)."
  exit 0
fi
for p in "${problems[@]}"; do summary "- $p"; done
summary "Health: RED. A top-up is a loop dispatch with action topup (key A)."
exit 1
