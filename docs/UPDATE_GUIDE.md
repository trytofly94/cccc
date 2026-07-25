# Update Guide

How to update cccc and migrate from previous versions.

## Updating cccc (v3.0+)

### Pull and Reinstall

```bash
# Navigate to the repository
cd /path/to/cccc

# Pull latest changes
git pull
```

### Re-run the installer

The supported install copies the scripts into `~/.local/bin/`, so updating is just
a matter of re-running the installer after pulling. `install.sh` is idempotent and
safe to re-run at any time:

```bash
./install.sh
```

This re-copies `cccc`, `cc-webui.py`, `limit-watcher.sh`, and `claude-cleanup`
into `~/.local/bin/` (atomically, so a running session never sees a half-written
file), and leaves your existing `~/.config/claude-control/` config untouched. Both
`cccc` and the Settings Web UI (`cc-webui.py`) must resolve from `~/.local/bin/`;
`cccc settings` / `cccc webui` also fall back to the repo checkout path if the
sibling `cc-webui.py` is missing.

If you opted into the short `cc` alias, pass the flag again on update:
`./install.sh --with-cc-symlink`.

#### Manual copy (alternative)

If you installed the scripts by hand rather than via `install.sh`, re-copy them on
every update:

```bash
cp cccc/cccc ~/.local/bin/cccc && chmod +x ~/.local/bin/cccc
cp cccc/cc-webui.py ~/.local/bin/cc-webui.py   # REQUIRED for `cccc settings` / `cccc webui`
```

> **External access:** `cccc settings` binds `127.0.0.1` only by default (local
> machine only, auto-opens the browser). LAN exposure is now the explicit
> `cccc settings --lan` opt-in — or the `cccc webui` alias, which still binds all
> interfaces (`0.0.0.0`) and prints local / LAN / Tailscale links by default (no
> auto-open). If a remote device can't connect, the macOS Application Firewall is
> likely dropping incoming connections to `python3` — allow it in System Settings
> (Network > Firewall), or headless:
> `sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate off`.

No service restart is required — cccc is a standalone bash script with no background daemon.

### Verify the Update

```bash
# Check the installed version matches the repo
cccc --version 2>/dev/null || head -5 ~/.local/bin/cccc
```

## v3.0 Migration Notes (Updating from v2.x)

Version 3.0 removes the HAPI middleware layer entirely. cccc now calls `claude` directly without any TypeScript wrapper, LaunchAgent, or bun runtime.

### What Changed

| v2.x | v3.0 |
|------|------|
| cccc → hapi wrapper → HAPI TypeScript → claude | cccc → claude (direct) |
| Requires bun + Node.js | No additional runtimes |
| HAPI LaunchAgent for background service | No background service |
| HAPI_WORKING_DIR environment variable | Not needed (tmux -c handles cwd) |
| Mobile PWA at localhost:3006 | No PWA (terminal only) |

### Removing HAPI Artifacts

If you previously ran v2.x, clean up the HAPI infrastructure:

**1. Remove the HAPI LaunchAgent:**

```bash
# Unload and delete the LaunchAgent plist
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.hapi.server.plist 2>/dev/null
rm -f ~/Library/LaunchAgents/com.hapi.server.plist
echo "LaunchAgent removed"
```

**2. Remove the HAPI wrapper script:**

```bash
rm -f /opt/homebrew/bin/hapi
echo "HAPI wrapper removed"
```

**3. Optionally remove HAPI source and config:**

```bash
# HAPI source (was in /tmp — likely already gone after reboot)
rm -rf /tmp/hapi-deep-analysis

# HAPI config (settings.json, logs)
rm -rf ~/.hapi
```

**4. Verify cleanup:**

```bash
which hapi 2>/dev/null && echo "WARNING: hapi still in PATH" || echo "OK: hapi not found"
launchctl list | grep -i hapi && echo "WARNING: HAPI LaunchAgent still loaded" || echo "OK: no HAPI service"
```

No other action is needed. The projects registry (`~/.config/claude-control/projects.conf`) is unchanged and compatible with v3.0.

### After Migration

Run `cccc` to confirm the dashboard works and sessions start correctly:

```bash
cccc
# Press a project letter
# In Claude session: verify cwd is correct with pwd or /status
```

## Troubleshooting Updates

### cccc Behaves Unexpectedly After Update

If the installed cccc does not reflect the latest changes:

```bash
# Check if there are multiple cccc installations
which -a cccc
type -a cccc

# Confirm the right one is installed
head -2 ~/.local/bin/cccc
```

### PATH Issues After Update

```bash
# Reload shell config
source ~/.zshrc  # or ~/.bashrc

# Re-verify cccc location
which cccc  # Should return ~/.local/bin/cccc
```
