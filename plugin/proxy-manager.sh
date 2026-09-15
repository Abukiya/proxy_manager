#!/bin/bash
#
# abukiya.proxy helper: apply / clear system proxy configuration.
#
# Usage: proxy-manager.sh <status|enable|disable [--no-check]>
#
# State lives in ~/.config/omarchy/proxy.json (created with defaults if
# missing). "enabled" is the persisted on/off flag; each integration is only
# touched if it appears in "integrations".

set -uo pipefail

CONFIG_FILE="$HOME/.config/omarchy/proxy.json"
ENV_DIR="$HOME/.config/environment.d"
PIP_CONF_DIR="$HOME/.config/pip"
PACMAN_SUDOERS="/etc/sudoers.d/omarchy-proxy"
BASHRC="$HOME/.bashrc"
STATE_DIR="$HOME/.config/hotspot-proxy"
USER_APPS="$HOME/.local/share/applications"
BROWSERS="chromium google-chrome-stable chromium-browser brave-browser google-chrome"
SUDOERS_HELPER="$(dirname "$(readlink -f "$0")")/proxy-sudoers-helper"

get_port() {
  local port
  if [[ -f "$CONFIG_FILE" ]]; then
    port=$(jq -r '.port // 8080' "$CONFIG_FILE")
  else
    port=8080
  fi
  if [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 ]] && [[ "$port" -le 65535 ]]; then
    echo "$port"
  else
    echo "8080"
  fi
}

detect_gateway_proxy() {
  local gw port
  gw=$(ip route 2>/dev/null | grep default | grep -v tun | grep -v tap | awk '{print $3}' | head -1)
  port=$(get_port)
  if [[ -n $gw ]]; then
    echo "http://$gw:$port"
  else
    echo "http://127.0.0.1:$port"
  fi
}

read_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    local url enabled
    url=$(detect_gateway_proxy)
    # Seed "enabled" from the state the machine already has, so a fresh
    # install never misreads an existing proxy (e.g. git/npm configured
    # through an earlier setproxy.sh run) as "off".
    if git config --global --get http.proxy >/dev/null 2>&1 || [[ -f "$ENV_DIR/proxy.conf" ]]; then
      enabled=true
    else
      enabled=false
    fi
    cat > "$CONFIG_FILE" <<EOF
{
  "httpProxy": "$url",
  "httpsProxy": "$url",
  "noProxy": "localhost,127.0.0.1,::1",
  "integrations": ["env", "git", "npm", "pip", "pacman", "browser", "vscode"],
  "gatewayAuto": true,
  "port": 8080,
  "enabled": $enabled
}
EOF
  fi
  cat "$CONFIG_FILE"
}

cfg_get() {
  read_config | jq -r "$1"
}

cfg_has_integration() {
  local name="$1"
  cfg_get ".integrations | index(\"$name\") != null" | grep -q true
}

set_enabled_flag() {
  local val="$1"
  read_config | jq --argjson enabled "$val" '.enabled = $enabled' > "$CONFIG_FILE.tmp"
  mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
}

# When gatewayAuto is on, refresh httpProxy/httpsProxy from the current
# gateway before applying (mirrors setproxy.sh, which re-detects every run).
# This is what keeps the proxy correct when the phone hotspot gateway moves.
refresh_gateway_urls() {
  local auto
  auto=$(cfg_get '.gatewayAuto')
  if [[ "$auto" == "false" ]]; then
    return 0
  fi
  local url
  url=$(detect_gateway_proxy)
  read_config | jq --arg url "$url" '.httpProxy = $url | .httpsProxy = $url' > "$CONFIG_FILE.tmp"
  mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
}

# ----------------------------------------------------------------- env vars

