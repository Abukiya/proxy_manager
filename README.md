# Proxy Manager for Omarchy

Proxy Manager gives Omarchy a simple switch for networks where internet
access must go through a local proxy, such as a phone hotspot running a proxy
service. It replaces the need to maintain separate shell commands for each
tool you use.

Enable it from the Proxy icon in the bar or from the command line. Proxy
Manager applies the setting to your development tools, terminals, browsers,
and package managers, then removes those settings cleanly when you disable it.

## Highlights

- Detects the current hotspot gateway automatically.
- Reapplies the proxy when the hotspot gateway changes.
- Provides a bar indicator, panel, and command-line interface.
- Supports environment variables, Git, npm, Yarn, pip, curl, browsers,
  VS Code, and optional pacman/yay support.
- Preserves unrelated configuration wherever it makes changes.
- Works without root for the main user-level features.

Hermes CLI/Desktop proxy support is intentionally deferred and is not included
in this release.

## Requirements

Proxy Manager is designed for Omarchy and requires:

- `omarchy`
- `omarchy-shell`
- Bash
- `jq`
- `ip` from `iproute2`

Root access is optional. A normal install provides the user plugin. A
root-assisted install also adds the optional NetworkManager gateway hook,
pacman/yay support, and its hardened helper.

## Install

From a checkout of this repository:

```sh
./install.sh
```

For the optional system integrations:

```sh
sudo ./install.sh
```

The installer copies the plugin into
`~/.config/omarchy/plugins/abukiya.proxy`, enables it, removes stale files
from older plugin versions, and reloads Omarchy. When run with `sudo`, it
still installs the user plugin into the invoking user's home rather than
`/root`.

Check that the plugin is available:

```sh
omarchy-shell abukiya.proxy status
```

## Use it

The Proxy icon appears on the right side of the Omarchy bar. Click it to open
the panel, then use the switch to enable or disable the proxy.

The same actions are available from the terminal:

```sh
omarchy-shell abukiya.proxy status
omarchy-shell abukiya.proxy enable
omarchy-shell abukiya.proxy disable
omarchy-shell abukiya.proxy toggle
```

On first enable, the gateway is detected from the active default route. The
panel shows the configured endpoint and the integrations currently active.

## Updating

After changing files in `plugin/`, update the live plugin copy with:

```sh
./sync.sh
```

This replaces the copied plugin directory and reloads the Omarchy shell
without changing your proxy settings. Run `./install.sh` again when updating
the optional system components installed by the root-assisted install.

## Configuration

The user configuration is stored at:

```text
~/.config/omarchy/proxy.json
```

Example:

```json
{
  "httpProxy": "http://192.168.1.1:8080",
  "httpsProxy": "http://192.168.1.1:8080",
  "noProxy": "localhost,127.0.0.1,::1",
  "integrations": ["env", "git", "npm", "yarn", "pip", "curl", "pacman", "browser", "vscode"],
  "gatewayAuto": true,
  "port": 8080,
  "enabled": false
}
```

Most users only need to change `integrations` or `port`:

- `gatewayAuto` refreshes the proxy endpoint from the current network route.
- `port` selects the proxy service port and must be between 1 and 65535.
- `integrations` controls which tools Proxy Manager configures.

Invalid JSON or invalid integration data is rejected with an explicit error
instead of being applied partially.

## When the gateway changes

Proxy Manager watches the default gateway and updates the endpoint
automatically. New terminals, browser windows, Git, pip, and curl use the new
endpoint without manual changes.

Some applications cache proxy settings when they start. Restart VS Code and
npm-related processes after a gateway change if they still use the old
endpoint. Existing terminal and browser processes may also need restarting.

If disabling the proxy leaves you without internet, Proxy Manager shows a
notification. This usually means the phone hotspot requires its proxy service
to remain enabled.

## Remove it

First clean up the settings it applied:

```sh
omarchy-shell abukiya.proxy disable
```

Then disable and remove the plugin:

```sh
omarchy plugin disable abukiya.proxy
rm -rf ~/.config/omarchy/plugins/abukiya.proxy
```

If you installed the optional root components, remove those through your
system's normal administrative process as described in `NOTES.md`.

## Testing

Maintainers can run the complete local validation suite with:

```sh
./check.sh
```

This checks shell syntax, sample JSON, and all 77 isolated Bats tests. The
tests use temporary directories and stubs; they do not modify your real proxy,
Omarchy, systemd, NetworkManager, or global tool configuration.

## More detail

Technical implementation details, historical context, runtime files,
troubleshooting notes, and maintainer guidance are kept in
[NOTES.md](NOTES.md).
