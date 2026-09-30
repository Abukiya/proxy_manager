#!/bin/bash
# Compatibility installer for local checkouts.
# Public users should prefer:
#   omarchy plugin add https://github.com/Abukiya/proxy_manager.git --enable

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIVE_PLUGIN_DIR="$HOME/.config/omarchy/plugins/abukiya.proxy"

for command in bash cp grep mkdir rm; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "error: required command not found: $command" >&2
    exit 1
  }
done

[[ -f "$REPO_DIR/manifest.json" ]] || {
  echo "error: root plugin manifest not found in $REPO_DIR" >&2
  exit 1
}

if [[ ${EUID:-$(id -u)} -eq 0 && -n "${SUDO_USER:-}" ]]; then
  command -v getent >/dev/null 2>&1 || {
    echo "error: required command not found: getent" >&2
    exit 1
  }
  TARGET_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
  [[ -n "$TARGET_HOME" ]] || {
    echo "error: could not resolve home directory for $SUDO_USER" >&2
    exit 1
  }
else
  TARGET_HOME="$HOME"
fi

if [[ ${EUID:-$(id -u)} -eq 0 && "$TARGET_HOME" != "/root" ]]; then
  command -v runuser >/dev/null 2>&1 || {
    echo "error: runuser is required when installing for another user" >&2
    exit 1
  }
  run_target_user() {
    runuser -u "$SUDO_USER" -- env HOME="$TARGET_HOME" "$@"
  }
else
  run_target_user() {
    HOME="$TARGET_HOME" "$@"
  }
fi

run_target_user mkdir -p "$TARGET_HOME/.config/omarchy/plugins"
run_target_user rm -rf "$LIVE_PLUGIN_DIR"
run_target_user mkdir -p "$LIVE_PLUGIN_DIR"
run_target_user cp -a "$REPO_DIR"/. "$LIVE_PLUGIN_DIR"/
echo "installed: $LIVE_PLUGIN_DIR (real directory copied from $REPO_DIR)"

if command -v omarchy >/dev/null 2>&1; then
  run_target_user omarchy plugin enable abukiya.proxy ||
    echo "note: run 'omarchy plugin enable abukiya.proxy' manually"
else
  echo "note: omarchy command not found; enable abukiya.proxy manually"
fi

if command -v omarchy-shell >/dev/null 2>&1; then
  run_target_user omarchy-shell shell rescanPlugins 2>/dev/null || true
else
  echo "note: omarchy-shell not found; run 'omarchy-shell shell rescanPlugins' manually"
fi

cat <<'EOF'

User-level installation is complete.
Optional privileged integrations are separate and require an explicit command:
  sudo ./setup-system-integrations.sh
EOF
