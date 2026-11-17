#!/usr/bin/env bash
# Converts faucet-funded Sepolia ETH into lREACT and Base Sepolia ETH for the same testnet account.
# Run only in Actions; DEPLOY_KEY is the environment secret TESTNET_KEY, never printed or written.
# Environment: REACT_ETH, BASE_ETH, TESTNET_ADDRESS, DEPLOY_KEY;
#   SEPOLIA_RPC, BASE_RPC, LASNA_RPC, FAUCET_ADDRESS, BRIDGE_ADDRESS may override the testnet defaults.
# FUND_POLL_TIMEOUT may shorten the 900 s credit wait for CI, never lengthen it. Polls are 15 s apart.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/chain.sh
source scripts/chain.sh

export SEPOLIA_RPC="${SEPOLIA_RPC-https://ethereum-sepolia-rpc.publicnode.com}"
export BASE_RPC="${BASE_RPC-https://sepolia.base.org}"
export LASNA_RPC="${LASNA_RPC-https://lasna-rpc.rnk.dev/}"
FAUCET_ADDRESS="${FAUCET_ADDRESS-0x9b9BB25f1A81078C544C829c5EB7822d747Cf434}"
BRIDGE_ADDRESS="${BRIDGE_ADDRESS-0xfd0Bf71F60660E2f608ed56e1659C450eB113120}"
need_env REACT_ETH BASE_ETH TESTNET_ADDRESS DEPLOY_KEY SEPOLIA_RPC BASE_RPC LASNA_RPC FAUCET_ADDRESS BRIDGE_ADDRESS

# Validate before any RPC or send. Use integer wei throughout, including the cap comparisons.
react_wei="$(to_wei "$REACT_ETH")"
base_wei="$(to_wei "$BASE_ETH")"
python3 - "$react_wei" "$base_wei" <<'PY' || exit 1
import sys
react, base = map(int, sys.argv[1:])
if react > 2 * 10**18:
    sys.exit("STOP: react_eth exceeds the 2 ETH per-run cap")
if base > 2 * 10**17:
    sys.exit("STOP: base_eth exceeds the 0.2 ETH per-run cap")
if react == base == 0:
    sys.exit("STOP: both funding legs are zero")
PY
poll_timeout="${FUND_POLL_TIMEOUT-900}"
[[ "$poll_timeout" =~ ^(0|[1-9][0-9]{0,2})$ ]] && [ "$poll_timeout" -le 900 ] \
  || die "FUND_POLL_TIMEOUT must be an integer from 0 to 900 seconds"
