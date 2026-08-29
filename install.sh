#!/bin/bash
# Install abukiya.proxy from this repo into Omarchy.
# Safe to re-run: only (re)creates the plugin directory and enables the plugin.
#
# NOTE: the live plugin directory is a real COPY, not a symlink. Qt/QML's
# component loader refuses to load bar-widget/panel entry points through a
# symlinked directory ("File name case mismatch"), so a copy is required.
# Re-sync after editing files in plugin/ with: ./sync.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$REPO_DIR/plugin"
LIVE_PLUGIN_DIR="$HOME/.config/omarchy/plugins/abukiya.proxy"

[[ -d "$PLUGIN_DIR" ]] || { echo "error: no plugin/ dir in $REPO_DIR" >&2; exit 1; }

mkdir -p "$HOME/.config/omarchy/plugins"

# Replace a symlink (older install layout) with a real directory.
if [[ -L "$LIVE_PLUGIN_DIR" ]]; then
  echo "note: replacing symlink $LIVE_PLUGIN_DIR with real dir"
  rm "$LIVE_PLUGIN_DIR"
fi

mkdir -p "$LIVE_PLUGIN_DIR"
cp -a "$PLUGIN_DIR"/. "$LIVE_PLUGIN_DIR"/
echo "installed: $LIVE_PLUGIN_DIR (real dir, copied from $PLUGIN_DIR)"

# Enable the plugin if it isn't already.
if ! grep -q '"id":"abukiya.proxy"' "$HOME/.config/omarchy/shell.json" 2>/dev/null; then
  omarchy plugin enable abukiya.proxy || echo "note: run 'omarchy plugin enable abukiya.proxy' manually"
else
  echo "plugin already enabled in shell.json"
fi

omarchy-shell shell rescanPlugins 2>/dev/null || true

# Install polkit rule for passwordless sudoers management (optional).
RULES_SRC="$REPO_DIR/policy/60-abukiya-proxy.rules"
RULES_DST="/etc/polkit-1/rules.d/60-abukiya-proxy.rules"
if [[ -f "$RULES_SRC" ]]; then
  if [[ -w "/etc/polkit-1/rules.d/" ]]; then
    cp "$RULES_SRC" "$RULES_DST"
    echo "installed: polkit rule (passwordless sudoers management)"
  else
    echo "note: to enable passwordless pacman proxy, run with sudo:"
    echo "  sudo cp $RULES_SRC $RULES_DST"
  fi
fi

echo
echo "Done. Verify with:"
echo "  omarchy-shell abukiya.proxy status"
echo "  omarchy-shell abukiya.proxy enable   # (to apply proxy config)"