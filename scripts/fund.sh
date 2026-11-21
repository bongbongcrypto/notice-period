#!/usr/bin/env bash
# Converts faucet-funded Sepolia ETH into lREACT and Base Sepolia ETH for the same testnet account.
# Run only in Actions; DEPLOY_KEY is the environment secret TESTNET_KEY, never printed or written.
# Environment: REACT_ETH, BASE_ETH, SEPOLIA_NONCE, TESTNET_ADDRESS, DEPLOY_KEY;
#   SEPOLIA_RPC, BASE_RPC, LASNA_RPC may override the public endpoints (CI points them at local chains).
#   The contract addresses below are fixed and cannot be overridden.
# FUND_POLL_TIMEOUT (1-900 s, default 900) and FUND_RECEIPT_TIMEOUT (1-180 s, default 180) may shorten waits for CI,
# never lengthen them. Credit polls are 15 s apart.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/chain.sh
source scripts/chain.sh

export SEPOLIA_RPC="${SEPOLIA_RPC-https://ethereum-sepolia-rpc.publicnode.com}"
export BASE_RPC="${BASE_RPC-https://sepolia.base.org}"
export LASNA_RPC="${LASNA_RPC-https://lasna-rpc.rnk.dev/}"
# Reactive faucet on Sepolia. request(receiver) keeps all of the ETH (no refund path) and only emits
# PaymentRequest(receiver, min(value, max_payout)). Its Lasna payer then pays value * exchangeRate / 10000 lREACT, or
# nothing at all when paused, in debt, short of funds, or above its own max_payout (500 lREACT, i.e. 5 ETH: above
# that the whole request is lost, not just the excess). Sources: Reactive-Network/testnet-faucet 6b69f5be, live reads.
FAUCET_ADDRESS=0x9b9BB25f1A81078C544C829c5EB7822d747Cf434
LASNA_PAYER=0x5cBC52A390E69D9193996AeBFB53F7b97DB6cf51
LASNA_SYSTEM=0x8888888888888888888888888888888888888888
# Base's L1StandardBridge on Sepolia: depositETH credits the same address on Base Sepolia.
BRIDGE_ADDRESS=0xfd0Bf71F60660E2f608ed56e1659C450eB113120
SEPOLIA_CHAIN_ID=11155111
# Highest legacy gas price this job sends at (wei). Sends use twice the read price for headroom, so the read price
# must be at most 1 gwei. Below a 1 gwei base fee the bridge's L2 gas burn is at its maximum, so the estimate holds.
MAX_SEND_GAS_PRICE=2000000000
MIN_RESERVE=10000000000000000 # 0.01 ETH kept for gas
need_env REACT_ETH BASE_ETH SEPOLIA_NONCE TESTNET_ADDRESS DEPLOY_KEY SEPOLIA_RPC BASE_RPC LASNA_RPC

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
[[ "$SEPOLIA_NONCE" =~ ^(0|[1-9][0-9]{0,8})$ ]] \
  || die "sepolia_nonce must be a plain whole number: the account's current Sepolia nonce"
poll_timeout="${FUND_POLL_TIMEOUT-900}"
[[ "$poll_timeout" =~ ^[1-9][0-9]{0,2}$ ]] && [ "$poll_timeout" -le 900 ] \
  || die "FUND_POLL_TIMEOUT must be an integer from 1 to 900 seconds"
receipt_timeout="${FUND_RECEIPT_TIMEOUT-180}"
[[ "$receipt_timeout" =~ ^[1-9][0-9]{0,2}$ ]] && [ "$receipt_timeout" -le 180 ] \
  || die "FUND_RECEIPT_TIMEOUT must be an integer from 1 to 180 seconds"