for a in "$TESTNET_ADDRESS" "$FAUCET_ADDRESS" "$BRIDGE_ADDRESS"; do
  [[ "$a" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "invalid account, faucet or bridge address"
done
# Suppress tool errors too: an invalid private key must never be echoed by a tool's diagnostics.
DEPLOYER="$(cast wallet address --private-key "$DEPLOY_KEY" 2>/dev/null)" || die "could not derive the testnet address"
same_address "$DEPLOYER" "$TESTNET_ADDRESS" || die "key address differs from TESTNET_ADDRESS"
echo "deployer: $DEPLOYER"
check_chain "$SEPOLIA_RPC" 11155111 "Sepolia"
check_chain "$BASE_RPC" "$BASE_CHAIN_ID" "Base Sepolia"
check_chain "$LASNA_RPC" "$LASNA_CHAIN_ID" "Lasna"
for a in "$FAUCET_ADDRESS" "$BRIDGE_ADDRESS"; do
  code="$(cast code --rpc-url "$SEPOLIA_RPC" "$a" 2>/dev/null)" || die "Sepolia code unknown at $a"
  [[ "$code" =~ ^0x([0-9a-fA-F]{2})+$ ]] || die "no contract code at $a (or code unknown)"
done

read_balance() { # rpc [timeout_s]: never treat a failed, empty or malformed read as zero
  local bal
  bal="$(timeout "${2:-10}s" cast balance --rpc-url "$1" "$DEPLOYER" 2>/dev/null)" || return 1
  [[ "$bal" =~ ^[0-9]+$ ]] || return 1
  echo "$bal"
}

sepolia_before="$(read_balance "$SEPOLIA_RPC")" || die "Sepolia balance unknown"
base_before="$(read_balance "$BASE_RPC")" || die "Base Sepolia balance unknown"
lasna_before="$(read_balance "$LASNA_RPC")" || die "Lasna balance unknown"
echo "Before (wei): Sepolia ETH $sepolia_before; Base Sepolia ETH $base_before; Lasna lREACT $lasna_before"

gas_price="$(cast gas-price --rpc-url "$SEPOLIA_RPC" 2>/dev/null)" || die "Sepolia gas price unknown"
[[ "$gas_price" =~ ^[0-9]+$ ]] && [ "$gas_price" != 0 ] || die "invalid Sepolia gas price"
estimate() { # value to sig [args...]
  local value="$1" gas
  shift
  gas="$(cast estimate --rpc-url "$SEPOLIA_RPC" --from "$DEPLOYER" --legacy --gas-price "$gas_price" \
    --value "$value" "$@" 2>/dev/null)" || die "funding gas estimate failed; nothing sent"
  [[ "$gas" =~ ^[1-9][0-9]*$ ]] || die "funding gas estimate unknown"
  echo "$gas"
}
react_gas=0
base_gas=0
if [ "$react_wei" != 0 ]; then
  react_gas="$(estimate "$react_wei" "$FAUCET_ADDRESS" 'request(address)' "$DEPLOYER")"
fi
if [ "$base_wei" != 0 ]; then
  base_gas="$(estimate "$base_wei" "$BRIDGE_ADDRESS" 'depositETH(uint32,bytes)' 200000 0x)"
fi
reserve="$(python3 -c 'import sys; r,b,p=map(int,sys.argv[1:]); print(max(10**16, 2*(r+b)*p))' \
  "$react_gas" "$base_gas" "$gas_price")"
check_balance "$SEPOLIA_RPC" "Sepolia" "$(add_wei "$(add_wei "$react_wei" "$base_wei")" "$reserve")"
echo "Gas reserve: $reserve wei; estimated gas: faucet $react_gas, bridge $base_gas; gas price $gas_price wei"

react_tx=""
base_tx=""
react_status=unsent
base_status=unsent
[ "$react_wei" != 0 ] || react_status=skipped
[ "$base_wei" != 0 ] || base_status=skipped
credit_warning=""

balance_row() { # label explorer before after (wei, or unknown)
  python3 - "$1" "$2" "$DEPLOYER" "$3" "$4" <<'PY'
import sys
label, explorer, address, before, after = sys.argv[1:]
def coins(n):
    n = int(n)
    sign = "-" if n < 0 else ""
    whole, part = divmod(abs(n), 10**18)
    return f"{sign}{whole}.{part:018d}"
change = "unknown" if after == "unknown" else coins(int(after) - int(before))
print(f"| [{label}]({explorer}/address/{address}) | {coins(before)} | "
      f"{after if after == 'unknown' else coins(after)} | {change} |")
PY
}

finish() {
  local rc=$? sepolia_after base_after lasna_after
  trap - EXIT
  # Preserve a failure and the submitted hashes even when final balance reads fail.
  sepolia_after="$(read_balance "$SEPOLIA_RPC")" || sepolia_after=unknown
  base_after="$(read_balance "$BASE_RPC")" || base_after=unknown
  lasna_after="$(read_balance "$LASNA_RPC")" || lasna_after=unknown
  summary "### Testnet funding (exit status $rc)"
  summary ""
  summary "Account: \`$DEPLOYER\`. Sepolia gas reserve: $reserve wei."
  summary "Faucet: $react_status. Bridge: $base_status."
  summary ""
  summary "| Balance (whole coins) | Before | After | Change |"
  summary "|---|---|---|---|"
  summary "$(balance_row 'Sepolia ETH' https://sepolia.etherscan.io "$sepolia_before" "$sepolia_after")"
  summary "$(balance_row 'Base Sepolia ETH' https://base-sepolia.blockscout.com "$base_before" "$base_after")"
  summary "$(balance_row 'Lasna lREACT' https://lasna.reactscan.net "$lasna_before" "$lasna_after")"
  [ -z "$credit_warning" ] || summary "WARNING: $credit_warning"
  if [ "$sepolia_after" = unknown ] || [ "$base_after" = unknown ] || [ "$lasna_after" = unknown ]; then
    summary "WARNING: final balance read failed; unknown is not zero. Check the explorers before retrying."
  fi
  [ "$rc" = 0 ] || summary "STOP: funding did not complete. Check submitted transactions before retrying; a completed leg is not undone."
  exit "$rc"
}
trap finish EXIT

fund_send() { # leg to value estimated_gas sig [args...]; stores the hash before waiting for the receipt
  local leg="$1" to="$2" value="$3" gas="$4" tx receipt status limit
  shift 4
  # 20% gas-limit headroom; the fixed legacy price bounds cost below the twice-estimated reserve.
  limit="$(python3 -c 'import sys; print((int(sys.argv[1])*120+99)//100)' "$gas")"
  printf -v "${leg}_status" '%s' 'submission unknown'
  tx="$(cast send --async --rpc-url "$SEPOLIA_RPC" --private-key "$DEPLOY_KEY" --legacy \
    --gas-price "$gas_price" --gas-limit "$limit" --value "$value" "$to" "$@" 2>/dev/null)" \
    || die "$leg: submission failed or unknown; do not retry without checking the account"
  [[ "$tx" =~ ^0x[0-9a-fA-F]{64}$ ]] || die "$leg: submission returned no valid transaction hash"
  printf -v "${leg}_tx" '%s' "$tx"
  printf -v "${leg}_status" '%s' 'receipt unknown'
  # Persist the hash immediately, including if the receipt fails or the job is interrupted later.
  summary "$leg transaction: [$tx](https://sepolia.etherscan.io/tx/$tx)"
  receipt="$(timeout 180s cast receipt --json --rpc-url "$SEPOLIA_RPC" --confirmations 1 "$tx" 2>/dev/null)" \
    || die "$leg: receipt unknown for $tx; next leg remains unsent"
  status="$(json_field "$receipt" status)"
  case "$status" in
    1 | 0x1) printf -v "${leg}_status" '%s' 'receipt status 1' ;;
    *) printf -v "${leg}_status" '%s' "receipt status ${status:-unknown}"; die "$leg: receipt status is not 1; next leg remains unsent" ;;
  esac
}

