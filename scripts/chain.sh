# shellcheck shell=bash
# Helpers shared by the deploy and loop scripts. Sourced, never run directly.
#
# Inputs (environment):
#   BASE_RPC, LASNA_RPC   JSON-RPC endpoints of Base Sepolia and Reactive Lasna
#   DEPLOY_KEY            the testnet key (GitHub secret TESTNET_KEY), "key A"; never printed, never written to a file.
#                         Key B is derived from it (derive_key_b below), masked, and never printed either.
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
  check_balance_of "$1" "$2" "$DEPLOYER" "$3"
}
check_balance_of() { # rpc label address need_wei
  local bal
  bal="$(cast balance --rpc-url "$1" "$3" 2>/dev/null)" || die "$2: balance unknown (RPC error)"
  [ -n "$bal" ] || die "$2: balance unknown (empty answer)"
  python3 - "$bal" "$4" "$2" <<'PY' || exit 1
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

# Polls for the first log matching the filter; prints its transaction hash. The poll itself is scripts/wait-log.py:
# an RPC error is retried, never read as "no log"; only the timeout ends the wait. Queries name both block ends and
# span at most LOG_CHUNK blocks, and send their own User-Agent (sepolia.base.org refuses urllib's default with 403
# and wide or "latest" ranges with 413). Every returned log is checked again (address, block, topics).
# Topics are 32-byte hex values for topic1, topic2, ... (use `cast to-uint256` for numbers).
wait_log() { # rpc label from_block address event_sig timeout_s [topic...]
  local rpc="$1" label="$2" from="$3" addr="$4" sig="$5" timeout="$6" topic0 tx rc
  shift 6
  topic0="$(cast keccak "$sig")" || die "$label: cannot hash $sig"
  rc=0
  tx="$(python3 scripts/wait-log.py "$rpc" "$label" "$from" "$addr" "$topic0" "$timeout" "$@")" || rc=$?
  case "$rc" in
    0) [ -n "$tx" ] || die "$label: wait ended with no hash" ;;
    3) die "$label: not seen within $timeout s" ;;
    *) die "$label: wait failed (exit $rc)" ;;
  esac
  echo "$tx"
}

# Stops unless the exit landed strictly before the change could run (both unix seconds).
check_exit_timing() { # exit_time executable_at label
  [[ "$1" =~ ^[0-9]+$ ]] && [[ "$2" =~ ^[0-9]+$ ]] || die "$3: exit time '$1' or executableAt '$2' unknown"
  [ "$2" -gt 0 ] || die "$3: executableAt is 0 (the change was not pending when read)"
  [ "$1" -lt "$2" ] || die "$3: the exit landed at $1, not before the change could run at $2"
}

# Prints "outcome reason shares assets" of the WatchEnded log of `watch_topic` emitted by `exit_addr` in `tx`.
watch_ended_fields() { # rpc txhash exit_addr watch_topic
  local r
  r="$(cast receipt --json --rpc-url "$1" "$2" 2>/dev/null)" || die "receipt of $2 unknown"
  python3 -c '
import json, sys
rec = json.loads(sys.argv[1])
addr, topic1, topic0 = sys.argv[2].lower(), sys.argv[3].lower(), sys.argv[4].lower()
for log in rec.get("logs", []):
    t = [x.lower() for x in log.get("topics", [])]
    if log.get("address", "").lower() == addr and len(t) == 3 and t[0] == topic0 and t[1] == topic1:
        d = log["data"][2:]
        if len(d) != 256:
            sys.exit(3)
        print(" ".join(str(int(d[i * 64:(i + 1) * 64], 16)) for i in range(4)))
        sys.exit(0)
sys.exit(4)
' "$r" "$3" "$4" "$(cast keccak 'WatchEnded(uint256,uint256,uint8,uint8,uint256,uint256)')" \
    || die "no well-formed WatchEnded for watch $4 in $2"
}