# Write the # PROXY_SETTINGS block into ~/.bashrc, inserting it ABOVE the
# interactive-shell guard ([[ $- != *i* ]] && return). omarchy's menu/terminal
# launch scripts run non-interactive shells (bash -lc via execDetached, foot
# -e), so a block below the guard is never sourced — `sudo pacman -S` from the
# menu's Install flow would get no http_proxy and fail on a hotspot-only
# network. Falls back to appending at EOF when no guard exists.
install_bashrc_block() {
  local http="$1" https="$2" snippet tmp escaped_http escaped_https

  tmp=$(mktemp)
  cat > "$tmp" <<'BASHRC_BLOCK'

# PROXY_SETTINGS
if [[ -f "$HOME/.config/environment.d/proxy.conf" ]]; then
  export HTTP_PROXY="__HTTP__"
  export HTTPS_PROXY="__HTTPS__"
  export http_proxy="__HTTP__"
  export https_proxy="__HTTPS__"
  export NODE_USE_ENV_PROXY=1
else
  unset http_proxy HTTP_PROXY https_proxy HTTPS_PROXY NODE_USE_ENV_PROXY 2>/dev/null || true
fi
# END_PROXY_SETTINGS
BASHRC_BLOCK
  # Substitute the actual proxy URLs (or empty strings) into the block.
  escaped_http=$(printf '%s' "$http" | sed 's/[&|\\]/\\&/g')
  escaped_https=$(printf '%s' "$https" | sed 's/[&|\\]/\\&/g')
  sed -i "s|__HTTP__|$escaped_http|g; s|__HTTPS__|$escaped_https|g" "$tmp"
  snippet=$(cat "$tmp")
  rm -f "$tmp"

  # Drop any previous block so a stale copy can't linger below the guard.
  sed -i '/# PROXY_SETTINGS/,/# END_PROXY_SETTINGS/d' "$BASHRC"

  if grep -q '^\[\[ \$- != \*i\* \]\] && return' "$BASHRC"; then
    awk -v block="$snippet" '
      /^\[\[ \$- != \*i\* \]\] && return/ {
        print block
        found = 1
      }
      { print }
      END { if (!found) print block }
    ' "$BASHRC" > "$BASHRC.tmp"
    mv "$BASHRC.tmp" "$BASHRC"
  else
    printf '%s\n' "$snippet" >> "$BASHRC"
  fi
}

enable_env() {
  local http https no
  http=$(cfg_get '.httpProxy // empty')
  https=$(cfg_get '.httpsProxy // empty')
  no=$(cfg_get '.noProxy // empty')
  mkdir -p "$ENV_DIR"
  cat > "$ENV_DIR/proxy.conf" <<EOF
http_proxy=$http
https_proxy=$https
no_proxy=$no
HTTP_PROXY=$http
HTTPS_PROXY=$https
NO_PROXY=$no
EOF
  # Persist into ~/.bashrc so new terminals pick the proxy up immediately
  # instead of waiting for the next login. The block is self-cleaning: once
  # proxy.conf is gone (disable), any inherited proxy env vars get unset in
  # new shells even before a re-login.
  install_bashrc_block "$http" "$https"
  # Best effort for the running session's future systemd user services.
  systemctl --user set-environment \
    http_proxy="$http" HTTP_PROXY="$http" \
    https_proxy="$https" HTTPS_PROXY="$https" \
    no_proxy="$no" NO_PROXY="$no" 2>/dev/null || true

  # Update D-Bus activation environment so D-Bus-activated services also see
  # the proxy vars immediately.
  if command -v dbus-update-activation-environment >/dev/null 2>&1; then
    dbus-update-activation-environment --systemd \
      http_proxy="$http" HTTP_PROXY="$http" \
      https_proxy="$https" HTTPS_PROXY="$https" \
      no_proxy="$no" NO_PROXY="$no" 2>/dev/null || true
  fi
}

disable_env() {
  rm -f "$ENV_DIR/proxy.conf"
  systemctl --user unset-environment http_proxy HTTP_PROXY https_proxy HTTPS_PROXY no_proxy NO_PROXY 2>/dev/null || true

  # Rewrite the bashrc block in "cleaner" mode: the self-cleaning block
  # detects that proxy.conf is gone and auto-unsets any inherited proxy env
  # vars.  This way new terminals are clean without requiring a re-login.
  install_bashrc_block "" ""
}

# ------------------------------------------------------------------------ git

enable_git() {
  local url
  url=$(cfg_get '.httpProxy // empty')
  git config --global http.proxy "$url"
  git config --global https.proxy "$url"
}

disable_git() {
  git config --global --unset-all http.proxy 2>/dev/null || true
  git config --global --unset-all https.proxy 2>/dev/null || true
}

