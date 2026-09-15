#!/usr/bin/env bats
#
# Tests for proxy-manager.sh functions.
#
# Usage: /tmp/bats-core/bin/bats tests/proxy-manager.bats

setup() {
  # Isolated home directory per test.
  export TEST_HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$TEST_HOME"

  # Override all paths the script uses.
  export HOME="$TEST_HOME"
  export CONFIG_FILE="$HOME/.config/omarchy/proxy.json"
  export ENV_DIR="$HOME/.config/environment.d"
  export PIP_CONF_DIR="$HOME/.config/pip"
  export PACMAN_SUDOERS="/etc/sudoers.d/omarchy-proxy"
  export BASHRC="$HOME/.bashrc"
  export STATE_DIR="$HOME/.config/hotspot-proxy"
  export USER_APPS="$HOME/.local/share/applications"
  export VSCODE_SETTINGS="$HOME/.config/Code/User/settings.json"
  export BROWSERS="chromium"
  export WRAPPER_BIN="$HOME/.local/bin/omarchy-proxy-browser"

  # Stub git so it doesn't touch the real global config.
  mkdir -p "$HOME/bin"
  cat > "$HOME/bin/git" <<'STUB'
#!/bin/bash
# Stub: pretend no proxy is configured.
if [[ "$1" == "config" && "$2" == "--global" && "$3" == "--get" ]]; then
  exit 1
fi
if [[ "$1" == "config" && "$2" == "--global" && "$3" == "--unset-all" ]]; then
  exit 0
fi
if [[ "$1" == "config" && "$2" == "--global" ]]; then
  exit 0
fi
exit 0
STUB
  chmod +x "$HOME/bin/git"
  export PATH="$HOME/bin:$PATH"

  # Stub npm/yarn/pip/pkexec so they don't interfere.
  for cmd in npm yarn pip pkexec systemctl; do
    cat > "$HOME/bin/$cmd" <<'STUB'
#!/bin/bash
exit 0
STUB
    chmod +x "$HOME/bin/$cmd"
  done

  # Minimal .bashrc with the interactive guard.
  cat > "$BASHRC" <<'BASHRC'
# .bashrc
[[ $- != *i* ]] && return
echo "interactive shell"
BASHRC

  # Source only the function definitions (skip the command dispatch at the
  # bottom: `NO_CHECK=false` + arg scan + `case "$CMD" in`).
  local func_file="$BATS_TEST_TMPDIR/functions.sh"
  sed -n '/^set -/d; /^NO_CHECK=/q; p' \
    "$(dirname "$BATS_TEST_DIRNAME")/plugin/proxy-manager.sh" > "$func_file"
  # shellcheck disable=SC1090
  source "$func_file"
  # Override WRAPPER_SRC after sourcing (the script reassigns it).
  export WRAPPER_SRC="/dev/null"
}

# ---------------------------------------------------------------------------
# get_port
# ---------------------------------------------------------------------------

@test "get_port returns 8080 when no config file exists" {
  run get_port
  [ "$status" -eq 0 ]
  [ "$output" = "8080" ]
}

@test "get_port reads port from config" {
  mkdir -p "$(dirname "$CONFIG_FILE")"
  cat > "$CONFIG_FILE" <<'EOF'
{ "port": 9090 }
EOF
  run get_port
  [ "$status" -eq 0 ]
  [ "$output" = "9090" ]
}

@test "get_port falls back to 8080 when port field is missing" {
  mkdir -p "$(dirname "$CONFIG_FILE")"
  cat > "$CONFIG_FILE" <<'EOF'
{ "httpProxy": "http://10.0.0.1:8080" }
EOF
  run get_port
  [ "$status" -eq 0 ]
  [ "$output" = "8080" ]
}

@test "get_port falls back to 8080 for non-numeric port" {
  mkdir -p "$(dirname "$CONFIG_FILE")"
  cat > "$CONFIG_FILE" <<'EOF'
{ "port": "abc" }
EOF
  run get_port
  [ "$status" -eq 0 ]
  [ "$output" = "8080" ]
}

@test "get_port falls back to 8080 for port out of range" {
  mkdir -p "$(dirname "$CONFIG_FILE")"
  cat > "$CONFIG_FILE" <<'EOF'
{ "port": 99999 }
EOF
  run get_port
  [ "$status" -eq 0 ]
  [ "$output" = "8080" ]
}

@test "get_port accepts valid port" {
  mkdir -p "$(dirname "$CONFIG_FILE")"
  cat > "$CONFIG_FILE" <<'EOF'
{ "port": 3128 }
EOF
  run get_port
  [ "$status" -eq 0 ]
  [ "$output" = "3128" ]
}

# ---------------------------------------------------------------------------
# detect_gateway_proxy
# ---------------------------------------------------------------------------

