# Proxy Manager — Session Notes

What we built and everything we learned along the way. Read this to catch up.

## What this is

An Omarchy shell plugin (`abukiya.proxy`) that replaces your temporary
`setproxy.sh` / `clearproxy.sh`. It toggles system proxy config for a
phone-hotspot gateway, applied live, and is controlled from a **bar widget +
panel** (no more menu integration). The service is purely a state machine; the
UI is two QML files that call the same IPC commands you'd run by hand.

## Where everything lives

```
~/proxy_manager/                  <- this project (git repo)
  plugin/                         <- copied into omarchy as the live plugin
    manifest.json
    Service.qml                   IPC service (omarchy-shell abukiya.proxy ...)
    BarWidget.qml                 bar icon; click opens/closes the panel
    Panel.qml                     enable/disable switch + status rows
    proxy-manager.sh              all the logic
    omarchy-proxy-browser         standalone browser wrapper script
  tests/
    proxy-manager.bats            bats test suite (54 tests)
  install.sh                      (re)install: copy + enable
  sync.sh                         re-sync plugin/ to the live dir after edits
  docs/                           notes + sample config
  README.md                       install/usage/removal
  NOTES.md                        this file
~/.config/omarchy/plugins/abukiya.proxy   -> real copy of ~/proxy_manager/plugin
```

**The live dir is a real copy, NOT a symlink.** Qt QML refuses to load
`bar-widget`/`panel` entry points through a symlinked directory — it reports
"File name case mismatch" for every widget/panel component (services loaded
through the symlink still worked, which made this very confusing to debug).
After editing files in `plugin/`, run `./sync.sh` to copy them over and
hot-reload the shell.

The plugin's live config/state lives outside the repo:
- `~/.config/omarchy/proxy.json` — config (gatewayAuto, integrations, port, enabled)
- `~/.bashrc` — `# PROXY_SETTINGS` block
- `~/.config/environment.d/proxy.conf` — env vars for systemd user services
- `~/.local/share/applications/*.desktop` — browser launcher overrides (+ `.orig`)
- `~/.local/bin/omarchy-proxy-browser` + `omarchy-proxy-*` — browser wrappers
- `~/.config/hotspot-proxy/gateway` — live gateway state file (full URL with port)
- `/etc/sudoers.d/omarchy-proxy` — pacman/yay env_keep (via pkexec)

## What enable/disable touch

- **env** — environment.d + `.bashrc` block + `systemctl --user set-environment`
- **git** — global http/https proxy
- **npm** — proxy, https-proxy, strict-ssl false, maxsockets 1
- **yarn** — proxy, https-proxy (only if yarn installed)
- **pip** — `~/.config/pip/pip.conf`
- **vscode** — `http.proxy` + `http.proxyStrictSSL` in `Code/User/settings.json`
- **browser** — chromium/google-chrome launchers routed through wrappers
- **pacman** — sudoers env_keep so `sudo pacman`/`yay` keep proxy vars

`disable` reverts all of it.

## How to use

Bar widget (right side): the **󰓓 Proxy** icon is accent-colored when the proxy
is on. Left-click opens/closes the panel; the proxy itself is toggled from the
panel's Enable/Disable switch (with optimistic UI — status lags ~2s). The panel
shows status rows for git, npm, yarn, pip, VSCode, browser, pacman and the endpoint.

CLI:
```
omarchy-shell abukiya.proxy status
omarchy-shell abukiya.proxy enable
omarchy-shell abukiya.proxy disable
omarchy-shell abukiya.proxy toggle
```

Gateway is auto-detected on every enable (`gatewayAuto: true`), so it follows
the hotspot even when the phone's IP changes.

## Gotchas / bugs we hit (important)

1. **`.bashrc` interactive guard** — the `# PROXY_SETTINGS` block must be
   inserted ABOVE `[[ $- != *i* ]] && return`. Omarchy's menu runs terminals
   via non-interactive `bash -lc` (execDetached), so a block below the guard is
   never sourced → `sudo pacman -S` from Menu→Install had no `http_proxy` and
   failed on the hotspot-only network. **This fixed the "install doesn't work"
   bug.**

2. **`omarchy-launch-browser` strips Exec flags** — it reads only the FIRST
   token of a `.desktop` `Exec=` line, dropping `--proxy-server=...`. That's
   why Super+Shift+Enter / app-menu launches ignored the proxy while
   `gtk-launch` worked. Fix: launchers route through `omarchy-proxy-<browser>`
   wrapper symlinks that read the live gateway state file and inject the flag
   at launch time.