# ------------------------------------------------------------------------ npm

enable_npm() {
  command -v npm >/dev/null 2>&1 || return 0
  npm config set proxy "$(cfg_get '.httpProxy // empty')" >/dev/null 2>&1 || true
  npm config set https-proxy "$(cfg_get '.httpsProxy // empty')" >/dev/null 2>&1 || true
  npm config set strict-ssl false >/dev/null 2>&1 || true
  npm config set maxsockets 1 >/dev/null 2>&1 || true
}

disable_npm() {
  command -v npm >/dev/null 2>&1 || return 0
  npm config delete proxy >/dev/null 2>&1 || true
  npm config delete https-proxy >/dev/null 2>&1 || true
  npm config delete strict-ssl >/dev/null 2>&1 || true
  npm config delete maxsockets >/dev/null 2>&1 || true
}

# ----------------------------------------------------------------------- yarn

enable_yarn() {
  command -v yarn >/dev/null 2>&1 || return 0
  yarn config set proxy "$(cfg_get '.httpProxy // empty')" >/dev/null 2>&1 || true
  yarn config set https-proxy "$(cfg_get '.httpsProxy // empty')" >/dev/null 2>&1 || true
}

disable_yarn() {
  command -v yarn >/dev/null 2>&1 || return 0
  yarn config delete proxy >/dev/null 2>&1 || true
  yarn config delete https-proxy >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------------ pip

enable_pip() {
  command -v pip >/dev/null 2>&1 || return 0
  mkdir -p "$PIP_CONF_DIR"
  local proxy_line="proxy = $(cfg_get '.httpProxy // empty')"
  if [[ -f "$PIP_CONF_DIR/pip.conf" ]]; then
    sed -i '/^\s*proxy\s*=/d' "$PIP_CONF_DIR/pip.conf"
    if grep -q '^\[global\]' "$PIP_CONF_DIR/pip.conf"; then
      sed -i '/^\[global\]/a \'"$proxy_line" "$PIP_CONF_DIR/pip.conf"
    else
      printf '\n[global]\n%s\n' "$proxy_line" >> "$PIP_CONF_DIR/pip.conf"
    fi
  else
    cat > "$PIP_CONF_DIR/pip.conf" <<EOF
[global]
$proxy_line
EOF
  fi
}

disable_pip() {
  command -v pip >/dev/null 2>&1 || return 0
  if [[ -f "$PIP_CONF_DIR/pip.conf" ]]; then
    sed -i '/^\s*proxy\s*=/d' "$PIP_CONF_DIR/pip.conf"
  fi
}

# --------------------------------------------------------------------- pacman

# pacman runs as root via sudo; sudo drops proxy env vars unless a sudoers
# rule keeps them. This only works when the pkexec auth succeeds.
#
# Status uses a marker file instead of probing pkexec every time: pkexec
# needs the polkit agent, which is not reliably reachable from the shell's
# service context (the agent registers after the service's first status
# refresh), and each probe blocks ~5s on a slow agent. enable/disable write
# and clear the marker; the one-time fallback below seeds it for setups that
# already have the rule.
PACMAN_MARKER="$STATE_DIR/pacman-sudoers"

pacman_sudoers_exists() {
  [[ -f "$PACMAN_MARKER" ]]
}

enable_pacman() {
  # Fast path: marker says sudoers file exists, trust it.
  if [[ -f "$PACMAN_MARKER" ]]; then
    return 0
  fi
  if command -v pkexec >/dev/null 2>&1 && [[ -f "$SUDOERS_HELPER" ]]; then
    # Timeout after 5s — pkexec blocks indefinitely when no polkit agent is
    # running, which makes the IPC caller (Panel UI) show "Failed to enable".
    if timeout 5 pkexec "$SUDOERS_HELPER" write 2>/dev/null; then
      : > "$PACMAN_MARKER"
    else
      echo "warning: could not write $PACMAN_SUDOERS (pkexec timed out or denied)"
    fi
  else
    echo "warning: pkexec not available; skipping sudoers env_keep"
  fi
}

disable_pacman() {
  if [[ -f "$PACMAN_MARKER" ]]; then
    timeout 5 pkexec "$SUDOERS_HELPER" remove 2>/dev/null || \
      echo "warning: could not remove $PACMAN_SUDOERS (run: sudo rm /etc/sudoers.d/omarchy-proxy)"
    # Always clear the marker so status reflects "off" even if removal failed.
    rm -f "$PACMAN_MARKER"
  fi
}

# ---------------------------------------------------------------------- vscode

# Mirrors setproxy.sh: VS Code does not honor http_proxy env vars for its
# extensions/integrated terminal proxy settings, so write http.proxy into
# its user settings.json.
VSCODE_SETTINGS="$HOME/.config/Code/User/settings.json"

enable_vscode() {
  local url
  url=$(cfg_get '.httpProxy // empty')
  [[ -f "$VSCODE_SETTINGS" ]] || return 0
  jq --arg url "$url" \
    '."http.proxy" = $url | ."http.proxyStrictSSL" = false' \
    "$VSCODE_SETTINGS" > "$VSCODE_SETTINGS.tmp"
  mv "$VSCODE_SETTINGS.tmp" "$VSCODE_SETTINGS"
}

disable_vscode() {
  [[ -f "$VSCODE_SETTINGS" ]] || return 0
  jq 'del(."http.proxy") | del(."http.proxyStrictSSL")' \
    "$VSCODE_SETTINGS" > "$VSCODE_SETTINGS.tmp"
  mv "$VSCODE_SETTINGS.tmp" "$VSCODE_SETTINGS"
}

# --------------------------------------------------------------------- browser

# Root cause of "launcher/keybind doesn't use proxy": omarchy-launch-browser
# (Super+Shift+Enter, app menu) reads only the FIRST TOKEN of the .desktop
# Exec line, so baking "--proxy-server=..." into Exec gets stripped. Instead
# we point every launcher at a per-browser wrapper that reads the LIVE gateway
# from the state file at launch time. The wrapper infers the browser binary
# from its own filename (symlink), so it works no matter how it's invoked —
# via gtk-launch (full Exec) or omarchy-launch-browser (first token only).
WRAPPER_BIN="$HOME/.local/bin/omarchy-proxy-browser"
WRAPPER_SRC="$(dirname "$(readlink -f "$0")")/omarchy-proxy-browser"

write_wrapper() {
  [[ -f "$WRAPPER_SRC" ]] || { echo "warning: wrapper source not found at $WRAPPER_SRC" >&2; return 1; }
  mkdir -p "$HOME/.local/bin"
  cp "$WRAPPER_SRC" "$WRAPPER_BIN"
  chmod +x "$WRAPPER_BIN"
}

# Create one symlink per browser so the wrapper can tell which binary to exec.
ensure_wrapper_links() {
  for name in $BROWSERS; do
    local sys_desktop="/usr/share/applications/${name}.desktop"
    [[ -f "$sys_desktop" ]] || continue
    ln -sf "$WRAPPER_BIN" "$HOME/.local/bin/omarchy-proxy-$name"
  done
}

# Patch a .desktop's Exec lines so the first token is the wrapper symlink
# (which omarchy-launch-browser keeps), not the bare binary.
route_launcher() {
  local user_desktop="$1"
  local escaped_home="${HOME//\//\\/}"
  sed -i "s|^Exec=\([^ ]*\)|Exec=${escaped_home}/.local/bin/omarchy-proxy-${BROWSER_NAME} |" "$user_desktop"
}

enable_browser() {
  local url
  url=$(cfg_get '.httpProxy // empty')
  [[ -n $url ]] || return 0

  write_wrapper
  ensure_wrapper_links
  mkdir -p "$STATE_DIR"
  echo "$url" > "$STATE_DIR/gateway"

  for name in $BROWSERS; do
    local sys_desktop="/usr/share/applications/${name}.desktop"
    local user_desktop="$USER_APPS/${name}.desktop"
    [[ -f "$sys_desktop" ]] || continue
    # Back up the pristine copy once, so disable can restore exactly.
    [[ -f "${user_desktop}.orig" ]] || cp "$sys_desktop" "${user_desktop}.orig"
    cp "${user_desktop}.orig" "$user_desktop"
    BROWSER_NAME="$name" route_launcher "$user_desktop"
  done

  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$USER_APPS" >/dev/null 2>&1
}

disable_browser() {
  rm -f "$STATE_DIR/gateway"
  for name in $BROWSERS; do
    local user_desktop="$USER_APPS/${name}.desktop"
    local orig_backup="${user_desktop}.orig"
    [[ -f "$orig_backup" ]] || continue
    rm -f "$user_desktop" "$orig_backup"
    rm -f "$HOME/.local/bin/omarchy-proxy-$name"
  done
  rm -f "$WRAPPER_BIN"
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$USER_APPS" >/dev/null 2>&1
}

# --------------------------------------------------------------------- status

integration_active() {
  local out=""
  out+="\"env\":$([[ -f "$ENV_DIR/proxy.conf" ]] && echo true || echo false),"
  out+="\"bashrc\":$(grep -q '# PROXY_SETTINGS' "$BASHRC" 2>/dev/null && echo true || echo false),"
  out+="\"git\":$(git config --global --get http.proxy >/dev/null 2>&1 && echo true || echo false),"
  if command -v npm >/dev/null 2>&1; then
    out+="\"npm\":$([[ "$(npm config get proxy 2>/dev/null)" != "null" ]] && echo true || echo false),"
  else
    out+="\"npm\":false,"
  fi
  if command -v yarn >/dev/null 2>&1; then
    out+="\"yarn\":$([[ "$(yarn config get proxy 2>/dev/null)" != "null" ]] && echo true || echo false),"
  else
    out+="\"yarn\":false,"
  fi
  out+="\"pip\":$(grep -q '^\s*proxy\s*=' "$PIP_CONF_DIR/pip.conf" 2>/dev/null && echo true || echo false),"
  out+="\"pacman\":$(pacman_sudoers_exists && echo true || echo false),"
  local vscode_active="false"
  if [[ -f "$VSCODE_SETTINGS" ]] && jq -e '."http.proxy" != null' "$VSCODE_SETTINGS" >/dev/null 2>&1; then
    vscode_active="true"
  fi
  out+="\"vscode\":$vscode_active,"
  out+="\"browser\":$([[ -f "$STATE_DIR/gateway" ]] && echo true || echo false)"
  echo "{ $out }"
}

cmd_status() {
  read_config | jq -c --argjson integrations "$(cfg_get '.integrations')" \
    --argjson active "$(integration_active)" \
    '{enabled: .enabled, httpProxy: .httpProxy, httpsProxy: .httpsProxy, noProxy: .noProxy,
      integrations: $integrations, active: $active}'
}