[[ "$TESTNET_ADDRESS" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "TESTNET_ADDRESS is not a 0x-prefixed 20-byte address"
# Suppress tool errors too: an invalid private key must never be echoed by a tool's diagnostics.
DEPLOYER="$(cast wallet address --private-key "$DEPLOY_KEY" 2>/dev/null)" || die "could not derive the testnet address"
same_address "$DEPLOYER" "$TESTNET_ADDRESS" || die "key address differs from TESTNET_ADDRESS"
echo "deployer: $DEPLOYER"
check_chain "$SEPOLIA_RPC" "$SEPOLIA_CHAIN_ID" "Sepolia"
check_chain "$BASE_RPC" "$BASE_CHAIN_ID" "Base Sepolia"
check_chain "$LASNA_RPC" "$LASNA_CHAIN_ID" "Lasna"
for a in "$FAUCET_ADDRESS" "$BRIDGE_ADDRESS"; do
  code="$(cast code --rpc-url "$SEPOLIA_RPC" "$a" 2>/dev/null)" || die "Sepolia code unknown at $a"
  [[ "$code" =~ ^0x([0-9a-fA-F]{2})+$ ]] || die "no contract code at $a (or code unknown)"
done

read_balance() { # rpc [timeout_s] [address]: never treat a failed, empty or malformed read as zero
  local bal
  bal="$(timeout "${2:-10}s" cast balance --rpc-url "$1" "${3:-$DEPLOYER}" 2>/dev/null)" || return 1
  [[ "$bal" =~ ^[0-9]+$ ]] || return 1
  echo "$bal"
}

read_word() { # label rpc to sig [args...] -> the 32-byte answer as a decimal integer; stops on any failed read
  local label="$1" rpc="$2" to="$3" out
  shift 3
  out="$(timeout 20s cast call --rpc-url "$rpc" "$to" "$@" 2>/dev/null)" || die "$label unknown (RPC error); nothing sent"
  [[ "$out" =~ ^0x[0-9a-fA-F]{64}$ ]] || die "$label unknown (no contract or malformed answer); nothing sent"
  python3 -c 'import sys; print(int(sys.argv[1], 16))' "$out"
}

wei_ge() { # a b: true when a >= b (arbitrary size)
  python3 -c 'import sys; sys.exit(not (int(sys.argv[1]) >= int(sys.argv[2])))' "$1" "$2"
}

sepolia_before="$(read_balance "$SEPOLIA_RPC")" || die "Sepolia balance unknown"
base_before="$(read_balance "$BASE_RPC")" || die "Base Sepolia balance unknown"
lasna_before="$(read_balance "$LASNA_RPC")" || die "Lasna balance unknown"
echo "Before (wei): Sepolia ETH $sepolia_before; Base Sepolia ETH $base_before; Lasna lREACT $lasna_before"

gas_price="$(cast gas-price --rpc-url "$SEPOLIA_RPC" 2>/dev/null)" || die "Sepolia gas price unknown"
[[ "$gas_price" =~ ^[0-9]+$ ]] && [ "$gas_price" != 0 ] || die "invalid Sepolia gas price"
send_price="$(python3 -c 'import sys; print(2 * int(sys.argv[1]))' "$gas_price")"
wei_ge "$MAX_SEND_GAS_PRICE" "$send_price" \
  || die "Sepolia gas price too high: $gas_price wei read, the job sends at twice that and pays at most $MAX_SEND_GAS_PRICE wei; try later"

# The values plus the reserve floor, before estimating: a leg above the balance makes the estimate fail with a
# misleading reason.
check_balance "$SEPOLIA_RPC" "Sepolia" "$(add_wei "$(add_wei "$react_wei" "$base_wei")" "$MIN_RESERVE")"

# The faucet keeps the ETH whatever happens on Lasna, so read the payout state that decides whether lREACT is paid.
react_expect=0
if [ "$react_wei" != 0 ]; then
  l1_max="$(read_word "Sepolia faucet max_payout" "$SEPOLIA_RPC" "$FAUCET_ADDRESS" 'max_payout()')"
  p_l1="$(read_word "Lasna payer l1" "$LASNA_RPC" "$LASNA_PAYER" 'l1()')"
  p_chain="$(read_word "Lasna payer chainId" "$LASNA_RPC" "$LASNA_PAYER" 'chainId()')"
  p_paused="$(read_word "Lasna payer paused" "$LASNA_RPC" "$LASNA_PAYER" 'paused()')"
  p_rate="$(read_word "Lasna payer exchangeRate" "$LASNA_RPC" "$LASNA_PAYER" 'exchangeRate()')"
  p_max="$(read_word "Lasna payer max_payout" "$LASNA_RPC" "$LASNA_PAYER" 'max_payout()')"
  p_reserve="$(read_word "Lasna payer gasReserve" "$LASNA_RPC" "$LASNA_PAYER" 'gasReserve()')"
  p_debt="$(read_word "Lasna payer system debt" "$LASNA_RPC" "$LASNA_SYSTEM" 'debt(address)' "$LASNA_PAYER")"
  p_balance="$(read_balance "$LASNA_RPC" 10 "$LASNA_PAYER")" || die "Lasna payer balance unknown; nothing sent"
  react_expect="$(python3 - "$react_wei" "$l1_max" "$p_l1" "$FAUCET_ADDRESS" "$p_chain" "$SEPOLIA_CHAIN_ID" \
    "$p_paused" "$p_rate" "$p_max" "$p_reserve" "$p_debt" "$p_balance" <<'PY'
import sys
a = sys.argv[1:]
react, l1_max, p_l1 = int(a[0]), int(a[1]), int(a[2])
faucet, p_chain, chain = int(a[3], 16), int(a[4]), int(a[5])
paused, rate, p_max, reserve, debt, bal = map(int, a[6:])
if react > l1_max:
    sys.exit(f"STOP: Sepolia faucet max_payout is {l1_max} wei, below react_eth; the faucet would keep the rest")
if p_l1 != faucet or p_chain != chain:
    sys.exit("STOP: Lasna payer is not wired to the Sepolia faucet")
if paused != 0:
    sys.exit("STOP: Lasna payer is paused; a request now would pay nothing")
if rate != 1_000_000:
    sys.exit(f"STOP: Lasna payer exchange rate is {rate}, expected 1000000 (100 lREACT per ETH)")
expect = react * rate // 10_000
if expect > p_max:
    sys.exit(f"STOP: Lasna payer max_payout is {p_max} wei, below the {expect} wei this request pays")
if expect + reserve > bal:
    sys.exit(f"STOP: Lasna payer balance {bal} wei cannot cover {expect} wei plus its {reserve} wei reserve")
if debt != 0:
    sys.exit(f"STOP: Lasna payer has system debt ({debt} wei); payouts are stopped")
print(expect)
PY
)" || exit 1
  echo "Lasna payer ready: pays $react_expect wei lREACT for $react_wei wei"
fi

estimate() { # value to sig [args...]
  local value="$1" gas
  shift
  gas="$(cast estimate --rpc-url "$SEPOLIA_RPC" --from "$DEPLOYER" --legacy --gas-price "$gas_price" \
    --value "$value" "$@" 2>/dev/null)" || die "funding gas estimate failed; nothing sent"
  [[ "$gas" =~ ^[1-9][0-9]*$ ]] || die "funding gas estimate unknown"
  echo "$gas"
}
gas_limit() { # estimate -> 20% headroom, rounded up
  python3 -c 'import sys; print((int(sys.argv[1]) * 120 + 99) // 100)' "$1"
}
react_limit=0
base_limit=0
if [ "$react_wei" != 0 ]; then
  react_limit="$(gas_limit "$(estimate "$react_wei" "$FAUCET_ADDRESS" 'request(address)' "$DEPLOYER")")"
fi
if [ "$base_wei" != 0 ]; then
  base_limit="$(gas_limit "$(estimate "$base_wei" "$BRIDGE_ADDRESS" 'depositETH(uint32,bytes)' 200000 0x)")"
fi
# Most gas both sends can cost at the send price; under the price ceiling this stays below the 0.01 ETH floor.
reserve="$(python3 -c 'import sys; r,b,p,m=map(int,sys.argv[1:]); print(max(m, (r+b)*p))' \
  "$react_limit" "$base_limit" "$send_price" "$MIN_RESERVE")"
check_balance "$SEPOLIA_RPC" "Sepolia" "$(add_wei "$(add_wei "$react_wei" "$base_wei")" "$reserve")"
echo "Gas reserve: $reserve wei; gas limits: faucet $react_limit, bridge $base_limit; gas price read $gas_price wei, sent at $send_price wei"

# Duplicate guard. Only this job sends from the account on Sepolia, so its nonce counts earlier funding transactions.
# A second dispatch or a re-run with the same sepolia_nonce is refused once anything was sent.
nonce_latest="$(timeout 20s cast nonce --rpc-url "$SEPOLIA_RPC" "$DEPLOYER" 2>/dev/null)" || die "Sepolia nonce unknown"
nonce_pending="$(timeout 20s cast nonce --block pending --rpc-url "$SEPOLIA_RPC" "$DEPLOYER" 2>/dev/null)" \
  || die "Sepolia pending nonce unknown"
[[ "$nonce_latest" =~ ^[0-9]+$ ]] && [[ "$nonce_pending" =~ ^[0-9]+$ ]] || die "Sepolia nonce unknown (malformed answer)"
[ "$nonce_latest" = "$nonce_pending" ] || die "a Sepolia transaction from this account is still pending (nonce $nonce_latest, pending $nonce_pending); wait for it and check the account before any new run"
[ "$nonce_latest" = "$SEPOLIA_NONCE" ] || die "Sepolia nonce is $nonce_latest, but sepolia_nonce is $SEPOLIA_NONCE: an earlier run already sent. Check the account; enter the current nonce only for a deliberate new run"
next_nonce="$nonce_latest"

react_tx=""
base_tx=""
react_status=unsent
base_status=unsent
react_seen="not checked"
base_seen="not checked"
if [ "$react_wei" = 0 ]; then react_status=skipped; react_seen=skipped; fi
if [ "$base_wei" = 0 ]; then base_status=skipped; base_seen=skipped; fi
credit_warning=""
credit_error=""

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
  local rc=$? sepolia_after base_after lasna_after nonce_after
  trap - EXIT
  # Preserve a failure and the submitted hashes even when final balance reads fail.
  sepolia_after="$(read_balance "$SEPOLIA_RPC")" || sepolia_after=unknown
  base_after="$(read_balance "$BASE_RPC")" || base_after=unknown
  lasna_after="$(read_balance "$LASNA_RPC")" || lasna_after=unknown
  nonce_after="$(timeout 10s cast nonce --block pending --rpc-url "$SEPOLIA_RPC" "$DEPLOYER" 2>/dev/null)" \
    || nonce_after=unknown
  summary "### Testnet funding (exit status $rc)"
  summary ""
  summary "Account: \`$DEPLOYER\`. Sepolia gas reserve: $reserve wei. Gas price sent: $send_price wei."
  summary "Faucet: $react_status. Bridge: $base_status."
  summary "Lasna credit observed: $react_seen (at least $react_expect wei expected)."
  summary "Base Sepolia credit observed: $base_seen (at least $base_wei wei expected)."
  summary ""
  summary "| Balance (whole coins) | Before | After | Change |"
  summary "|---|---|---|---|"
  summary "$(balance_row 'Sepolia ETH' https://sepolia.etherscan.io "$sepolia_before" "$sepolia_after")"
  summary "$(balance_row 'Base Sepolia ETH' https://base-sepolia.blockscout.com "$base_before" "$base_after")"
  summary "$(balance_row 'Lasna lREACT' https://lasna.reactscan.net "$lasna_before" "$lasna_after")"
  summary ""
  summary "sepolia_nonce for a deliberate next run: $nonce_after (check this run's results first; a re-run with the old value is refused)."
  [ -z "$credit_warning" ] || summary "WARNING: $credit_warning"
  if [ "$sepolia_after" = unknown ] || [ "$base_after" = unknown ] || [ "$lasna_after" = unknown ]; then
    summary "WARNING: final balance read failed; unknown is not zero. Check the explorers before retrying."
  fi
  if [ -n "$credit_error" ]; then
    summary "STOP: $credit_error"
  elif [ "$rc" != 0 ]; then
    summary "STOP: funding did not complete. Check submitted transactions before any new run; a completed leg is not undone."
  fi
  exit "$rc"
}
trap finish EXIT

