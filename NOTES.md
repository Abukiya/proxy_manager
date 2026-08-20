# Proxy Manager — Session Notes

What we built and everything we learned along the way. Read this to catch up.

## What this is

An Omarchy shell plugin (`abukiya.proxy`) that replaces your temporary
`setproxy.sh` / `clearproxy.sh`. It's a **background service**: toggles
system proxy config for a phone-hotspot gateway, applied live, controllable
from the Omarchy menu. No persistent UI.

## Where everything lives

```
~/proxy_manager/                  <- this project (git repo)
  plugin/                         <- symlinked into omarchy as the live plugin
    manifest.json
    Service.qml                   IPC service (omarchy-shell abukiya.proxy ...)
    proxy-manager.sh              all the logic
  install.sh                      (re)install: symlink + enable
  docs/                           menu snippet + sample config
  README.md                       install/usage/removal
  NOTES.md                        this file
~/.config/omarchy/plugins/abukiya.proxy   -> symlink to ~/proxy_manager/plugin
```

The plugin's live config/state lives outside the repo:
- `~/.config/omarchy/proxy.json` — config (gatewayAuto, integrations, enabled)
- `~/.bashrc` — `# PROXY_SETTINGS` block
- `~/.config/environment.d/proxy.conf` — env vars for systemd user services
- `~/.local/share/applications/*.desktop` — browser launcher overrides (+ `.orig`)
- `~/.local/bin/omarchy-proxy-browser` + `omarchy-proxy-*` — browser wrappers
- `~/.config/hotspot-proxy/gateway` — live gateway state file
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

Menu: `Super+Alt+Space` → **Proxy** → Enable / Disable / Toggle / Status.

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
   file always fails (directory perms). Existence checks use `pkexec test -f`.

6. **No notification daemon** — `notify-send` silently does nothing unless the
   message is tagged `-a omarchy-action` (bypasses DND in the omarchy
   notifications service). Menu "Status" uses that.

## Side effects if you remove it

`omarchy plugin disable` (or deleting the plugin) does NOT revert anything —
it only removes the plugin from the shell. To fully remove:
1. `omarchy-shell abukiya.proxy disable` (reverts all integrations)
2. `omarchy plugin disable abukiya.proxy`
3. Delete the symlink + repo + Proxy menu entries.

Leftovers from old setproxy.sh (unmanaged by the plugin): `# PROXY_ALIASES`
block in `~/.bashrc` and `~/.local/bin/chrome-proxy` — only relevant if you
used google-chrome/chrome aliases (you use chromium, so they're dead weight).

## Current state

- Working: env, bashrc, git, npm, pip, vscode, browser, pacman (needs one-time
  pkexec auth to create the sudoers file).
- Verified end-to-end: menu toggle, IPC commands, browser keybind launch,
  menu→install (after the .bashrc fix), status toast.
- The plugin is now in a git repo (`~/proxy_manager`) with a clean baseline
  commit, symlinked into omarchy.