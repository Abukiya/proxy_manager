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
  export WRAPPER_SRC="/dev/null"

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

  # Source only the function definitions (skip the case statement).
  local func_file="$BATS_TEST_TMPDIR/functions.sh"
  sed -n '1,/^case "${1:-status}"/{ /^set -/d; /^case /d; p; }' \
    "$(dirname "$BATS_TEST_DIRNAME")/plugin/proxy-manager.sh" > "$func_file"
  # shellcheck disable=SC1090
  source "$func_file"
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
