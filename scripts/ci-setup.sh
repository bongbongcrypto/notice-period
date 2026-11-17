#!/usr/bin/env bash
# Installs the pinned toolchain and libraries inside GitHub Actions.
# Every download is checked against a digest or a full commit hash written below.
# Nothing here runs on a developer machine.
set -euo pipefail

FOUNDRY_VERSION="v1.9.0"
# sha256 of foundry_v1.9.0_linux_amd64.tar.gz, from the GitHub release API ("digest" field, immutable release).
FOUNDRY_SHA256="8d17599b42e3139f1a9c171be3798c4ed8e743ae17b84cc3435e57bf2a51ae99"

SOLC_VERSION="0.8.30"
SOLC_FILE="solc-linux-amd64-v0.8.30+commit.73712a01"
# sha256 from https://binaries.soliditylang.org/linux-amd64/list.json
SOLC_SHA256="f3e987dc6ecebd4bd350c48edcbc320b46cf9e3109bd3fc3d88f1acaf4c428f7"

# Sponsor library, fetched and never committed (it carries no licence).
REACTIVE_LIB_URL="https://github.com/Reactive-Network/reactive-lib-omni.git"
REACTIVE_LIB_COMMIT="3ade0dcf1d27e67e5783ef807e73a1b9e0c0cce8"
# forge-std v1.16.1, the same commit the sponsor library locks.
FORGE_STD_URL="https://github.com/foundry-rs/forge-std.git"
FORGE_STD_COMMIT="620536fa5277db4e3fd46772d5cbc1ea0696fb43"

workspace="${GITHUB_WORKSPACE:-$(pwd)}"
tools="${RUNNER_TEMP:-/tmp}/notice-tools"
mkdir -p "$tools/bin"

echo "Foundry ${FOUNDRY_VERSION}"
curl -fsSL --retry 3 -o "$tools/foundry.tar.gz" \
  "https://github.com/foundry-rs/foundry/releases/download/${FOUNDRY_VERSION}/foundry_${FOUNDRY_VERSION}_linux_amd64.tar.gz"
echo "${FOUNDRY_SHA256}  $tools/foundry.tar.gz" | sha256sum -c -
tar -xzf "$tools/foundry.tar.gz" -C "$tools/bin"

echo "solc ${SOLC_VERSION}"
curl -fsSL --retry 3 -o "$tools/bin/solc-${SOLC_VERSION}" \
  "https://binaries.soliditylang.org/linux-amd64/${SOLC_FILE}"
echo "${SOLC_SHA256}  $tools/bin/solc-${SOLC_VERSION}" | sha256sum -c -
chmod +x "$tools/bin/"*

fetch_pinned() {
  local dir="$1" url="$2" commit="$3"
  rm -rf "$dir"
  git init -q "$dir"
  git -C "$dir" remote add origin "$url"
  git -C "$dir" fetch -q --depth 1 origin "$commit"
  git -C "$dir" checkout -q FETCH_HEAD
  local got
  got="$(git -C "$dir" rev-parse HEAD)"
  if [ "$got" != "$commit" ]; then
    echo "pin mismatch for $url: got $got, want $commit" >&2
    exit 1
  fi
  echo "$url @ $got"
}
fetch_pinned "$workspace/lib/reactive-lib-omni" "$REACTIVE_LIB_URL" "$REACTIVE_LIB_COMMIT"
fetch_pinned "$workspace/lib/forge-std" "$FORGE_STD_URL" "$FORGE_STD_COMMIT"

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$tools/bin" >> "$GITHUB_PATH"
  # Point Foundry at the verified compiler and forbid any download: a silent fallback fails the build.
  echo "FOUNDRY_SOLC_VERSION=$tools/bin/solc-${SOLC_VERSION}" >> "$GITHUB_ENV"
  echo "FOUNDRY_OFFLINE=true" >> "$GITHUB_ENV"
fi
"$tools/bin/forge" --version
"$tools/bin/solc-${SOLC_VERSION}" --version | tail -n 1
