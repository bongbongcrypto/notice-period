# shellcheck shell=bash
# Helpers shared by the deploy and loop scripts. Sourced, never run directly.
#
# Inputs (environment):
#   BASE_RPC, LASNA_RPC   JSON-RPC endpoints of Base Sepolia and Reactive Lasna
#   DEPLOY_KEY            the testnet key (GitHub secret TESTNET_KEY); never printed, never written to a file
#   CALLBACK_PROXY        callback proxy on Base Sepolia
# Every failed or empty read is "unknown" and stops the script: nothing is sent on a guess.
set -euo pipefail

BASE_CHAIN_ID=84532
LASNA_CHAIN_ID=5318007
CRON10_TOPIC=0x04463f7c1651e6b9774d7f85c85bb94654e3c46ca79b0c16fb16d4183307b687

die() {
  echo "STOP: $*" >&2
  exit 1
}

need_env() {
  local v
  for v in "$@"; do
    [ -n "${!v:-}" ] || die "$v is not set"
  done
}

need_key() {
  [ -n "${DEPLOY_KEY:-}" ] || die "no key: the TESTNET_KEY secret of the testnet environment is empty"
  DEPLOYER="$(cast wallet address --private-key "$DEPLOY_KEY")" || die "could not derive the deployer address"
  echo "deployer: $DEPLOYER"
}

check_chain() { # rpc expected_id label
  local got
  got="$(cast chain-id --rpc-url "$1" 2>/dev/null)" || die "$3: chain id unknown (RPC error)"
  [ "$got" = "$2" ] || die "$3: chain id is $got, expected $2"
  echo "$3: chain $got"
}

# Stops when the balance is zero, unknown, or below the amount this run needs.
check_balance() { # rpc label need_wei
  local bal
  bal="$(cast balance --rpc-url "$1" "$DEPLOYER" 2>/dev/null)" || die "$2: balance unknown (RPC error)"
  [ -n "$bal" ] || die "$2: balance unknown (empty answer)"
  python3 - "$bal" "$3" "$2" <<'PY' || exit 1
import sys
bal, need, label = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
print(f"{label}: balance {bal} wei ({bal / 1e18:.6f}), this run needs at least {need} wei ({need / 1e18:.6f})")
if bal == 0:
    sys.exit(f"STOP: {label}: balance is zero")
if bal < need:
    sys.exit(f"STOP: {label}: balance below what this run needs")
PY
}

to_wei() { # decimal amount in whole coins (ETH or lREACT, 18 decimals), e.g. "0.002" -> wei
  [[ "$1" =~ ^[0-9]+(\.[0-9]{1,18})?$ ]] || die "amount '$1' is not a plain decimal number of coins"
  cast to-wei "$1" ether 2>/dev/null || die "cannot read amount $1"
}

add_wei() { # a b -> a + b (arbitrary size)
  python3 -c 'import sys; print(int(sys.argv[1]) + int(sys.argv[2]))' "$1" "$2"
}

# Next CREATE address of the deployer on a chain (pending nonce, so a queued transaction is counted).
next_address() { # rpc
  local n
  n="$(cast nonce --block pending --rpc-url "$1" "$DEPLOYER" 2>/dev/null)" || die "nonce unknown (RPC error)"
  cast compute-address --nonce "$n" "$DEPLOYER" | awk '{print $NF}'
}

same_address() {
  [ "$(echo "$1" | tr 'A-F' 'a-f')" = "$(echo "$2" | tr 'A-F' 'a-f')" ]
}

# Reads a field from the last JSON object in a tool's output (the object may span several lines and follow other
# text). Prints nothing if there is no such object or field.
json_field() { # text field
  python3 - "$1" "$2" <<'PY'
import json, sys
text, field = sys.argv[1], sys.argv[2]
dec = json.JSONDecoder()
found = None
for i, ch in enumerate(text):
    if ch != "{":
        continue
    try:
        obj, _ = dec.raw_decode(text[i:])
    except ValueError:
        continue
    if isinstance(obj, dict) and field in obj:
        found = obj
v = None if found is None else found.get(field)
print("" if v is None else v)
PY
}