3. **pacman must run LAST in `apply()`** — `enable_pacman` calls `pkexec`
   (modal polkit dialog). When it ran before browser, enable appeared to skip
   browser entirely (pkexec blocked until you auth). Reordering fixed it.

4. **Status can lag ~2s** — IPC `status` returns a cached snapshot refreshed
   asynchronously. Actual system state is correct immediately; the cache
   catches up. Not a bug, just async.

5. **`/etc/sudoers.d` unreadable by the user** — `[[ -f ... ]]` on the sudoers
   file always fails (directory perms). AND `pkexec test -f` from the shell's
   service context is unreliable: the polkit agent registers after the
   service's startup status refresh, so the probe times out (~5s) and the
   panel showed pacman/yay as OFF even though the rule existed. Fix: pacman
   status reads a marker (`~/.config/hotspot-proxy/pacman-sudoers`) written by
   enable/disable and seeded by a one-time probe, so status is instant and
   context-independent.

6. **Qt QML rejects symlinked plugin dirs** — "File name case mismatch" on
   widget/panel entry points. The fix that finally landed: the live plugin dir
   is a real directory, kept in sync from the repo with `./sync.sh`.
   Debugging notes from that hunt: the failure was *per-URL* and cached
   in-memory by the running shell — a URL that first failed (e.g. while the dir
   was a symlink) kept failing for the whole shell session even after the dir
   became real; a fresh shell (or `omarchy-restart-shell`) cleared it. Probe
   plugins with the same content in different dirs loaded fine, which
   initially pointed the finger at the file contents instead.

7. **No notification daemon** — `notify-send` silently does nothing unless the
   message is tagged `-a omarchy-action` (bypasses DND in the omarchy
   notifications service).

8. **QML `Timer` needs `running: true`** — a `Timer` with `repeat`/`interval`
   but no `running` never starts, so a widget that "polls" with
   `running: true` on its `Process` runs its probe exactly once (at mount,
   before the service cache is ready → `enabled=undefined`) and then freezes.
   The bar icon showed "Proxy off" forever while the proxy was on. Fix:
   `running: true` on the poll timer (the first-party SystemUpdate widget sets
   it too).

## Side effects if you remove it

`omarchy plugin disable` (or deleting the plugin) does NOT revert anything —
it only removes the plugin from the shell. To fully remove:
1. `omarchy-shell abukiya.proxy disable` (reverts all integrations)
2. `omarchy plugin disable abukiya.proxy`
3. Delete the copied plugin dir + repo (menu entries already removed).

Leftovers from old setproxy.sh (unmanaged by the plugin): `# PROXY_ALIASES`
block in `~/.bashrc` and `~/.local/bin/chrome-proxy` — only relevant if you
used google-chrome/chrome aliases (you use chromium, so they're dead weight).

## Current state

- **All integrations working:** env, bashrc, git, npm, yarn, pip, vscode,
  browser, pacman (needs one-time pkexec auth to create the sudoers file).
- **Configurable port:** `proxy.json` supports a `port` field (default 8080,
  validated 1-65535). Gateway state file stores full URL including port.
- **54 bats tests:** cover all functions — config management, every
  enable/disable integration, the browser wrapper standalone script, and
  end-to-end status output. Run with `/tmp/bats-core/bin/bats tests/proxy-manager.bats`.
- **Browser wrapper extracted:** standalone `omarchy-proxy-browser` file instead
  of inline heredoc. write_wrapper() copies the file, with a guard for missing
  source.
- **Bug fixes applied:**
  - `disable_npm` now cleans up `strict-ssl` and `maxsockets`
  - `systemctl set-environment` propagates both upper and lowercase env vars
  - `pip.conf` enable no longer creates duplicate `[global]` sections
  - `get_port` validates port is numeric 1-65535
  - Pacman sudoers cleaned of unused `ftp_proxy`/`all_proxy`
  - Browser wrapper strips whitespace from gateway state file
- **Known issue:** `refresh_gateway_urls` — jq's `//` operator treats `false`
  as falsy, so `gatewayAuto: false` is ignored (always refreshes). Documented
  in test 47.
- The plugin lives in a git repo (`~/proxy_manager`), copied into omarchy's
  plugin dir and kept in sync with `./sync.sh`.