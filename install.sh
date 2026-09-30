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

for command in bash cp chmod grep install mkdir rm; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "error: required command not found: $command" >&2
    exit 1
  }
done

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  command -v getent >/dev/null 2>&1 || {
    echo "error: required command not found: getent" >&2
    exit 1
  }
  TARGET_USER="${SUDO_USER:-root}"
  TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
  [[ -n "$TARGET_HOME" ]] || {
    echo "error: could not resolve home directory for $TARGET_USER" >&2
    exit 1
  }
else
  TARGET_USER="$(id -un)"
  TARGET_HOME="$HOME"
fi

LIVE_PLUGIN_DIR="$TARGET_HOME/.config/omarchy/plugins/abukiya.proxy"

[[ -d "$PLUGIN_DIR" ]] || { echo "error: no plugin/ dir in $REPO_DIR" >&2; exit 1; }

run_target_user() {
  if [[ ${EUID:-$(id -u)} -eq 0 && "$TARGET_USER" != "root" ]]; then
    command -v runuser >/dev/null 2>&1 || {
      echo "error: runuser is required when installing as root for $TARGET_USER" >&2
      exit 1
    }
    runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" "$@"
  else
    HOME="$TARGET_HOME" "$@"
  fi
}

run_target_user mkdir -p "$TARGET_HOME/.config/omarchy/plugins"

# Replace a symlink (older install layout) with a real directory.
if [[ -L "$LIVE_PLUGIN_DIR" ]]; then
  echo "note: replacing symlink $LIVE_PLUGIN_DIR with real dir"
  run_target_user rm "$LIVE_PLUGIN_DIR"
fi

run_target_user rm -rf "$LIVE_PLUGIN_DIR"
run_target_user mkdir -p "$LIVE_PLUGIN_DIR"
run_target_user cp -a "$PLUGIN_DIR"/. "$LIVE_PLUGIN_DIR"/
echo "installed: $LIVE_PLUGIN_DIR (real dir, copied from $PLUGIN_DIR)"

# Enable the plugin if it isn't already.
if ! grep -q '"id"[[:space:]]*:[[:space:]]*"abukiya.proxy"' "$TARGET_HOME/.config/omarchy/shell.json" 2>/dev/null; then
  if command -v omarchy >/dev/null 2>&1; then
    run_target_user omarchy plugin enable abukiya.proxy ||
      echo "note: run 'omarchy plugin enable abukiya.proxy' manually"
  else
    echo "note: omarchy command not found; enable abukiya.proxy manually"
  fi
else
  echo "plugin already enabled in shell.json"
fi

if command -v omarchy-shell >/dev/null 2>&1; then
  run_target_user omarchy-shell shell rescanPlugins 2>/dev/null || true
else
  echo "note: omarchy-shell not found; run 'omarchy-shell shell rescanPlugins' manually"
fi

# Install polkit rule for passwordless sudoers management (optional).
RULES_SRC="$REPO_DIR/policy/60-abukiya-proxy.rules"
RULES_DST="/etc/polkit-1/rules.d/60-abukiya-proxy.rules"
if [[ -f "$RULES_SRC" ]]; then
  if [[ ${EUID:-$(id -u)} -eq 0 && -d "/etc/polkit-1/rules.d" ]]; then
    install -m 644 "$RULES_SRC" "$RULES_DST"
    echo "installed: polkit rule (passwordless sudoers management)"
  else
    echo "note: polkit rule not installed; rerun as root to enable pacman proxy"
  fi
fi

# Install root-owned system helper (preferred by proxy-manager.sh).
# When present, pkexec runs /usr/local/bin/omarchy-proxy-sudoers-helper
# which is not writable by the user, so tampering can't escalate to root.
HELPER_SRC="$PLUGIN_DIR/proxy-sudoers-helper"
HELPER_DST="/usr/local/bin/omarchy-proxy-sudoers-helper"
if [[ -f "$HELPER_SRC" ]]; then
  if [[ ${EUID:-$(id -u)} -eq 0 && -d "/usr/local/bin" ]]; then
    install -m 755 -o root -g root "$HELPER_SRC" "$HELPER_DST"
    echo "installed: system helper $HELPER_DST (root-owned)"
  else
    echo "note: root-owned pacman helper not installed; rerun as root to harden it"
  fi
fi

# Install NetworkManager dispatcher for automatic gateway-change detection.
DISPATCHER_SRC="$PLUGIN_DIR/nm-dispatcher-proxy"
DISPATCHER_DST="/etc/NetworkManager/dispatcher.d/99-proxy-gateway"
if [[ -f "$DISPATCHER_SRC" ]]; then
  if [[ ${EUID:-$(id -u)} -eq 0 && -d "/etc/NetworkManager/dispatcher.d" ]]; then
    install -m 755 "$DISPATCHER_SRC" "$DISPATCHER_DST"
    echo "installed: NM dispatcher (auto gateway-change detection)"
    # Restart the dispatcher to pick up the new script.
    systemctl restart NetworkManager-dispatcher.service 2>/dev/null || true
  else
    echo "note: NM dispatcher not installed; rerun as root to enable connection-event detection"
  fi
fi

echo
echo "Done. Verify with:"
echo "  omarchy-shell abukiya.proxy status"
echo "  omarchy-shell abukiya.proxy enable   # (to apply proxy config)"