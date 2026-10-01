<div align="center">
  <img src="docs/proxy-icon.svg" alt="Proxy Manager icon" width="80" height="80">

  # Proxy Manager for Omarchy

  **A bar widget and command-line switch for local HTTP/HTTPS proxies**

  [![Omarchy plugin](https://img.shields.io/badge/Omarchy-plugin-7c3aed?style=flat-square)](https://omarchy.org/)
  [![Shell](https://img.shields.io/badge/Bash-4%2B-4EAA25?style=flat-square&logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
  [![Tests](https://img.shields.io/badge/tests-78-2ea44f?style=flat-square)](tests/proxy-manager.bats)

  [Install](#installation) · [Use](#usage) · [Configure](#configuration) · [Develop](#development)
</div>

Proxy Manager makes a phone hotspot or other local proxy service easy to use
from Omarchy. Enable it from the bar, from the panel, or with one command; it
then configures the tools that need the proxy and removes those settings when
you disable it.

> [!NOTE]
> This plugin is designed for [Omarchy](https://omarchy.org/) and is not a
> general-purpose proxy daemon. The proxy service itself must already be
> reachable through the active network gateway.

## Features

- Detects the active default-route gateway and builds the proxy URL.
- Watches for gateway changes and reapplies enabled integrations automatically.
- Provides an Omarchy bar indicator, panel, and IPC-backed CLI.
- Integrates environment variables, Git, npm, Yarn, pip, curl, browsers,
  VS Code, and optional pacman/yay support.
- Preserves unrelated configuration and removes only the settings it owns.
- Runs the main user-level workflow without root access.
- Reports status as JSON for the UI and scripts.

Hermes CLI/Desktop proxy support is intentionally not included in this
release.

## Requirements

- Omarchy with `omarchy` and `omarchy-shell`
- Bash
- `jq`
- `ip` from `iproute2`

The optional system integration setup additionally uses `sudo`, polkit, and
NetworkManager's dispatcher directory when those components are available.

## Installation

### Recommended: Omarchy plugin manager

```sh
omarchy plugin add https://github.com/Abukiya/proxy_manager.git --enable
```

This installs the plugin as a real directory at
`~/.config/omarchy/plugins/abukiya.proxy`. No root access is required for the
user-level integrations.

### Optional system integrations

From a local checkout, explicitly install the privileged pieces only if you
need pacman/yay support or the NetworkManager gateway hook:

```sh
sudo ./setup-system-integrations.sh
```

This installs a polkit rule, a root-owned sudoers helper, and the optional
NetworkManager dispatcher. It is separate from `omarchy plugin add` and is
never run implicitly.

### Local checkout

For local development, `install.sh` copies the repository into Omarchy's live
plugin directory and enables it:

```sh
./install.sh
omarchy-shell abukiya.proxy status
```

## Usage

Click the **Proxy** icon on the right side of the Omarchy bar to open the
panel. Use the switch to enable or disable the proxy. The panel shows the
current endpoint and the integrations that are active.

The same operations are available from a terminal:

```sh
omarchy-shell abukiya.proxy status
omarchy-shell abukiya.proxy enable
omarchy-shell abukiya.proxy disable
omarchy-shell abukiya.proxy toggle
```

`status` prints JSON, which makes it suitable for scripts:

```sh
omarchy-shell abukiya.proxy status | jq '{enabled, httpProxy, active}'
```

When enabled, the plugin detects the current gateway. If the gateway changes,
the background watcher updates the endpoint and reapplies the configured
integrations. New terminals, browser windows, Git, pip, and curl pick up the
new endpoint automatically. Restart VS Code and npm-related processes if they
continue using a cached endpoint.

> [!WARNING]
> Disabling the proxy starts a connectivity check in the background. If the
> hotspot only provides internet while its proxy service is running, Omarchy
> will notify you that direct connectivity is unavailable.

## Configuration

Configuration is stored outside the repository at
`~/.config/omarchy/proxy.json`. The first enable creates it automatically.
A complete example is available at [`docs/proxy.json`](docs/proxy.json).

```json
{
  "httpProxy": "http://192.168.1.1:8080",
  "httpsProxy": "http://192.168.1.1:8080",
  "noProxy": "localhost,127.0.0.1,::1",
  "integrations": ["env", "git", "npm", "yarn", "pip", "curl", "browser", "vscode"],
  "gatewayAuto": true,
  "port": 8080,
  "enabled": false
}
```

| Setting | Description |
| --- | --- |
| `gatewayAuto` | Refresh `httpProxy` and `httpsProxy` from the active gateway before enabling and when it changes. |
| `port` | Proxy service port, from `1` through `65535`. |
| `integrations` | Tools to configure. Supported values are `env`, `git`, `npm`, `yarn`, `pip`, `curl`, `pacman`, `browser`, and `vscode`. |
| `noProxy` | Comma-separated hosts that bypass the proxy. |

Invalid JSON or invalid integration data is rejected with an explicit error;
the plugin does not apply a partial configuration.

## Updating and removing

Update an Omarchy-managed installation with:

```sh
omarchy plugin update abukiya.proxy --yes
```

Clean up settings before removing the plugin:

```sh
omarchy-shell abukiya.proxy disable
omarchy plugin disable abukiya.proxy
rm -rf ~/.config/omarchy/plugins/abukiya.proxy
```

Removing the plugin does not remove privileged files installed by
`setup-system-integrations.sh`; remove those through your system's normal
administrative process.

## Project layout

| Path | Purpose |
| --- | --- |
| `manifest.json` | Omarchy plugin metadata and entry points. |
| `Service.qml` | IPC service that queues Bash operations and caches status. |
| `BarWidget.qml`, `Panel.qml`, `ProxyIcon.qml` | Bar indicator, control panel, and themed icon. |
| `proxy-manager.sh` | Configuration, integration, gateway watcher, and status logic. |
| `omarchy-proxy-browser` | Browser wrapper that reads the live gateway endpoint. |
| `setup-system-integrations.sh` | Explicit privileged integration installer. |
| `install.sh`, `sync.sh` | Local-checkout installation and development sync helpers. |
| `tests/proxy-manager.bats` | Isolated shell and integration tests. |
| `NOTES.md` | Maintainer notes, runtime files, design details, and troubleshooting history. |

The live plugin is a real copy rather than a symlink because Omarchy's QML
loader requires real plugin entry-point paths. `sync.sh` replaces that copy
and reloads the shell during local development.

## Development

Run the release checks from the repository root:

```sh
./check.sh
```

The check validates shell syntax, parses the sample JSON, and runs all 78 Bats
tests in temporary directories. The tests stub external commands and do not
modify your real proxy, Omarchy, systemd, NetworkManager, or global tool
configuration.

After changing plugin files in a local checkout:

```sh
./sync.sh
```

Re-run the optional system integration setup when changing its privileged
source files:

```sh
sudo ./setup-system-integrations.sh
```

For implementation details and known platform-specific behavior, see
[`NOTES.md`](NOTES.md).
