#!/bin/bash
#
# abukiya.proxy helper: apply / clear system proxy configuration.
#
# Usage: proxy-manager.sh <status|enable|disable>
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

get_port() {
  if [[ -f "$CONFIG_FILE" ]]; then
    jq -r '.port // 8080' "$CONFIG_FILE"
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
  auto=$(cfg_get '.gatewayAuto // true')
  if [[ "$auto" != "true" ]]; then
    return 0
  fi
  local url
  url=$(detect_gateway_proxy)
  read_config | jq --arg url "$url" '.httpProxy = $url | .httpsProxy = $url' > "$CONFIG_FILE.tmp"
  mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
}

# ----------------------------------------------------------------- env vars

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
  # Persist into ~/.bashrc exactly like setproxy.sh, so new terminals pick
  # the proxy up immediately instead of waiting for the next login.
  # CRITICAL: the block must go ABOVE the `.bashrc` interactive-shell guard
  # ([[ $- != *i* ]] && return). omarchy's menu/terminal launch scripts run
  # non-interactive shells (bash -lc via execDetached, foot -e), and a block
  # below the guard never gets sourced — so `sudo pacman -S` from the menu's
  # Install flow would have no http_proxy and fail on a hotspot-only network.
  sed -i '/# PROXY_SETTINGS/,/# END_PROXY_SETTINGS/d' "$BASHRC"
  awk -v block="$http|$https|$no" '
    BEGIN { split(block, a, "|") }
    /^\[\[ \$- != \*i\* \]\] && return/ {
      print "# PROXY_SETTINGS"
      print "export HTTP_PROXY=" a[1]
      print "export HTTPS_PROXY=" a[2]
      print "export http_proxy=" a[1]
      print "export https_proxy=" a[2]
      print "export NODE_USE_ENV_PROXY=1"
      print "# END_PROXY_SETTINGS"
      print ""
    }
    { print }
  ' "$BASHRC" > "$BASHRC.tmp"
  mv "$BASHRC.tmp" "$BASHRC"
  # Best effort for the running session's future systemd user services.
  systemctl --user set-environment \
    http_proxy="$http" HTTP_PROXY="$http" \
    https_proxy="$https" HTTPS_PROXY="$https" \
    no_proxy="$no" NO_PROXY="$no" 2>/dev/null || true
}

disable_env() {
  rm -f "$ENV_DIR/proxy.conf"
  sed -i '/# PROXY_SETTINGS/,/# END_PROXY_SETTINGS/d' "$BASHRC"
  systemctl --user unset-environment http_proxy HTTP_PROXY https_proxy HTTPS_PROXY no_proxy NO_PROXY 2>/dev/null || true
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

PACMAN_SUDOERS_EXISTS() {
  if [[ -f "$PACMAN_MARKER" ]]; then
    return 0
  fi
  # One-time probe: confirm the rule is really present and remember it so
  # later status calls are instant and context-independent.
  if timeout 5 pkexec sh -c 'test -f /etc/sudoers.d/omarchy-proxy' >/dev/null 2>&1; then
    : > "$PACMAN_MARKER"
    return 0
  fi
  return 1
}

enable_pacman() {
  if PACMAN_SUDOERS_EXISTS; then
    return 0
  fi
  local body='Defaults env_keep += "http_proxy https_proxy ftp_proxy no_proxy all_proxy"'
  if command -v pkexec >/dev/null 2>&1; then
    if printf '%s\n' "$body" | pkexec sh -c "cat > '$PACMAN_SUDOERS' && chmod 440 '$PACMAN_SUDOERS'" 2>/dev/null; then
      : > "$PACMAN_MARKER"
    else
      echo "warning: could not write $PACMAN_SUDOERS (needs pkexec auth)"
    fi
  else
    echo "warning: pkexec not available; skipping sudoers env_keep"
  fi
}

disable_pacman() {
  if PACMAN_SUDOERS_EXISTS; then
    if pkexec rm -f "$PACMAN_SUDOERS" 2>/dev/null; then
      rm -f "$PACMAN_MARKER"
    else
      echo "warning: could not remove $PACMAN_SUDOERS (needs pkexec auth)"
    fi
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
  sed -i "s|^Exec=\([^ ]*\)|Exec=$HOME/.local/bin/omarchy-proxy-${BROWSER_NAME} |" "$user_desktop"
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
  out+="\"pacman\":$(PACMAN_SUDOERS_EXISTS && echo true || echo false),"
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

case "${1:-status}" in
  status)
    cmd_status
    ;;
  enable)
    refresh_gateway_urls
    apply enable
    set_enabled_flag true
    cmd_status
    ;;
  disable)
    apply disable
    set_enabled_flag false
    cmd_status
    ;;
  *)
    echo "usage: proxy-manager.sh <status|enable|disable>" >&2
    exit 1
    ;;
esac