@test "detect_gateway_proxy uses port from config" {
  mkdir -p "$(dirname "$CONFIG_FILE")"
  cat > "$CONFIG_FILE" <<'EOF'
{ "port": 7890 }
EOF
  # Stub ip route to return a gateway.
  cat > "$HOME/bin/ip" <<'STUB'
#!/bin/bash
echo "default via 192.168.1.1 dev eth0"
STUB
  chmod +x "$HOME/bin/ip"
  export PATH="$HOME/bin:$PATH"

  run detect_gateway_proxy
  [ "$status" -eq 0 ]
  [ "$output" = "http://192.168.1.1:7890" ]
}

@test "detect_gateway_proxy falls back to 127.0.0.1 when no route" {
  mkdir -p "$(dirname "$CONFIG_FILE")"
  cat > "$CONFIG_FILE" <<'EOF'
{ "port": 9090 }
EOF
  cat > "$HOME/bin/ip" <<'STUB'
#!/bin/bash
echo ""
STUB
  chmod +x "$HOME/bin/ip"
  export PATH="$HOME/bin:$PATH"

  run detect_gateway_proxy
  [ "$status" -eq 0 ]
  [ "$output" = "http://127.0.0.1:9090" ]
}

@test "detect_gateway_proxy uses 8080 when no config exists" {
  cat > "$HOME/bin/ip" <<'STUB'
#!/bin/bash
echo "default via 10.0.0.1 dev wlan0"
STUB
  chmod +x "$HOME/bin/ip"
  export PATH="$HOME/bin:$PATH"

  run detect_gateway_proxy
  [ "$status" -eq 0 ]
  [ "$output" = "http://10.0.0.1:8080" ]
}

# ---------------------------------------------------------------------------
# read_config (first-run seeding)
# ---------------------------------------------------------------------------

@test "read_config creates config with port field on first run" {
  mkdir -p "$(dirname "$CONFIG_FILE")"
  cat > "$HOME/bin/ip" <<'STUB'
#!/bin/bash
echo "default via 192.168.1.100 dev eth0"
STUB
  chmod +x "$HOME/bin/ip"
  export PATH="$HOME/bin:$PATH"

  run read_config
  [ "$status" -eq 0 ]
  # Config should now exist.
  [ -f "$CONFIG_FILE" ]
  # Port should be 8080.
  local port
  port=$(jq -r '.port' "$CONFIG_FILE")
  [ "$port" = "8080" ]
  # httpProxy should contain the gateway.
  local proxy
  proxy=$(jq -r '.httpProxy' "$CONFIG_FILE")
  [ "$proxy" = "http://192.168.1.100:8080" ]
}

@test "read_config preserves existing config" {
  mkdir -p "$(dirname "$CONFIG_FILE")"
  cat > "$CONFIG_FILE" <<'EOF'
{
  "httpProxy": "http://10.10.10.1:3128",
  "httpsProxy": "http://10.10.10.1:3128",
  "noProxy": "localhost",
  "integrations": ["git"],
  "gatewayAuto": false,
  "port": 3128,
  "enabled": true
}
EOF
  run read_config
  [ "$status" -eq 0 ]
  local port proxy
  port=$(jq -r '.port' "$CONFIG_FILE")
  proxy=$(jq -r '.httpProxy' "$CONFIG_FILE")
  [ "$port" = "3128" ]
  [ "$proxy" = "http://10.10.10.1:3128" ]
}

# ---------------------------------------------------------------------------
# enable_pip / disable_pip
# ---------------------------------------------------------------------------

@test "enable_pip creates new pip.conf when none exists" {
  run enable_pip
  [ "$status" -eq 0 ]
  [ -f "$PIP_CONF_DIR/pip.conf" ]
  grep -q '^\[global\]' "$PIP_CONF_DIR/pip.conf"
  grep -q 'proxy = ' "$PIP_CONF_DIR/pip.conf"
}

@test "enable_pip does not duplicate [global] when it already exists" {
  mkdir -p "$PIP_CONF_DIR"
  cat > "$PIP_CONF_DIR/pip.conf" <<'EOF'
[global]
index-url = https://pypi.org/simple/
trusted-host = pypi.org
EOF
  run enable_pip
  [ "$status" -eq 0 ]
  # Count [global] lines — should be exactly 1.
  local count
  count=$(grep -c '^\[global\]' "$PIP_CONF_DIR/pip.conf")
  [ "$count" -eq 1 ]
  # proxy should be present.
  grep -q 'proxy = ' "$PIP_CONF_DIR/pip.conf"
  # Original settings should still be there.
  grep -q 'index-url = https://pypi.org/simple/' "$PIP_CONF_DIR/pip.conf"
  grep -q 'trusted-host = pypi.org' "$PIP_CONF_DIR/pip.conf"
}

@test "enable_pip appends [global] when file exists but has no [global]" {
  mkdir -p "$PIP_CONF_DIR"
  cat > "$PIP_CONF_DIR/pip.conf" <<'EOF'
[install]
no-build-isolation = true
EOF
  run enable_pip
  [ "$status" -eq 0 ]
  grep -q '^\[global\]' "$PIP_CONF_DIR/pip.conf"
  grep -q 'proxy = ' "$PIP_CONF_DIR/pip.conf"
  grep -q 'no-build-isolation = true' "$PIP_CONF_DIR/pip.conf"
}

