#!/bin/bash
# Re-sync this root plugin into the live Omarchy plugin directory.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIVE_PLUGIN_DIR="$HOME/.config/omarchy/plugins/abukiya.proxy"

for command in cp mkdir omarchy-shell rm; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "error: required command not found: $command" >&2
    exit 1
  }
done

[[ -f "$REPO_DIR/manifest.json" ]] || {
  echo "error: root plugin manifest not found in $REPO_DIR" >&2
  exit 1
}

rm -rf "$LIVE_PLUGIN_DIR"
mkdir -p "$LIVE_PLUGIN_DIR"
cp -a "$REPO_DIR"/. "$LIVE_PLUGIN_DIR"/

omarchy-shell shell rescanPlugins 2>/dev/null || true

echo "synced: $REPO_DIR -> $LIVE_PLUGIN_DIR"
echo "shell reloaded."