# --------------------------------------------------------------------- apply

# pacman must run LAST: it prompts for root via pkexec (a modal polkit
# dialog) and would otherwise block the browser/env steps behind it.
apply() {
  local action="$1"
  for name in env git npm yarn pip browser vscode pacman; do
    if cfg_has_integration "$name"; then
      "${action}_${name}"
    fi
  done
}

# ---------------------------------------------------------- connectivity check

# Test whether the machine has direct internet access (no proxy).
# Returns 0 if reachable, 1 if not.  Used after `disable` to warn the user
# when the phone hotspot requires Every Proxy to be running.
check_connectivity() {
  # Three probes — any one success means we're fine.
  curl -s --connect-timeout 5 --max-time 10 -o /dev/null \
    "http://connectivitycheck.gstatic.com/generate_204" 2>/dev/null && return 0
  curl -s --connect-timeout 5 --max-time 10 -o /dev/null \
    "http://www.google.com" 2>/dev/null && return 0
  curl -s --connect-timeout 5 --max-time 10 -o /dev/null \
    "http://1.1.1.1" 2>/dev/null && return 0
  return 1
}

notify_no_internet() {
  notify-send -a omarchy-action -u critical -i network-offline \
    "Proxy disabled — no internet detected" \
    "Close all terminals and open a new one.

If using phone hotspot:
• Disable Every Proxy on your phone
• Ensure your phone hotspot allows direct traffic (not proxy-only)" \
    2>/dev/null || true
}