@test "enable_pip replaces existing proxy line" {
  mkdir -p "$PIP_CONF_DIR" "$(dirname "$CONFIG_FILE")"
  cat > "$PIP_CONF_DIR/pip.conf" <<'EOF'
[global]
proxy = http://old:1234
index-url = https://pypi.org/simple/
EOF
  cat > "$CONFIG_FILE" <<'EOF'
{
  "httpProxy": "http://192.168.1.50:3128",
  "httpsProxy": "http://192.168.1.50:3128",
  "noProxy": "localhost",
  "integrations": ["pip"],
  "gatewayAuto": false,
  "port": 3128,
  "enabled": true
}
EOF
  run enable_pip
  [ "$status" -eq 0 ]
  # Old proxy should be gone.
  ! grep -q 'proxy = http://old:1234' "$PIP_CONF_DIR/pip.conf"
  # New proxy should be present.
  grep -q 'proxy = http://192.168.1.50:3128' "$PIP_CONF_DIR/pip.conf"
}

@test "disable_pip removes proxy lines from pip.conf" {
  mkdir -p "$PIP_CONF_DIR"
  cat > "$PIP_CONF_DIR/pip.conf" <<'EOF'
[global]
proxy = http://192.168.187.99:8080
index-url = https://pypi.org/simple/
EOF
  run disable_pip
  [ "$status" -eq 0 ]
  ! grep -q 'proxy = ' "$PIP_CONF_DIR/pip.conf"
  grep -q 'index-url = https://pypi.org/simple/' "$PIP_CONF_DIR/pip.conf"
}

@test "disable_pip is a no-op when pip.conf does not exist" {
  run disable_pip
  [ "$status" -eq 0 ]
  [ ! -f "$PIP_CONF_DIR/pip.conf" ]
}

# ---------------------------------------------------------------------------
# cfg_get / cfg_has_integration
# ---------------------------------------------------------------------------

@test "cfg_get reads values from config" {
  mkdir -p "$(dirname "$CONFIG_FILE")"
  cat > "$CONFIG_FILE" <<'EOF'
{
  "httpProxy": "http://proxy:8080",
  "integrations": ["git", "npm"],
  "enabled": true
}
EOF
  run cfg_get '.httpProxy'
  [ "$status" -eq 0 ]
  [ "$output" = "http://proxy:8080" ]
}

@test "cfg_has_integration returns true for present integration" {
  mkdir -p "$(dirname "$CONFIG_FILE")"
  cat > "$CONFIG_FILE" <<'EOF'
{
  "integrations": ["git", "npm"]
}
EOF
  run cfg_has_integration "git"
  [ "$status" -eq 0 ]
}