fund_send() { # leg to value gas_limit sig [args...]; stores the hash before waiting for the receipt
  local leg="$1" to="$2" value="$3" limit="$4" tx receipt status
  shift 4
  printf -v "${leg}_status" '%s' 'submission unknown'
  # Nonce and gas are fixed here, so cast reads nothing from a possibly lagging RPC backend before signing.
  tx="$(cast send --async --rpc-url "$SEPOLIA_RPC" --private-key "$DEPLOY_KEY" --legacy --nonce "$next_nonce" \
    --gas-price "$send_price" --gas-limit "$limit" --value "$value" "$to" "$@" 2>/dev/null)" \
    || die "$leg: submission failed or unknown; do not retry without checking the account"
  [[ "$tx" =~ ^0x[0-9a-fA-F]{64}$ ]] || die "$leg: submission returned no valid transaction hash"
  next_nonce=$((next_nonce + 1))
  printf -v "${leg}_tx" '%s' "$tx"
  printf -v "${leg}_status" '%s' 'receipt unknown'
  # Persist the hash immediately, including if the receipt fails or the job is interrupted later.
  summary "$leg transaction: [$tx](https://sepolia.etherscan.io/tx/$tx)"
  receipt="$(timeout "${receipt_timeout}s" cast receipt --json --rpc-url "$SEPOLIA_RPC" --confirmations 1 "$tx" 2>/dev/null)" \
    || die "$leg: receipt unknown for $tx; next leg remains unsent"
  status="$(json_field "$receipt" status)"
  case "$status" in
    1 | 0x1) printf -v "${leg}_status" '%s' 'receipt status 1' ;;
    *) printf -v "${leg}_status" '%s' "receipt status ${status:-unknown}"; die "$leg: receipt status is not 1; next leg remains unsent" ;;
  esac
}