# forge create with the testnet key. Prints "<address> <tx hash>". Extra args go to forge create.
deploy() { # rpc label contract value_wei [forge create args...]
  local rpc="$1" label="$2" contract="$3" value="$4" out addr tx
  shift 4
  out="$(forge create --broadcast --json --rpc-url "$rpc" --private-key "$DEPLOY_KEY" --value "$value" "$contract" "$@")" \
    || die "$label: deployment failed"
  addr="$(json_field "$out" deployedTo)"
  tx="$(json_field "$out" transactionHash)"
  [ -n "$addr" ] && [ -n "$tx" ] || die "$label: deployment answer has no address or hash"
  echo "$label: $addr (tx $tx)" >&2
  echo "$addr $tx"
}

# cast send with the testnet key. Prints the transaction hash; stops unless the receipt says success.
send() { # rpc label to sig [args...]
  local rpc="$1" label="$2" out status tx
  shift 2
  out="$(cast send --json --rpc-url "$rpc" --private-key "$DEPLOY_KEY" "$@")" || die "$label: transaction failed"
  status="$(json_field "$out" status)"
  tx="$(json_field "$out" transactionHash)"
  case "$status" in 1 | 0x1 | true | True) ;; *) die "$label: transaction $tx did not succeed (status $status)" ;; esac
  echo "$label: tx $tx" >&2
  echo "$tx"
}

block_number() { # rpc
  cast block-number --rpc-url "$1" 2>/dev/null || die "block number unknown (RPC error)"
}

tx_block_time() { # rpc txhash -> unix seconds of the block that holds it
  local r b bn ts
  r="$(cast receipt --json --rpc-url "$1" "$2" 2>/dev/null)" || die "receipt of $2 unknown"
  bn="$(json_field "$r" blockNumber)"
  [ -n "$bn" ] || die "receipt of $2 has no block number"
  bn="$(python3 -c 'import sys; print(int(sys.argv[1], 0))' "$bn")"
  b="$(cast block --json --rpc-url "$1" "$bn" 2>/dev/null)" || die "block $bn unknown"
  ts="$(json_field "$b" timestamp)"
  [ -n "$ts" ] || die "block $bn has no timestamp"
  python3 -c 'import sys; print(int(sys.argv[1], 0))' "$ts"
}

# Polls for the first log matching the filter; prints its transaction hash. An RPC error is retried, never read as
# "no log"; only the timeout ends the wait.
wait_log() { # rpc label from_block address event_sig timeout_s [topic...]
  local rpc="$1" label="$2" from="$3" addr="$4" sig="$5" timeout="$6" start out tx
  shift 6
  start="$(date +%s)"
  while :; do
    if out="$(cast logs --json --rpc-url "$rpc" --from-block "$from" --to-block latest --address "$addr" "$sig" "$@" 2>/dev/null)"; then
      tx="$(python3 -c 'import json,sys; l=json.loads(sys.argv[1] or "[]"); print(l[0]["transactionHash"] if l else "")' "$out")"
      if [ -n "$tx" ]; then
        echo "$label: tx $tx after $(($(date +%s) - start)) s of waiting" >&2
        echo "$tx"
        return 0
      fi
    else
      echo "$label: log query failed, retrying (state unknown, not 'absent')" >&2
    fi
    [ $(($(date +%s) - start)) -lt "$timeout" ] || die "$label: not seen within $timeout s"
    sleep 3
  done
}

output() { # NAME value: appended to $DEPLOY_OUT when set (addresses only, for the next script)
  if [ -n "${DEPLOY_OUT:-}" ]; then echo "$1=$2" >> "$DEPLOY_OUT"; fi
}

summary() { # markdown line for the job summary
  echo "$*"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "$*" >> "$GITHUB_STEP_SUMMARY"; fi
}