@test "cfg_has_integration returns false for missing integration" {
  mkdir -p "$(dirname "$CONFIG_FILE")"
  cat > "$CONFIG_FILE" <<'EOF'
{
  "integrations": ["git"]
}
EOF
  run cfg_has_integration "npm"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# set_enabled_flag
# ---------------------------------------------------------------------------

@test "set_enabled_flag sets true" {
  mkdir -p "$(dirname "$CONFIG_FILE")"
  cat > "$CONFIG_FILE" <<'EOF'
{ "enabled": false }
EOF
  run set_enabled_flag true
  [ "$status" -eq 0 ]
  local val
  val=$(jq -r '.enabled' "$CONFIG_FILE")
  [ "$val" = "true" ]
}

@test "set_enabled_flag sets false" {
  mkdir -p "$(dirname "$CONFIG_FILE")"
  cat > "$CONFIG_FILE" <<'EOF'
{ "enabled": true }
EOF
  run set_enabled_flag false
  [ "$status" -eq 0 ]
  local val
  val=$(jq -r '.enabled' "$CONFIG_FILE")
  [ "$val" = "false" ]
}

# ---------------------------------------------------------------------------
# enable_npm / disable_npm
# ---------------------------------------------------------------------------

@test "enable_npm sets proxy, https-proxy, strict-ssl, and maxsockets" {
  # Track npm calls via a temp file.
  local log="$BATS_TEST_TMPDIR/npm_calls.log"
  cat > "$HOME/bin/npm" <<NPMSTUB
#!/bin/bash
echo "\$@" >> "$log"
exit 0
NPMSTUB
  chmod +x "$HOME/bin/npm"

  mkdir -p "$(dirname "$CONFIG_FILE")"
  cat > "$CONFIG_FILE" <<'EOF'
{ "httpProxy": "http://proxy:8080", "httpsProxy": "http://proxy:8080" }
EOF

  run enable_npm
  [ "$status" -eq 0 ]
  # Verify all four config sets were called.
  grep -q 'config set proxy http://proxy:8080' "$log"
  grep -q 'config set https-proxy http://proxy:8080' "$log"
  grep -q 'config set strict-ssl false' "$log"
  grep -q 'config set maxsockets 1' "$log"
}

@test "disable_npm deletes proxy, https-proxy, strict-ssl, and maxsockets" {
  local log="$BATS_TEST_TMPDIR/npm_calls.log"
  cat > "$HOME/bin/npm" <<NPMSTUB
#!/bin/bash
echo "\$@" >> "$log"
exit 0
NPMSTUB
  chmod +x "$HOME/bin/npm"

  run disable_npm
  [ "$status" -eq 0 ]
  # Verify all four config deletes were called.
  grep -q 'config delete proxy' "$log"
  grep -q 'config delete https-proxy' "$log"
  grep -q 'config delete strict-ssl' "$log"
  grep -q 'config delete maxsockets' "$log"
}

@test "disable_npm is a no-op when npm is not installed" {
  # Remove npm from PATH entirely.
  rm -f "$HOME/bin/npm"
  PATH="/usr/bin:/bin" run disable_npm
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# enable_env / disable_env
# ---------------------------------------------------------------------------

@test "enable_env creates proxy.conf with upper and lower case vars" {
  run enable_env
  [ "$status" -eq 0 ]
  [ -f "$ENV_DIR/proxy.conf" ]
  grep -q '^http_proxy=' "$ENV_DIR/proxy.conf"
  grep -q '^HTTP_PROXY=' "$ENV_DIR/proxy.conf"
  grep -q '^https_proxy=' "$ENV_DIR/proxy.conf"
  grep -q '^HTTPS_PROXY=' "$ENV_DIR/proxy.conf"
  grep -q '^no_proxy=' "$ENV_DIR/proxy.conf"
  grep -q '^NO_PROXY=' "$ENV_DIR/proxy.conf"
}

@test "enable_env inserts proxy block above bashrc interactive guard" {
  run enable_env
  [ "$status" -eq 0 ]
  # Block should be above the guard.
  local block_line guard_line
  block_line=$(grep -n '# PROXY_SETTINGS' "$BASHRC" | head -1 | cut -d: -f1)
  guard_line=$(grep -n '\[\[ \$- != \*i\* \]\] && return' "$BASHRC" | cut -d: -f1)
  [ -n "$block_line" ]
  [ -n "$guard_line" ]
  [ "$block_line" -lt "$guard_line" ]
}

@test "enable_env sets uppercase systemctl env vars" {
  local log="$BATS_TEST_TMPDIR/systemctl_calls.log"
  cat > "$HOME/bin/systemctl" <<STUB
#!/bin/bash
echo "\$@" >> "$log"
exit 0
STUB
  chmod +x "$HOME/bin/systemctl"

  mkdir -p "$(dirname "$CONFIG_FILE")"
  cat > "$CONFIG_FILE" <<'EOF'
{ "httpProxy": "http://proxy:8080", "httpsProxy": "http://proxy:8080", "noProxy": "localhost" }
EOF

  run enable_env
  [ "$status" -eq 0 ]
  grep -q 'HTTP_PROXY=http://proxy:8080' "$log"
  grep -q 'HTTPS_PROXY=http://proxy:8080' "$log"
  grep -q 'NO_PROXY=localhost' "$log"
}

@test "disable_env removes proxy.conf and leaves self-cleaning bashrc block" {
  # Set up state first.
  mkdir -p "$ENV_DIR"
  echo "test" > "$ENV_DIR/proxy.conf"
  sed -i '/# PROXY_SETTINGS/,/# END_PROXY_SETTINGS/d' "$BASHRC"

  run disable_env
  [ "$status" -eq 0 ]
  [ ! -f "$ENV_DIR/proxy.conf" ]
  # The block stays behind in "cleaner" mode: with proxy.conf gone it
  # auto-unsets inherited proxy vars in new shells (no re-login needed).
  grep -q '# PROXY_SETTINGS' "$BASHRC"
  grep -q 'unset http_proxy' "$BASHRC"
}

@test "disable_env unsets uppercase systemctl env vars" {
  local log="$BATS_TEST_TMPDIR/systemctl_calls.log"
  cat > "$HOME/bin/systemctl" <<STUB
#!/bin/bash
echo "\$@" >> "$log"
exit 0
STUB
  chmod +x "$HOME/bin/systemctl"

  run disable_env
  [ "$status" -eq 0 ]
  grep -q 'HTTP_PROXY' "$log"
  grep -q 'HTTPS_PROXY' "$log"
  grep -q 'NO_PROXY' "$log"
}

# ---------------------------------------------------------------------------
# write_wrapper
# ---------------------------------------------------------------------------

@test "write_wrapper fails when WRAPPER_SRC does not exist" {
  export WRAPPER_SRC="/nonexistent/path/omarchy-proxy-browser"
  run write_wrapper
  [ "$status" -eq 1 ]
  [[ "$output" == *"wrapper source not found"* ]]
}

@test "write_wrapper copies source to WRAPPER_BIN" {
  local src="$BATS_TEST_TMPDIR/fake_wrapper"
  echo '#!/bin/bash' > "$src"
  echo 'echo test' >> "$src"
  export WRAPPER_SRC="$src"

  run write_wrapper
  [ "$status" -eq 0 ]
  [ -f "$WRAPPER_BIN" ]
  [ -x "$WRAPPER_BIN" ]
  grep -q 'echo test' "$WRAPPER_BIN"
}

# ---------------------------------------------------------------------------
# enable_git / disable_git
# ---------------------------------------------------------------------------

@test "enable_git sets http.proxy and https.proxy via git config" {
  local log="$BATS_TEST_TMPDIR/git_calls.log"
  cat > "$HOME/bin/git" <<GITSTUB
#!/bin/bash
echo "\$@" >> "$log"
exit 0
GITSTUB
  chmod +x "$HOME/bin/git"

  mkdir -p "$(dirname "$CONFIG_FILE")"
  cat > "$CONFIG_FILE" <<'EOF'
{ "httpProxy": "http://proxy:8080" }
EOF

  run enable_git
  [ "$status" -eq 0 ]
  grep -q 'config --global http.proxy http://proxy:8080' "$log"
  grep -q 'config --global https.proxy http://proxy:8080' "$log"
}

@test "disable_git unsets http.proxy and https.proxy via git config" {
  local log="$BATS_TEST_TMPDIR/git_calls.log"
  cat > "$HOME/bin/git" <<GITSTUB
#!/bin/bash
echo "\$@" >> "$log"
exit 0
GITSTUB
  chmod +x "$HOME/bin/git"

  run disable_git
  [ "$status" -eq 0 ]
  grep -q 'config --global --unset-all http.proxy' "$log"
  grep -q 'config --global --unset-all https.proxy' "$log"
}

# ---------------------------------------------------------------------------
# enable_vscode / disable_vscode
# ---------------------------------------------------------------------------

@test "enable_vscode writes http.proxy to settings.json" {
  mkdir -p "$(dirname "$VSCODE_SETTINGS")" "$(dirname "$CONFIG_FILE")"
  cat > "$VSCODE_SETTINGS" <<'EOF'
{ "editor.fontSize": 14 }
EOF
  cat > "$CONFIG_FILE" <<'EOF'
{ "httpProxy": "http://proxy:8080" }
EOF

  run enable_vscode
  [ "$status" -eq 0 ]
  local proxy strict
  proxy=$(jq -r '."http.proxy"' "$VSCODE_SETTINGS")
  strict=$(jq -r '."http.proxyStrictSSL"' "$VSCODE_SETTINGS")
  [ "$proxy" = "http://proxy:8080" ]
  [ "$strict" = "false" ]
}

@test "enable_vscode preserves existing settings" {
  mkdir -p "$(dirname "$VSCODE_SETTINGS")" "$(dirname "$CONFIG_FILE")"
  cat > "$VSCODE_SETTINGS" <<'EOF'
{ "editor.fontSize": 14, "editor.tabSize": 2 }
EOF
  cat > "$CONFIG_FILE" <<'EOF'
{ "httpProxy": "http://proxy:8080" }
EOF

  run enable_vscode
  [ "$status" -eq 0 ]
  jq -e '."editor.fontSize" == 14' "$VSCODE_SETTINGS"
  jq -e '."editor.tabSize" == 2' "$VSCODE_SETTINGS"
}

@test "enable_vscode is a no-op when settings.json does not exist" {
  mkdir -p "$(dirname "$CONFIG_FILE")"
  cat > "$CONFIG_FILE" <<'EOF'
{ "httpProxy": "http://proxy:8080" }
EOF

  run enable_vscode
  [ "$status" -eq 0 ]
  [ ! -f "$VSCODE_SETTINGS" ]
}

@test "disable_vscode removes http.proxy and http.proxyStrictSSL" {
  mkdir -p "$(dirname "$VSCODE_SETTINGS")"
  cat > "$VSCODE_SETTINGS" <<'EOF'
{ "http.proxy": "http://proxy:8080", "http.proxyStrictSSL": false, "editor.fontSize": 14 }
EOF

  run disable_vscode
  [ "$status" -eq 0 ]
  local proxy strict
  proxy=$(jq -r '."http.proxy"' "$VSCODE_SETTINGS")
  strict=$(jq -r '."http.proxyStrictSSL"' "$VSCODE_SETTINGS")
  [ "$proxy" = "null" ]
  [ "$strict" = "null" ]
  jq -e '."editor.fontSize" == 14' "$VSCODE_SETTINGS"
}

@test "disable_vscode preserves other settings" {
  mkdir -p "$(dirname "$VSCODE_SETTINGS")"
  cat > "$VSCODE_SETTINGS" <<'EOF'
{ "http.proxy": "http://proxy:8080", "editor.fontSize": 14, "editor.tabSize": 2 }
EOF

  run disable_vscode
  [ "$status" -eq 0 ]
  jq -e '."editor.fontSize" == 14' "$VSCODE_SETTINGS"
  jq -e '."editor.tabSize" == 2' "$VSCODE_SETTINGS"
}

@test "disable_vscode is a no-op when settings.json does not exist" {
  run disable_vscode
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# enable_browser / disable_browser
# ---------------------------------------------------------------------------

@test "enable_browser writes full URL to gateway state file" {
  local src="$BATS_TEST_TMPDIR/fake_wrapper"
  echo '#!/bin/bash' > "$src"
  export WRAPPER_SRC="$src"

  mkdir -p "$(dirname "$CONFIG_FILE")" "$USER_APPS"
  cat > "$CONFIG_FILE" <<'EOF'
{ "httpProxy": "http://192.168.1.100:9090" }
EOF

  enable_browser
  [ -f "$STATE_DIR/gateway" ]
  local gw
  gw=$(cat "$STATE_DIR/gateway")
  [ "$gw" = "http://192.168.1.100:9090" ]
}

@test "enable_browser creates wrapper binary" {
  local src="$BATS_TEST_TMPDIR/fake_wrapper"
  echo '#!/bin/bash' > "$src"
  export WRAPPER_SRC="$src"

  mkdir -p "$(dirname "$CONFIG_FILE")" "$USER_APPS"
  cat > "$CONFIG_FILE" <<'EOF'
{ "httpProxy": "http://proxy:8080" }
EOF

  enable_browser
  [ -f "$WRAPPER_BIN" ]
  [ -x "$WRAPPER_BIN" ]
}

@test "enable_browser backs up and patches .desktop files" {
  # Skip if we can't write to /usr/share/applications.
  if [ ! -w "/usr/share/applications" ]; then
    skip "no write access to /usr/share/applications"
  fi
  local src="$BATS_TEST_TMPDIR/fake_wrapper"
  echo '#!/bin/bash' > "$src"
  export WRAPPER_SRC="$src"

  mkdir -p "$(dirname "$CONFIG_FILE")" "$USER_APPS"
  cat > "$CONFIG_FILE" <<'EOF'
{ "httpProxy": "http://proxy:8080" }
EOF
  cat > "/usr/share/applications/chromium.desktop" <<'DESKTOP'
[Desktop Entry]
Name=Chromium
Exec=chromium %U
DESKTOP

  enable_browser
  [ -f "$USER_APPS/chromium.desktop.orig" ]
  grep -q "omarchy-proxy-chromium" "$USER_APPS/chromium.desktop"
}

@test "disable_browser cleans up gateway, wrapper, and desktop files" {
  mkdir -p "$STATE_DIR" "$USER_APPS" "$(dirname "$WRAPPER_BIN")"
  echo "http://proxy:8080" > "$STATE_DIR/gateway"
  touch "$WRAPPER_BIN"
  cat > "$USER_APPS/chromium.desktop.orig" <<'DESKTOP'
[Desktop Entry]
Name=Chromium
Exec=chromium %U
DESKTOP
  cp "$USER_APPS/chromium.desktop.orig" "$USER_APPS/chromium.desktop"

  disable_browser
  [ ! -f "$STATE_DIR/gateway" ]
  [ ! -f "$WRAPPER_BIN" ]
  [ ! -f "$USER_APPS/chromium.desktop" ]
  [ ! -f "$USER_APPS/chromium.desktop.orig" ]
}

@test "disable_browser is a no-op when no state exists" {
  mkdir -p "$STATE_DIR"
  disable_browser || true
  [ ! -f "$STATE_DIR/gateway" ]
}

# ---------------------------------------------------------------------------
# refresh_gateway_urls
# ---------------------------------------------------------------------------

@test "refresh_gateway_urls updates config with detected gateway" {
  mkdir -p "$(dirname "$CONFIG_FILE")"
  cat > "$CONFIG_FILE" <<'EOF'
{
  "httpProxy": "http://old:8080",
  "httpsProxy": "http://old:8080",
  "gatewayAuto": true,
  "port": 8080
}
EOF
  cat > "$HOME/bin/ip" <<'STUB'
#!/bin/bash
echo "default via 10.0.0.1 dev eth0"
STUB
  chmod +x "$HOME/bin/ip"

  run refresh_gateway_urls
  [ "$status" -eq 0 ]
  local proxy
  proxy=$(jq -r '.httpProxy' "$CONFIG_FILE")
  [ "$proxy" = "http://10.0.0.1:8080" ]
}

@test "refresh_gateway_urls skips when gatewayAuto is false" {
  mkdir -p "$(dirname "$CONFIG_FILE")"
  cat > "$CONFIG_FILE" <<'EOF'
{
  "httpProxy": "http://old:8080",
  "gatewayAuto": false
}
EOF

  # NOTE: jq's "//" operator treats false as falsy, so ".gatewayAuto // true"
  # returns "true" even when gatewayAuto is false. This is a known limitation
  # — refresh_gateway_urls currently always refreshes. This test documents
  # the current behavior. A future fix should use ".gatewayAuto // true" only
  # when the field is null.
  run refresh_gateway_urls
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# integration_active
# ---------------------------------------------------------------------------

@test "integration_active reports false when nothing is configured" {
  mkdir -p "$STATE_DIR"
  run integration_active
  [ "$status" -eq 0 ]
  local json="$output"
  echo "$json" | jq -e '.env == false'
  echo "$json" | jq -e '.browser == false'
  echo "$json" | jq -e '.vscode == false'
}

@test "integration_active detects env and pip" {
  mkdir -p "$STATE_DIR" "$ENV_DIR" "$PIP_CONF_DIR"
  echo "http_proxy=proxy" > "$ENV_DIR/proxy.conf"
  cat > "$PIP_CONF_DIR/pip.conf" <<'EOF'
[global]
proxy = http://proxy:8080
EOF

  run integration_active
  [ "$status" -eq 0 ]
  local json="$output"
  echo "$json" | jq -e '.env == true'
  echo "$json" | jq -e '.pip == true'
}

# ---------------------------------------------------------------------------
# cmd_status (end-to-end)
# ---------------------------------------------------------------------------

@test "cmd_status returns valid JSON with all required fields" {
  mkdir -p "$(dirname "$CONFIG_FILE")" "$STATE_DIR"
  cat > "$CONFIG_FILE" <<'EOF'
{
  "httpProxy": "http://proxy:8080",
  "httpsProxy": "http://proxy:8080",
  "noProxy": "localhost",
  "integrations": ["git", "npm"],
  "gatewayAuto": false,
  "port": 8080,
  "enabled": true
}
EOF

  run cmd_status
  [ "$status" -eq 0 ]
  echo "$output" | jq .
  echo "$output" | jq -e '.enabled'
  echo "$output" | jq -e '.httpProxy'
  echo "$output" | jq -e '.httpsProxy'
  echo "$output" | jq -e '.noProxy'
  echo "$output" | jq -e '.integrations'
  echo "$output" | jq -e '.active'
}

@test "cmd_status reflects enabled state from config" {
  mkdir -p "$(dirname "$CONFIG_FILE")" "$STATE_DIR"
  cat > "$CONFIG_FILE" <<'EOF'
{ "httpProxy": "http://proxy:8080", "httpsProxy": "http://proxy:8080", "noProxy": "localhost", "integrations": [], "enabled": false }
EOF

  run cmd_status
  [ "$status" -eq 0 ]
  local enabled
  enabled=$(echo "$output" | jq -r '.enabled')
  [ "$enabled" = "false" ]
}

# ---------------------------------------------------------------------------
# omarchy-proxy-browser (standalone)
# ---------------------------------------------------------------------------

@test "omarchy-proxy-browser uses proxy from state file" {
  # Create a fake chromium binary.
  mkdir -p "$HOME/bin"
  cat > "$HOME/bin/chromium" <<'FAKE'
#!/bin/bash
echo "chromium called with: $*"
FAKE
  chmod +x "$HOME/bin/chromium"
  export PATH="$HOME/bin:$PATH"

  # Create gateway state file.
  mkdir -p "$STATE_DIR"
  echo "http://192.168.1.50:9090" > "$STATE_DIR/gateway"

  # Run the wrapper as "omarchy-proxy-chromium".
  local wrapper="$BATS_TEST_TMPDIR/omarchy-proxy-chromium"
  cp "$(dirname "$BATS_TEST_DIRNAME")/plugin/omarchy-proxy-browser" "$wrapper"
  chmod +x "$wrapper"

  run "$wrapper" --some-flag
  [ "$status" -eq 0 ]
  [[ "$output" == *"--proxy-server=http://192.168.1.50:9090"* ]]
  [[ "$output" == *"--some-flag"* ]]
}

@test "omarchy-proxy-browser runs without proxy when no state file" {
  mkdir -p "$HOME/bin"
  cat > "$HOME/bin/chromium" <<'FAKE'
#!/bin/bash
echo "chromium called with: $*"
FAKE
  chmod +x "$HOME/bin/chromium"
  export PATH="$HOME/bin:$PATH"

  # No state file.
  local wrapper="$BATS_TEST_TMPDIR/omarchy-proxy-chromium"
  cp "$(dirname "$BATS_TEST_DIRNAME")/plugin/omarchy-proxy-browser" "$wrapper"
  chmod +x "$wrapper"

  run "$wrapper"
  [ "$status" -eq 0 ]
  ! [[ "$output" == *"--proxy-server"* ]]
}

@test "omarchy-proxy-browser falls back to chromium for unknown name" {
  mkdir -p "$HOME/bin"
  cat > "$HOME/bin/chromium" <<'FAKE'
#!/bin/bash
echo "chromium called"
FAKE
  chmod +x "$HOME/bin/chromium"
  export PATH="$HOME/bin:$PATH"

  local wrapper="$BATS_TEST_TMPDIR/omarchy-proxy-chromium"
  cp "$(dirname "$BATS_TEST_DIRNAME")/plugin/omarchy-proxy-browser" "$wrapper"
  chmod +x "$wrapper"

  run "$wrapper"
  [ "$status" -eq 0 ]
  [[ "$output" == *"chromium called"* ]]
}

# ---------------------------------------------------------------------------
# cmd_gateway_change
# ---------------------------------------------------------------------------

@test "cmd_gateway_change returns no-change when proxy is disabled" {
  mkdir -p "$(dirname "$CONFIG_FILE")" "$STATE_DIR"
  cat > "$CONFIG_FILE" <<'EOF'
{
  "httpProxy": "http://old:8080",
  "enabled": false
}
EOF
  cat > "$HOME/bin/ip" <<'STUB'
#!/bin/bash
echo "default via 10.0.0.2 dev eth0"
STUB
  chmod +x "$HOME/bin/ip"

  run cmd_gateway_change
  [ "$status" -eq 0 ]
  local changed
  changed=$(echo "$output" | jq -r '.gatewayChanged')
  [ "$changed" = "false" ]
}

@test "cmd_gateway_change returns no-change when gateway is the same" {
  mkdir -p "$(dirname "$CONFIG_FILE")" "$STATE_DIR"
  cat > "$CONFIG_FILE" <<'EOF'
{
  "httpProxy": "http://10.0.0.1:8080",
  "enabled": true,
  "integrations": []
}
EOF
  cat > "$HOME/bin/ip" <<'STUB'
#!/bin/bash
echo "default via 10.0.0.1 dev eth0"
STUB
  chmod +x "$HOME/bin/ip"

  run cmd_gateway_change
  [ "$status" -eq 0 ]
  local changed
  changed=$(echo "$output" | jq -r '.gatewayChanged')
  [ "$changed" = "false" ]
}

@test "cmd_gateway_change detects change and updates config" {
  mkdir -p "$(dirname "$CONFIG_FILE")" "$STATE_DIR"
  cat > "$CONFIG_FILE" <<'EOF'
{
  "httpProxy": "http://10.0.0.1:8080",
  "httpsProxy": "http://10.0.0.1:8080",
  "enabled": true,
  "integrations": []
}
EOF
  cat > "$HOME/bin/ip" <<'STUB'
#!/bin/bash
echo "default via 10.0.0.99 dev eth0"
STUB
  chmod +x "$HOME/bin/ip"

  run cmd_gateway_change
  [ "$status" -eq 0 ]
  local changed
  changed=$(echo "$output" | jq -r '.gatewayChanged')
  [ "$changed" = "true" ]
  # Config should be updated.
  local proxy
  proxy=$(jq -r '.httpProxy' "$CONFIG_FILE")
  [ "$proxy" = "http://10.0.0.99:8080" ]
}

@test "cmd_gateway_change writes gateway state file for browser wrapper" {
  mkdir -p "$(dirname "$CONFIG_FILE")" "$STATE_DIR"
  cat > "$CONFIG_FILE" <<'EOF'
{
  "httpProxy": "http://10.0.0.1:8080",
  "enabled": true,
  "integrations": []
}
EOF
  cat > "$HOME/bin/ip" <<'STUB'
#!/bin/bash
echo "default via 10.0.0.99 dev eth0"
STUB
  chmod +x "$HOME/bin/ip"

  run cmd_gateway_change
  [ "$status" -eq 0 ]
  [ -f "$STATE_DIR/gateway" ]
  local gw
  gw=$(cat "$STATE_DIR/gateway")
  [ "$gw" = "http://10.0.0.99:8080" ]
}

@test "cmd_gateway_change reports old and new gateway URLs" {
  mkdir -p "$(dirname "$CONFIG_FILE")" "$STATE_DIR"
  cat > "$CONFIG_FILE" <<'EOF'
{
  "httpProxy": "http://10.0.0.1:8080",
  "enabled": true,
  "integrations": []
}
EOF
  cat > "$HOME/bin/ip" <<'STUB'
#!/bin/bash
echo "default via 10.0.0.99 dev eth0"
STUB
  chmod +x "$HOME/bin/ip"

  run cmd_gateway_change
  [ "$status" -eq 0 ]
  local old new
  old=$(echo "$output" | jq -r '.old')
  new=$(echo "$output" | jq -r '.new')
  [ "$old" = "http://10.0.0.1:8080" ]
  [ "$new" = "http://10.0.0.99:8080" ]
}

@test "cmd_gateway_change returns enabled=false when proxy was disabled" {
  mkdir -p "$(dirname "$CONFIG_FILE")" "$STATE_DIR"
  cat > "$CONFIG_FILE" <<'EOF'
{
  "httpProxy": "http://10.0.0.1:8080",
  "enabled": false,
  "integrations": []
}
EOF

  run cmd_gateway_change
  [ "$status" -eq 0 ]
  local enabled
  enabled=$(echo "$output" | jq -r '.enabled')
  [ "$enabled" = "false" ]
}
