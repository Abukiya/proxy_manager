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
    nm-dispatcher-proxy           NM dispatcher for connection events
  tests/
    proxy-manager.bats            bats test suite (77 tests)
    check.sh                      release validation (syntax, JSON, tests)
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
After editing files in `plugin/`, run `./sync.sh` to replace the copied plugin
directory and hot-reload the shell. Run `./install.sh` again when privileged
system components also changed.

The plugin's live config/state lives outside the repo:
- `~/.config/omarchy/proxy.json` — config (gatewayAuto, integrations, port, enabled)
- `~/.bashrc` — `# PROXY_SETTINGS` block
- `~/.config/environment.d/proxy.conf` — env vars for systemd user services
- `~/.local/share/applications/*.desktop` — browser launcher overrides (+ `.orig`)
- `~/.local/bin/omarchy-proxy-browser` + `omarchy-proxy-*` — browser wrappers
- `~/.config/hotspot-proxy/gateway` — live gateway state file (full URL with port)
- `~/.config/hotspot-proxy/gateway-watcher.sh` — polling watcher script
- `~/.config/hotspot-proxy/gateway-watcher.pid` — watcher PID file
- `~/.config/hotspot-proxy/live-status.json` — status JSON for bar widget
- `/etc/sudoers.d/omarchy-proxy` — pacman/yay env_keep (via pkexec)
- `~/.curlrc` — file-based curl proxy (`# PROXY_SETTINGS` `proxy`/`noproxy`) so every `curl` caller — including third-party plugins — is proxy-aware without restarting the shell
- `/etc/NetworkManager/dispatcher.d/99-proxy-gateway` — NM dispatcher (optional, needs sudo)

## What enable/disable touch

- **env** — environment.d + `.bashrc` block + `systemctl --user set-environment`
- **git** — global http/https proxy
- **npm** — proxy, https-proxy, strict-ssl false, maxsockets 1
- **yarn** — proxy, https-proxy (only if yarn installed)
- **pip** — `~/.config/pip/pip.conf`
- **curl** — `~/.curlrc` (`# PROXY_SETTINGS` `proxy`/`noproxy`) so every `curl` caller — including third-party plugins (Todoist, etc.) — is proxy-aware without restarting the shell; watcher keeps it fresh on gateway drift
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

## Gateway auto-detection

When the phone hotspot IP changes, the proxy re-applies automatically:

1. **Watcher** (`gateway-watcher.sh`) polls `ip route` every 5 seconds
2. Detects new gateway → calls `gateway-change` on `proxy-manager.sh`
3. `gateway-change` updates `proxy.json`, re-applies all integrations (except
   pacman — its sudoers rule is static), writes `live-status.json`
4. Watcher calls `omarchy-shell abukiya.proxy enable` through IPC to refresh
   Service.qml's `cachedStatus` so the bar widget and panel update
5. Desktop notification sent via `notify-send -a omarchy-action`

The watcher starts on `enable` and stops on `disable`. It's idempotent —
calling `enable` when the watcher is already running doesn't kill it.

**How the IPC cache stays fresh:** The watcher calls `enable` through IPC
after `gateway-change`. This runs the full enable path through Service.qml's
command queue, which updates `cachedStatus`. The bar widget polls this cache
every 3 seconds. `start_watcher` checks if a watcher is already running
before killing and restarting, so the IPC call from inside the watcher
doesn't kill itself.

**What auto-updates without restart:** git, pip, env/.bashrc, new terminal
sessions, new browser windows (wrapper reads live gateway).

**Still needs manual restart:** VS Code, npm (cache proxy at startup).

### NetworkManager dispatcher

`nm-dispatcher-proxy` is installed to `/etc/NetworkManager/dispatcher.d/`
(needs `sudo ./install.sh`). Fires on `up` events (initial connection).
For mid-connection gateway changes (DHCP renewals), the polling watcher
handles detection. The dispatcher is a fallback, not the primary mechanism.

## Gotchas / bugs we hit (important)

