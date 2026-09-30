#!/bin/bash
# Run the release validation checks without modifying system state.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for command in bash jq; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "error: required command not found: $command" >&2
    exit 1
  }
done

BATS_BIN="${BATS_BIN:-}"
if [[ -z "$BATS_BIN" ]]; then
  BATS_BIN="$(command -v bats 2>/dev/null || true)"
fi
if [[ -z "$BATS_BIN" && -x "$HOME/.local/bats/bin/bats" ]]; then
  BATS_BIN="$HOME/.local/bats/bin/bats"
fi
[[ -x "$BATS_BIN" ]] || {
  echo "error: Bats not found; set BATS_BIN or install bats-core" >&2
  exit 1
}

echo "checking shell syntax..."
bash -n "$REPO_DIR"/install.sh "$REPO_DIR"/sync.sh "$REPO_DIR"/setup-system-integrations.sh "$REPO_DIR"/*.sh
echo "checking JSON..."
jq empty "$REPO_DIR/docs/proxy.json"
echo "running tests..."
"$BATS_BIN" "$REPO_DIR/tests/proxy-manager.bats"