if [ "$react_wei" != 0 ]; then
  fund_send react "$FAUCET_ADDRESS" "$react_wei" "$react_gas" 'request(address)' "$DEPLOYER"
fi
if [ "$base_wei" != 0 ]; then
  fund_send base "$BRIDGE_ADDRESS" "$base_wei" "$base_gas" 'depositETH(uint32,bytes)' 200000 0x
fi

# Both enabled destinations share one 15-minute window. Never resend a leg because a credit is delayed.
react_seen=0
base_seen=0
[ "$react_wei" != 0 ] || react_seen=1
[ "$base_wei" != 0 ] || base_seen=1
deadline=$((SECONDS + poll_timeout))
while [ "$SECONDS" -lt "$deadline" ]; do
  if [ "$react_seen" = 0 ]; then
    remaining=$((deadline - SECONDS))
    [ "$remaining" -gt 0 ] || break
    if now="$(read_balance "$LASNA_RPC" "$((remaining < 10 ? remaining : 10))")"; then
      if python3 -c 'import sys; sys.exit(not (int(sys.argv[1]) > int(sys.argv[2])))' "$now" "$lasna_before"; then react_seen=1; fi
    else
      echo "Lasna credit: balance unknown, retrying"
    fi
  fi
  if [ "$base_seen" = 0 ] && [ "$SECONDS" -lt "$deadline" ]; then
    remaining=$((deadline - SECONDS))
    [ "$remaining" -gt 0 ] || break
    if now="$(read_balance "$BASE_RPC" "$((remaining < 10 ? remaining : 10))")"; then
      if python3 -c 'import sys; sys.exit(not (int(sys.argv[1]) > int(sys.argv[2])))' "$now" "$base_before"; then base_seen=1; fi
    else
      echo "Base Sepolia credit: balance unknown, retrying"
    fi
  fi
  if [ "$react_seen" = 1 ] && [ "$base_seen" = 1 ]; then break; fi
  [ "$SECONDS" -lt "$deadline" ] || break
  remaining=$((deadline - SECONDS))
  sleep "$((remaining < 15 ? remaining : 15))"
done
if [ "$react_seen" != 1 ] || [ "$base_seen" != 1 ]; then
  credit_warning="Credit not observed within $poll_timeout s (Lasna observed=$react_seen, Base Sepolia observed=$base_seen). Credit may arrive later; do not resend on this timeout."
fi
