#!/bin/bash
# Install optional privileged integrations for an already-installed plugin.
# This is intentionally separate from `omarchy plugin add`.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES_SRC="$REPO_DIR/policy/60-abukiya-proxy.rules"
RULES_DST="/etc/polkit-1/rules.d/60-abukiya-proxy.rules"
HELPER_SRC="$REPO_DIR/proxy-sudoers-helper"
HELPER_DST="/usr/local/bin/omarchy-proxy-sudoers-helper"
DISPATCHER_SRC="$REPO_DIR/nm-dispatcher-proxy"
DISPATCHER_DST="/etc/NetworkManager/dispatcher.d/99-proxy-gateway"

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
  echo "error: run this command with sudo" >&2
  exit 1
}

for path in "$RULES_SRC" "$HELPER_SRC" "$DISPATCHER_SRC"; do
  [[ -f "$path" ]] || {
    echo "error: required source file not found: $path" >&2
    exit 1
  }
done

command -v install >/dev/null 2>&1 || {
  echo "error: required command not found: install" >&2
  exit 1
}

if [[ -d /etc/polkit-1/rules.d ]]; then
  install -m 644 "$RULES_SRC" "$RULES_DST"
  echo "installed: polkit rule"
else
  echo "note: /etc/polkit-1/rules.d is unavailable; polkit integration skipped"
fi

if [[ -d /usr/local/bin ]]; then
  install -m 755 -o root -g root "$HELPER_SRC" "$HELPER_DST"
  echo "installed: root-owned sudoers helper"
else
  echo "note: /usr/local/bin is unavailable; sudoers helper skipped"
fi

if [[ -d /etc/NetworkManager/dispatcher.d ]]; then
  install -m 755 "$DISPATCHER_SRC" "$DISPATCHER_DST"
  echo "installed: NetworkManager gateway dispatcher"
  systemctl restart NetworkManager-dispatcher.service 2>/dev/null || true
else
  echo "note: NetworkManager dispatcher directory is unavailable; dispatcher skipped"
fi

echo "Optional system integrations are configured."
