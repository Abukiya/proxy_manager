# abukiya.proxy — Omarchy proxy manager plugin

Background service plugin for Omarchy that replaces the old ad-hoc
`setproxy.sh` / `clearproxy.sh` scripts. Toggles system proxy configuration
for a phone-hotspot gateway, applied live and reachable from a bar widget and
panel.

## What it does

On `enable`, sets the proxy (auto-detected gateway) for:

- **env** — `~/.config/environment.d/proxy.conf` + a `# PROXY_SETTINGS` block
  in `~/.bashrc` + `systemctl --user set-environment` (both upper and lower case)
- **git** — global `http.proxy` / `https.proxy`
- **npm** — `proxy`, `https-proxy`, `strict-ssl false`, `maxsockets 1`
- **yarn** — `proxy`, `https-proxy` (if yarn installed)
- **pip** — `~/.config/pip/pip.conf`
- **browser** — user `.desktop` launchers routed through a per-browser wrapper
  (`~/.local/bin/omarchy-proxy-browser`) that reads the live gateway at launch
- **vscode** — `http.proxy` + `http.proxyStrictSSL` in `Code/User/settings.json`
- **pacman** — `/etc/sudoers.d/omarchy-proxy` env_keep so `sudo pacman`/`yay`
  keep the proxy vars (needs one-time pkexec auth)

`disable` reverts all of the above.

## Layout

```
proxy_manager/
  plugin/                 -> live plugin dir (copied into omarchy plugins)
    manifest.json
    Service.qml           IPC service (omarchy-shell abukiya.proxy ...)
    BarWidget.qml         bar icon; left-click opens/closes the panel
    Panel.qml             enable/disable switch + integration status rows
    proxy-manager.sh      all the logic
    omarchy-proxy-browser standalone browser wrapper script
  tests/
    proxy-manager.bats    bats test suite (54 tests)
  install.sh              (re)install: copy + enable
  sync.sh                 re-sync plugin/ to the live dir after edits
  docs/
    omarchy-menu.jsonc    note: menu integration removed (see file)
    proxy.json            sample config
  README.md
```

> The live plugin dir is a real **copy**, not a symlink. Qt QML refuses to
> load `bar-widget`/`panel` entry points through a symlinked directory
> ("File name case mismatch"). After editing files in `plugin/`, run
> `./sync.sh` to copy them over and hot-reload the shell.

## Install

```sh
./install.sh
```

This copies `plugin/` to `~/.config/omarchy/plugins/abukiya.proxy` (a real
directory — see layout note above) and re-enables the plugin. Afterwards:

```sh
omarchy-shell shell rescanPlugins
omarchy-shell abukiya.proxy status
```

## Usage

Bar widget (right side): the **󰓓 Proxy** icon shows proxy state (accent =
enabled). Left-click opens/closes the proxy panel; the proxy itself is toggled
from the panel's Enable/Disable switch. The panel also shows status rows for
git, npm, yarn, pip, VSCode, browser, and pacman integrations, and the
configured endpoint.

CLI:

```sh
omarchy-shell abukiya.proxy status   # JSON: enabled, proxy, active integrations
omarchy-shell abukiya.proxy enable
omarchy-shell abukiya.proxy disable
omarchy-shell abukiya.proxy toggle
```

Config lives in `~/.config/omarchy/proxy.json`:

```json
{
  "httpProxy": "http://192.168.1.1:8080",
  "httpsProxy": "http://192.168.1.1:8080",
  "noProxy": "localhost,127.0.0.1,::1",
  "integrations": ["env", "git", "npm", "pip", "pacman", "browser", "vscode"],
  "gatewayAuto": true,
  "port": 8080,
  "enabled": true
}
```

- `gatewayAuto: true` re-detects the gateway on every enable.
- `port` controls the proxy port (default `8080`). Must be 1-65535.
- `integrations` controls which tools are configured.

## Testing

The project includes a bats test suite with 54 tests covering all functions:

```sh
# Install bats if not present.
git clone --depth 1 https://github.com/bats-core/bats-core.git /tmp/bats-core

# Run all tests.
/tmp/bats-core/bin/bats tests/proxy-manager.bats
```

Tests use isolated temp directories and stub commands — no system state is
modified. Coverage includes: config management, all integration enable/disable
functions, the browser wrapper standalone script, and end-to-end status output.

## Removal

1. Revert first: `omarchy-shell abukiya.proxy disable` (cleans all integrations).
2. Then disable the plugin: `omarchy plugin disable abukiya.proxy`.
3. Delete `~/.config/omarchy/plugins/abukiya.proxy` (the copied plugin dir) and
   the repo.

## Gotchas (learned the hard way)

1. **`.bashrc` interactive guard** — the `# PROXY_SETTINGS` block MUST be
   inserted *above* `[[ $- != *i* ]] && return`. The menu launches terminals
   via non-interactive `bash -lc` (execDetached), so a block below the guard is
   never sourced and `sudo pacman -S` from Menu -> Install gets no `http_proxy`.
2. **`omarchy-launch-browser` strips Exec flags** — it reads only the first
   token of a `.desktop` `Exec=` line, so baking `--proxy-server=...` into
   launchers is pointless. Launchers route through `omarchy-proxy-<browser>`
   wrappers that add the flag at launch time.
3. **pacman must run last** in `apply()` — `enable_pacman` calls `pkexec`
   (modal polkit dialog) and would block the browser/env steps behind it.
4. **Status can lag ~2s** after toggle — the IPC `status` returns a cached
   snapshot refreshed asynchronously; system state is correct immediately.
5. **`/etc/sudoers.d` unreadable by the user** — existence checks use
   `pkexec test -f`, not `[[ -f ]]`, which always fails on the directory perms.