1. **`.bashrc` interactive guard** — the `# PROXY_SETTINGS` block must be
   inserted ABOVE `[[ $- != *i* ]] && return`. Omarchy's menu runs terminals
   via non-interactive `bash -lc` (execDetached), so a block below the guard is
   never sourced → `sudo pacman -S` from Menu→Install had no `http_proxy` and
   failed on the hotspot-only network. **This fixed the "install doesn't work"
   bug.**
   **Regression:** the "cleaner" rework switched to `cat >>`, which appended the
   block BELOW the guard again (menu terminals lost `http_proxy`). Restored via
   `install_bashrc_block()` which strips any previous block and inserts the new
   one above the guard (appends to EOF only as a fallback when no guard exists).
   **Rule: never reintroduce a plain `cat >>` for this block.**

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

9. **`ip monitor route` needs root** — as a regular user, `ip monitor route`
   produces no output (needs CAP_NET_ADMIN). The gateway watcher uses polling
   (`ip route` every 5s) instead of netlink events.

10. **Watcher must not kill itself** — when the watcher calls `enable` through
    IPC to refresh the cache, `start_watcher` would kill the running watcher.
    Fix: `start_watcher` checks if a watcher PID is already alive before
    killing and restarting.

11. **QML FileView/Timer file polling unreliable** — `FileView { watchChanges }`
    and `Timer` + `Process { cat file }` both failed to reliably detect file
    changes in this QML environment. The watcher instead calls `enable`
    through IPC to update the cache directly.

12. **Third-party manifests lose `__sourceDir`** — `shell.qml`'s
    `publicPluginManifest()` strips `__sourceDir` (and the other `__*` fields)
    from the manifest it injects into third-party plugin instances
    (shell.qml:316-324, assigned at shell.qml:930). `Service.qml` derived its
    script path from `manifest.__sourceDir`, which was ALWAYS empty for
    `abukiya.proxy` → every `enable`/`disable`/`status` IPC silently no-opped
    → the panel's 8s guard (Panel.qml's pendingGuard) fired *"Failed to enable
    proxy"* even though nothing had run. Fix: resolve siblings relative to the
    QML file with `Qt.resolvedUrl("proxy-manager.sh")` — the same idiom
    `agx.screen-time` uses. **Rule: third-party plugin code must never derive
    paths from `manifest.__sourceDir`.**

