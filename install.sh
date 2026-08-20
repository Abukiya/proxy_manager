#!/bin/bash
# Install abukiya.proxy from this repo into Omarchy.
# Safe to re-run: only (re)creates the symlink and enables the plugin.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$REPO_DIR/plugin"
LIVE_PLUGIN_DIR="$HOME/.config/omarchy/plugins/abukiya.proxy"

[[ -d "$PLUGIN_DIR" ]] || { echo "error: no plugin/ dir in $REPO_DIR" >&2; exit 1; }

mkdir -p "$HOME/.config/omarchy/plugins"

# Replace an existing real directory (e.g. an older copy) with the symlink.
if [[ -e "$LIVE_PLUGIN_DIR" && ! -L "$LIVE_PLUGIN_DIR" ]]; then
  echo "note: replacing real dir $LIVE_PLUGIN_DIR with symlink"
  rm -rf "$LIVE_PLUGIN_DIR"
fi

ln -sfn "$PLUGIN_DIR" "$LIVE_PLUGIN_DIR"
echo "symlinked: $LIVE_PLUGIN_DIR -> $PLUGIN_DIR"

# Enable the plugin if it isn't already.
if ! grep -q '"id":"abukiya.proxy"' "$HOME/.config/omarchy/shell.json" 2>/dev/null; then
  omarchy plugin enable abukiya.proxy || echo "note: run 'omarchy plugin enable abukiya.proxy' manually"
else
  echo "plugin already enabled in shell.json"
fi

omarchy-shell shell rescanPlugins 2>/dev/null || true

echo
echo "Done. Verify with:"
echo "  omarchy-shell abukiya.proxy status"
echo "  omarchy-shell abukiya.proxy enable   # (to apply proxy config)"