# Re-apply all integrations with the current config (used after gateway change).
# Unlike the full `enable` path, this does NOT touch the enabled flag or
# refresh gateway URLs — the caller already did that.
# pacman is skipped: the sudoers env_keep rule is static and doesn't change
# when the gateway IP changes.  Re-applying it would trigger a pkexec dialog.
apply_current() {
  for name in env git npm yarn pip browser vscode; do
    if cfg_has_integration "$name"; then
      "enable_${name}"
    fi
  done
}

# ------------------------------------------------------------- gateway-watcher

WATCHER_PID_FILE="$STATE_DIR/gateway-watcher.pid"

start_watcher() {
  mkdir -p "$STATE_DIR"

  # If a watcher is already running, don't kill and restart it.
  if [[ -f "$WATCHER_PID_FILE" ]]; then
    local old_pid
    old_pid=$(cat "$WATCHER_PID_FILE")
    if kill -0 "$old_pid" 2>/dev/null; then
      return 0
    fi
    rm -f "$WATCHER_PID_FILE"
  fi

  cat > "$STATE_DIR/gateway-watcher.sh" <<'WATCHER'
#!/bin/bash
# Polls for default gateway changes every 5 seconds.
# When the gateway changes and the proxy is enabled, re-applies all integrations.
STATE_DIR="$HOME/.config/hotspot-proxy"
CONFIG_FILE="$HOME/.config/omarchy/proxy.json"
PM="$HOME/.config/omarchy/plugins/abukiya.proxy/proxy-manager.sh"

last_gw=$(ip route 2>/dev/null | grep default | grep -v tun | grep -v tap | awk '{print $3}' | head -1)

while true; do
  sleep 5

  enabled=$(jq -r '.enabled // false' "$CONFIG_FILE" 2>/dev/null)
  [[ "$enabled" == "true" ]] || continue

  new_gw=$(ip route 2>/dev/null | grep default | grep -v tun | grep -v tap | awk '{print $3}' | head -1)
  [[ -n "$new_gw" ]] || continue
  [[ "$new_gw" != "$last_gw" ]] || continue

  last_gw="$new_gw"

  # Re-apply proxy with the new gateway.
  result=$(bash "$PM" gateway-change 2>/dev/null) || continue

  changed=$(echo "$result" | jq -r '.gatewayChanged // false' 2>/dev/null)
  [[ "$changed" == "true" ]] || continue

  # Re-run enable through IPC so Service.qml's cachedStatus updates.
  # gateway-change already applied everything; this just refreshes the cache.
  omarchy-shell abukiya.proxy enable >/dev/null 2>&1 || true

  new_url=$(echo "$result" | jq -r '.new // ""' 2>/dev/null)
  needs_restart=$(echo "$result" | jq -r '.needsRestart // [] | join(", ")' 2>/dev/null)

  body="Proxy re-applied to $new_url"
  [[ -n "$needs_restart" ]] && body="$body

Restart these apps for full effect:
$needs_restart"

  notify-send -a omarchy-action -i network-proxy \
    "Gateway changed" "$body" 2>/dev/null || true

  # Write the new status to a file so the bar widget can pick it up
  # without going through the IPC cache.
  bash "$PM" status > "$STATE_DIR/live-status.json"
done
WATCHER
  chmod +x "$STATE_DIR/gateway-watcher.sh"

  bash "$STATE_DIR/gateway-watcher.sh" &
  echo $! > "$WATCHER_PID_FILE"
}