if [ "$react_wei" != 0 ]; then
  fund_send react "$FAUCET_ADDRESS" "$react_wei" "$react_limit" 'request(address)' "$DEPLOYER"
fi
if [ "$base_wei" != 0 ]; then
  fund_send base "$BRIDGE_ADDRESS" "$base_wei" "$base_limit" 'depositETH(uint32,bytes)' 200000 0x
fi

# Both destinations share one window. A credit counts only when the balance rose by at least the expected amount.
# Never resend a leg because a credit is delayed.
lasna_target="$(add_wei "$lasna_before" "$react_expect")"
base_target="$(add_wei "$base_before" "$base_wei")"
[ "$react_seen" = skipped ] || react_seen=no
[ "$base_seen" = skipped ] || base_seen=no
echo "Waiting up to $poll_timeout s for credits"
deadline=$((SECONDS + poll_timeout))
# Read every 15 s, and once more when the window ends: with a window of 16 s, a loop that stopped at the deadline
# read only at the start and missed a credit that came a second later. Each read may add up to 10 s.
while :; do
  last=0
  [ "$SECONDS" -lt "$deadline" ] || last=1
  if [ "$react_seen" = no ]; then
    if now="$(read_balance "$LASNA_RPC" 10)"; then
      if wei_ge "$now" "$lasna_target"; then react_seen=yes; fi
    else
      echo "Lasna credit: balance unknown, retrying"
    fi
  fi
  if [ "$base_seen" = no ]; then
    if now="$(read_balance "$BASE_RPC" 10)"; then
      if wei_ge "$now" "$base_target"; then base_seen=yes; fi
    else
      echo "Base Sepolia credit: balance unknown, retrying"
    fi
  fi
  if [ "$react_seen" != no ] && [ "$base_seen" != no ]; then break; fi
  [ "$last" = 0 ] || break
  remaining=$((deadline - SECONDS))
  [ "$remaining" -le 0 ] || sleep "$((remaining < 15 ? remaining : 15))"
done
if [ "$base_seen" = no ]; then
  credit_warning="Base Sepolia credit not observed within $poll_timeout s. Bridge deposits can take longer; check the explorer and do not resend."
fi
if [ "$react_seen" = no ]; then
  credit_error="Lasna credit not observed in full within $poll_timeout s ($react_expect wei expected). Payouts normally land within seconds and the Sepolia ETH stays in the faucet: do not resend. Check the Lasna payer $LASNA_PAYER on https://lasna.reactscan.net."
  die "$credit_error"
fi