# Key B: a second test key derived from the testnet key, so a run can have a depositor that is not the curator
# without a second secret. sha256(key A as lowercase hex without 0x || KEY_B_LABEL), computed in Python from the
# environment (the key never appears on a command line or in output). Sets KEY_B and ADDR_B; in Actions the key is
# masked before any use. Call it directly, never inside $(...), or the mask line is swallowed.
KEY_B_LABEL="|notice-period test key b|v1"
derive_key_b() {
  [ -n "${DEPLOY_KEY:-}" ] || die "no key A to derive key B from"
  KEY_B="$(KEY_B_LABEL="$KEY_B_LABEL" python3 - <<'PY'
import hashlib, os, sys
a = os.environ["DEPLOY_KEY"].strip().lower()
a = a[2:] if a.startswith("0x") else a
d = hashlib.sha256((a + os.environ["KEY_B_LABEL"]).encode()).hexdigest()
n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
if not 0 < int(d, 16) < n:
    sys.exit("STOP: derived key B is out of range")
print("0x" + d)
PY
)" || die "could not derive key B"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::add-mask::${KEY_B}"; fi
  ADDR_B="$(masked_address "$KEY_B")" || die "could not derive key B's address"
  echo "key B (derived): $ADDR_B"
}

# Address of a key that is already masked (key A is a secret, key B is masked by derive_key_b before this is called).
# Only the address is printed.
masked_address() { # key
  cast wallet address --private-key "$1"
}

# Target address of the n-th scheduled change of a run on a vault: the last 20 bytes of
# keccak256(abi.encode(run_id, vault, n)). Distinct per Submit, so a second Submit on one vault never repeats the same
# bytes (DataAlreadyPending).
keccak_target() { # run_id vault n
  local h
  h="$(cast keccak "$(cast abi-encode 'f(uint256,address,uint256)' "$1" "$2" "$3")")" || die "cannot derive a target"
  cast to-check-sum-address "0x${h: -40}"
}

# cast send with an explicit key (A or B). Prints the transaction hash; stops unless the receipt says success.
# With LOOP_NO_KEY_A=1 (health job) it refuses to send with key A.
send_as() { # key rpc label to [sig args... | --value x]
  local key="$1" rpc="$2" label="$3" out status tx
  shift 3
  if [ "${LOOP_NO_KEY_A:-0}" = 1 ] && [ "$key" = "${DEPLOY_KEY:-}" ]; then
    die "$label: this job may not send from key A"
  fi
  out="$(cast send --json --rpc-url "$rpc" --private-key "$key" "$@")" || die "$label: transaction failed"
  status="$(json_field "$out" status)"
  tx="$(json_field "$out" transactionHash)"
  case "$status" in 1 | 0x1 | true | True) ;; *) die "$label: transaction $tx did not succeed (status $status)" ;; esac
  echo "$label: tx $tx" >&2
  echo "$tx"
}

# Debt of a payer contract (NoticeExit, NoticeReactive) to its own service provider (callback proxy or system
# contract), read from the contract's _SERVICE_PROVIDER. Any debt stops every delivery to that contract.
debt_of() { # rpc contract -> wei
  local sp d
  sp="$(cast call --rpc-url "$1" "$2" '_SERVICE_PROVIDER()(address)' 2>/dev/null)" || die "service provider of $2 unknown"
  d="$(cast call --rpc-url "$1" "$sp" 'debt(address)(uint256)' "$2" 2>/dev/null | awk '{print $1}')" || die "debt of $2 unknown"
  [ -n "$d" ] || die "debt of $2 unknown (empty answer)"
  echo "$d"
}

block_time() { # rpc -> unix seconds of the latest block
  local b ts
  b="$(cast block --json --rpc-url "$1" latest 2>/dev/null)" || die "latest block unknown"
  ts="$(json_field "$b" timestamp)"
  [ -n "$ts" ] || die "latest block has no timestamp"
  python3 -c 'import sys; print(int(sys.argv[1], 0))' "$ts"
}

tx_block() { # rpc txhash -> block number
  local r bn
  r="$(cast receipt --json --rpc-url "$1" "$2" 2>/dev/null)" || die "receipt of $2 unknown"
  bn="$(json_field "$r" blockNumber)"
  [ -n "$bn" ] || die "receipt of $2 has no block number"
  python3 -c 'import sys; print(int(sys.argv[1], 0))' "$bn"
}

output() { # NAME value: appended to $DEPLOY_OUT when set (addresses only, for the next script)
  if [ -n "${DEPLOY_OUT:-}" ]; then echo "$1=$2" >> "$DEPLOY_OUT"; fi
}

summary() { # markdown line for the job summary
  echo "$*"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "$*" >> "$GITHUB_STEP_SUMMARY"; fi
}