stop_watcher() {
  if [[ -f "$WATCHER_PID_FILE" ]]; then
    local pid
    pid=$(cat "$WATCHER_PID_FILE")
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rm -f "$WATCHER_PID_FILE"
  fi
  # Also kill any stale watchers by pattern.
  pkill -f "gateway-watcher.sh" 2>/dev/null || true
}

# ----------------------------------------------------------------- gateway-change

# Called by the NetworkManager dispatcher when the default gateway may have
# changed.  Compares the detected gateway against the stored proxy URL; if
# different and the proxy is enabled, re-applies all integrations and writes
# the new gateway to the browser state file.
#
# Output JSON:
#   { "gatewayChanged": bool, "old": "...", "new": "...",
#     "needsRestart": [...], "enabled": bool }
cmd_gateway_change() {
  local new_gw old_gw enabled port
  new_gw=$(detect_gateway_proxy)
  enabled=$(cfg_get '.enabled // false')

  if [[ "$enabled" != "true" ]]; then
    echo '{"gatewayChanged":false,"old":"","new":"","needsRestart":[],"enabled":false}'
    return 0
  fi

  old_gw=$(cfg_get '.httpProxy // empty')

  if [[ "$new_gw" == "$old_gw" ]]; then
    echo '{"gatewayChanged":false,"old":"'"$old_gw"'","new":"'"$new_gw"'","needsRestart":[],"enabled":true}'
    return 0
  fi

  # Gateway changed — update config and re-apply everything.
  read_config | jq --arg url "$new_gw" \
    '.httpProxy = $url | .httpsProxy = $url' > "$CONFIG_FILE.tmp"
  mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"

  # Write the browser gateway state file so existing browser wrappers see
  # the new URL on their next launch.
  mkdir -p "$STATE_DIR"
  echo "$new_gw" > "$STATE_DIR/gateway"

  apply_current

  # Determine which apps need a manual restart (they cache proxy at startup).
  local needs_restart="[]"
  local needs=""

  if [[ -f "$VSCODE_SETTINGS" ]] && jq -e '."http.proxy" != null' "$VSCODE_SETTINGS" >/dev/null 2>&1; then
    needs_restart='["vscode"]'
    needs="VS Code"
  fi

  if command -v npm >/dev/null 2>&1 && [[ "$(npm config get proxy 2>/dev/null)" != "null" ]]; then
    if [[ -n "$needs" ]]; then
      needs="$needs, npm"
      needs_restart=$(echo "$needs_restart" | jq '. + ["npm"]')
    else
      needs="npm"
      needs_restart='["npm"]'
    fi
  fi

  # Propagate to the running systemd user session immediately.
  local http="$new_gw" https="$new_gw" no
  no=$(cfg_get '.noProxy // empty')
  systemctl --user set-environment \
    http_proxy="$http" HTTP_PROXY="$http" \
    https_proxy="$https" HTTPS_PROXY="$https" \
    no_proxy="$no" NO_PROXY="$no" 2>/dev/null || true

  local escaped_old escaped_new
  escaped_old=$(printf '%s' "$old_gw" | sed 's/[&/\]/\\&/g')
  escaped_new=$(printf '%s' "$new_gw" | sed 's/[&/\]/\\&/g')

  printf '{"gatewayChanged":true,"old":"%s","new":"%s","needsRestart":%s,"enabled":true}\n' \
    "$old_gw" "$new_gw" "$needs_restart"

  # Write live status for the bar widget (bypasses IPC cache).
  cmd_status > "$STATE_DIR/live-status.json"
}