13. **pkexec can stall the IPC caller** — `enable_pacman`/`disable_pacman` used
    a bare `pkexec`, which blocks indefinitely when no polkit agent responds
    (and the agent can lag the service's startup). A stalled pkexec made the
    IPCs that call `apply` exceed the panel's pendingGuard → *"Failed to
    enable"* even while the rest of the proxy was applying. Fix: `timeout 5
    pkexec` around both, so a dead/absent agent degrades to a stderr warning
    instead of blocking the queue.

14. **Disable must clear systemd + D-Bus with `VAR=`** — `disable_env` first
    did `systemctl unset` then `dbus-update-activation-environment --systemd
    http_proxy` (bare name). Bare means "copy from current env" — after we
    `unset` there, dbus ignored it and kept the old value; next
    `daemon-reload` re-set the manager env and new apps kept the proxy. Also
    `--systemd VAR=` leaves an empty var in the manager (still counts as set),
    so we must `systemctl unset` again after dbus. Fix: unset in process,
    `systemctl unset`, `dbus --systemd VAR=` + `systemctl unset` (with
    `NODE_USE_ENV_PROXY`), plus a defensive `show-environment` fallback.
    Running shells/browsers cache proxy at launch and need restart — new
    `bash -lc` is clean immediately.

15. **`curl` callers ignore shell env — root fix for all curl-based plugins** — third-party plugins (Todoist `curl -K -` with stdin `Authorization: Bearer`) shelled `curl` via `Quickshell.Io.Process`, which inherits env from the `quickshell` process at launch time. When the hotspot gateway drifted (`127.0.0.1:8080` → `192.168.176.99:8080`), `http_proxy` in the shell stayed stale until restart, so `curl` tried the dead proxy and returned `(7) Could not connect` → panel showed `Couldn’t reach Todoist — check your connection` even though the token was valid and `api/v1` was current. Diagnosis: compare `proxy.json` vs `tr '\0' '\n' < /proc/$(pidof quickshell)/environ | grep -i proxy` vs `systemctl --user show-environment | grep proxy`; prove with `curl -x http://old:8080` (fails) vs `curl -x http://new:8080` (200) vs `curl --config ~/.curlrc` (200). Fix: `~/.curlrc` `# PROXY_SETTINGS` `proxy`/`noproxy` is read by every `curl` invocation independent of env. `enable_curl`/`disable_curl` manage only that block (preserve other content, atomic `.tmp.$$`, `noproxy` conditional); `integration_active` reports `curl`, `apply`/`apply_current`/watcher include `curl` (pacman stays last), default `integrations` now includes `curl`, and `ensure_curl_integration` migrates existing installs. Verified: isolated `$HOME` bats + live `~/.curlrc` → `curl` works even with empty env (`env -u http_proxy curl https://api.todoist.com/api/v1/projects` → 200).

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

- **All integrations working:** env, bashrc, git, npm, yarn, pip, curl (`~/.curlrc`), vscode,
  browser, pacman (needs one-time pkexec auth to create the sudoers file).
- **Gateway auto-detection:** background watcher polls `ip route` every 5s,
  detects gateway changes, re-applies all integrations, notifies the user.
  Watcher starts on enable, stops on disable, is idempotent.
- **Configurable port:** `proxy.json` supports a `port` field (default 8080,
  validated 1-65535). Gateway state file stores full URL including port.
- **Self-cleaning `.bashrc` block:** after `disable` the `# PROXY_SETTINGS`
  block lingers with empty URLs and auto-unsets any inherited proxy vars in new
  shells, so terminals don't leak the proxy after a no-re-login disable.
  Inserted above the interactive guard by `install_bashrc_block()`.
- **Disable connectivity probe:** `disable` runs `check_connectivity()` (three
  HTTP probes). If none succeed — e.g. the phone hotspot requires Every Proxy —
  a critical *"Proxy disabled — no internet detected"* notification is shown.
  `proxy-manager.sh disable --no-check` skips the probe.
- **`timeout 5 pkexec`** wraps the sudoers helper so a missing/lagging polkit
  agent can't stall the enable/disable IPC (see gotcha #13). `disable_pacman`
  clears the marker even if removal fails and prints a manual
  `sudo rm /etc/sudoers.d/omarchy-proxy` hint on failure.
- **D-Bus propagation:** `enable_env` also runs
  `dbus-update-activation-environment --systemd`, so D-Bus-activated services
  see the proxy vars immediately (not just future systemd user services).
- **Disable fully clears env:** `disable_env` unsets in process, clears
  `systemctl --user` + D-Bus activation env with `VAR=` then re-unsets
  (covers `NODE_USE_ENV_PROXY`; see gotcha #14). `disable_pip` deduplicates
  stacked `[global]` and `disable_yarn` handles both `delete` and `unset`.
- **71 bats tests:** cover all functions — config management, every `curl` via `~/.curlrc`,
  enable/disable integration, the browser wrapper standalone script,
  end-to-end status output, and gateway-change command.
  Run with `/tmp/bats-core/bin/bats tests/proxy-manager.bats`.
- **Test harness:** the setup extracts the script's function definitions up to
  the command dispatch with `sed -n '/^set -/d; /^NO_CHECK=/q; p'` (was
  `case "${1:-status}"`, which no longer matches the `--no-check` dispatch).
  Test 29 asserts the self-cleaning block stays after disable.
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
  - `enable_pacman` trusts the marker file (no pkexec if already created)
  - **`Service.qml` script path** is now `Qt.resolvedUrl("proxy-manager.sh")`,
    not `manifest.__sourceDir` (stripped for third-party plugins — gotcha #12).
    This is what finally fixed *"Failed to enable proxy"* from the panel.
  - **`.bashrc` block placement** restored via `install_bashrc_block()` so the
    proxy block sits above the interactive guard again (gotcha #1 regression).
- **Fixed:** `refresh_gateway_urls` previously used `jq '.gatewayAuto // true'`
  where `//` treats `false` as falsy, so `gatewayAuto: false` was ignored
  (always refreshed). Now it reads `auto=$(cfg_get '.gatewayAuto')` and
  early-returns on `== "false"` / empty, so `false` is respected. Test 47
  documents the old bug.
- The plugin lives in a git repo (`~/proxy_manager`), copied into omarchy's
  plugin dir and kept in sync with `./sync.sh`.
- **Repo/live drift:** during the "cleaner" rework the live plugin dir
  (`~/.config/omarchy/plugins/abukiya.proxy`) got ahead of the repo (the
  self-cleaning bashrc, connectivity probe, `timeout 5 pkexec`, `--no-check`,
  D-Bus update). All of that plus the fixes above were synced back
  repo ← live, so `diff -r plugin <live dir>` is now clean.