#!/usr/bin/env bash
# Verification of one deployment (run by .github/workflows/verify.yml; no key, sends no transaction).
#
#   D (always): scripts/bytecode_match.py: the code on chain against the build of the deployment's source commit,
#     immutables masked, metadata compared. Writes status/bytecode-<name>.json. Public reads only.
#   Only with PUBLISH=yes (the owner's yes to registering our sources on outside sites is required first):
#   A: forge verify-contract --verifier sourcify, per contract;
#   B: if A fails for a contract, the standard JSON input sent to Sourcify's v2 API with Python (scripts/sourcify.py);
#   C: Base Sepolia contracts also on Blockscout (forge verify-contract --verifier blockscout).
#   Gate with PUBLISH=yes: Sourcify must then report an exact match for every address.
#
# Environment: DEPLOYMENT (name of deployments/<name>.json), BUILD_DIR (checkout of the source commit, built),
#   PUBLISH (no | yes).
set -euo pipefail
cd "$(dirname "$0")/.."

: "${DEPLOYMENT:?}" "${BUILD_DIR:?}"
publish="${PUBLISH:-no}"
[ "$publish" = no ] || [ "$publish" = yes ] || { echo "PUBLISH must be no or yes"; exit 2; }

say() {
  echo "$*"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "$*" >> "$GITHUB_STEP_SUMMARY"; fi
}

say "### Verification of deployment $DEPLOYMENT"
say ""
say "Branch D: bytecode match (no third party)"
say ""
say '```'
status_d=0
python3 scripts/bytecode_match.py --deployment "$DEPLOYMENT" --out "$BUILD_DIR/out" 2>&1 | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}" \
  || status_d=1
say '```'
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); sys.exit(0 if d["allMatch"] else 1)' \
  "status/bytecode-$DEPLOYMENT.json" || status_d=1
if [ "$status_d" != 0 ]; then
  say "Branch D: NOT every contract matches its build. Stop."
  exit 1
fi
say "Branch D: every contract matches the build of its source commit."

if [ "$publish" != yes ]; then
  say ""
  say "Branches A to C (Sourcify, Blockscout) not run: publish=no."
  exit 0
fi
# Branches A to C reach Sourcify and Blockscout, so forge must be online here, whatever ci-setup.sh wrote to
# GITHUB_ENV (FOUNDRY_OFFLINE=true) and whichever of that and the step's env GitHub lets win.
export FOUNDRY_OFFLINE=false

# One line per contract: key chainId address artifact constructorArgs
mapfile -t rows < <(python3 - "$DEPLOYMENT" <<'PY'
import json, sys
d = json.load(open(f"deployments/{sys.argv[1]}.json", encoding="utf-8"))
for b in d["build"]:
    print(b["key"], b["chainId"], b["address"], b["artifact"], b.get("constructorArgs") or "0x")
PY
)
fails=0
for row in "${rows[@]}"; do
  read -r key chain address artifact args <<<"$row"
  say ""
  say "#### $key ($artifact) on chain $chain: $address"
  extra=()
  [ "$args" = 0x ] || extra=(--constructor-args "$args")
  if (cd "$BUILD_DIR" && forge verify-contract --verifier sourcify --chain "$chain" "${extra[@]}" --watch "$address" "$artifact"); then
    say "A (forge, Sourcify): submitted"
  else
    say "A (forge, Sourcify): failed; trying B"
    if python3 scripts/sourcify.py submit --build-dir "$BUILD_DIR" --chain "$chain" --address "$address" \
      --artifact "$artifact" --deployment "$DEPLOYMENT" --key "$key"; then
      say "B (standard JSON, Sourcify v2): submitted"
    else
      say "B (standard JSON, Sourcify v2): failed"
    fi
  fi
  if [ "$chain" = 84532 ]; then
    if (cd "$BUILD_DIR" && forge verify-contract --verifier blockscout \
      --verifier-url https://base-sepolia.blockscout.com/api/ --chain "$chain" "${extra[@]}" --watch "$address" "$artifact"); then
      say "C (Blockscout): submitted"
    else
      say "C (Blockscout): failed (not a gate)"
    fi
  fi
  if python3 scripts/sourcify.py check --chain "$chain" --address "$address"; then
    say "Sourcify: exact match"
  else
    say "Sourcify: NOT an exact match"
    fails=$((fails + 1))
  fi
done
say ""
[ "$fails" = 0 ] || { say "Gate: $fails contracts without an exact Sourcify match."; exit 1; }
say "Gate: every contract has an exact Sourcify match."