NO_CHECK=false
CMD=""
for arg in "$@"; do
  case "$arg" in
    --no-check) NO_CHECK=true ;;
    status|enable|disable|gateway-change|start-watcher|stop-watcher) CMD="$arg" ;;
  esac
done
CMD="${CMD:-status}"

case "$CMD" in
  status)
    cmd_status
    ;;
  enable)
    refresh_gateway_urls
    apply enable
    set_enabled_flag true
    start_watcher
    mkdir -p "$STATE_DIR"
    cmd_status | tee "$STATE_DIR/live-status.json"
    ;;
  disable)
    stop_watcher
    apply disable
    set_enabled_flag false
    mkdir -p "$STATE_DIR"
    cmd_status | tee "$STATE_DIR/live-status.json"
    # Clean up leftover watcher script (PID file is already removed by stop_watcher).
    rm -f "$STATE_DIR/gateway-watcher.sh"
    # After removing all proxy settings, verify direct internet works.
    # On phone hotspots that require Every Proxy, this will fail and we
    # should warn the user.
    if [[ "$NO_CHECK" == "false" ]]; then
      if ! check_connectivity; then
        notify_no_internet
      fi
    fi
    ;;
  gateway-change)
    cmd_gateway_change
    ;;
  start-watcher)
    start_watcher
    ;;
  stop-watcher)
    stop_watcher
    ;;
  *)
    echo "usage: proxy-manager.sh <status|enable|disable [--no-check]|gateway-change|start-watcher|stop-watcher>" >&2
    exit 1
    ;;
esac
