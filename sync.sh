#!/bin/bash
# Re-sync plugin/ from this repo into the live Omarchy plugin directory.
# Use after editing files in plugin/ (the live dir is a real copy, not a
# symlink, because Qt QML cannot load widget/panel entry points through a
# symlinked directory).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$REPO_DIR/plugin"
LIVE_PLUGIN_DIR="$HOME/.config/omarchy/plugins/abukiya.proxy"

[[ -d "$PLUGIN_DIR" ]] || { echo "error: no plugin/ dir in $REPO_DIR" >&2; exit 1; }

mkdir -p "$LIVE_PLUGIN_DIR"
cp -a "$PLUGIN_DIR"/. "$LIVE_PLUGIN_DIR"/

omarchy-shell shell rescanPlugins 2>/dev/null || true

echo "synced: $PLUGIN_DIR -> $LIVE_PLUGIN_DIR"
echo "shell reloaded."