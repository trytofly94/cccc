# cccc (Claude Code Control Center) Reference

A terminal-based dashboard for managing Claude Code sessions within tmux.

## Overview

cccc provides an interactive interface for:
- Viewing all active Claude Code sessions
- Quick switching between projects
- Creating new sessions with managed naming
- Session lifecycle management (attach, detach, kill)

## Installation

```bash
# Copy to PATH
cp cccc/cccc ~/.local/bin/cccc
chmod +x ~/.local/bin/cccc

# Create configuration
mkdir -p ~/.config/claude-control
touch ~/.config/claude-control/projects.conf
```

## Configuration

### Projects File

Location: `~/.config/claude-control/projects.conf`

Format:
```
project-name|/full/path/to/project
```

Example:
```
frontend|/Users/me/projects/frontend
backend|/Users/me/projects/backend-api
docs|/Users/me/projects/documentation
```

The project name is used:
- As the display name in the dashboard
- As the default session tag when creating sessions
- For quick filtering and selection

## Commands

### Interactive Mode

```bash
cccc
```

Opens the interactive dashboard, showing your registered projects (by letter)
and any free/running sessions (by number), with status and last-activity info.

### CLI Subcommands

```bash
cccc                        Start interactive dashboard
cccc -c                     Continue last Claude session in current directory
cccc add <name> <path>      Add project
cccc rm <name>               Remove project
cccc new <project> [-c|-r|-p] [=backend] <name>
                             Create a session non-interactively (SSH-friendly); prints
                             the created session name and returns without attaching
cccc kill <session>         Kill a cc-* session (name-persistence + watcher cleanup preserved)
cccc list                   List projects
cccc cleanup                Kill orphaned Claude processes (safe for cccc sessions)
cccc cleanup -n             Dry-run: show orphans without killing
cccc limit                  Open Limit Watcher Manager (persistent, non-blocking)
cccc settings                Settings Web UI: projects.conf + settings.conf — binds 127.0.0.1, auto-opens the browser (primary command)
cccc settings --lan          Same, but also bound to network interfaces (auto-open stays on)
cccc settings --no-open      Same, but suppress browser auto-open
cccc webui                  Legacy alias for 'cccc settings --lan --no-open' — preserves the pre-existing default (network interfaces, prints link, no auto-open)
cccc webui --local          Same, but 127.0.0.1-only + auto-opens the browser
cccc config                 View/change settings
cccc about                  Show logo, version, and repo URL
cccc json                   Emit a JSON snapshot of projects + sessions (for external tools)
cccc --no-logo              Suppress the logo for this invocation (also: SHOW_LOGO setting)
cccc -v / --version         Print cccc version
cccc -h / --help / help     Show help
```

`kill` takes a session *name* (as shown by `cccc list`), not a number — kill by number is only available from inside the interactive dashboard.

## Interactive Dashboard

### Layout (illustrative)

Projects are grouped under the `[Category]` headers from `projects.conf`. Each
category gets its own color on the letter chip and the title; sessions nest
under their project with a live status. The dashboard paints progressively
(header first, rows build up).

```
cccc 4.0.0    ⚙ settings 127.0.0.1:8787

──[ Work ]───────────────────────────────────────────
 a  Autobooks                     ~/dev/autobooks
  ├─ 1  api            ▸ working   [2 win] 🔍
► ├─ 2  billing-fix    ● waiting   [1 win]
  └─ 3  import-tool    💤 asleep    [1 win]
 b  Website                       ~/dev/website
  └─ ⚫ no sessions

──[ Free ]───────────────────────────────────────────
  └─ 4  scratch        ○ idle      [1 win] ~/tmp/scratch (C)

 1 waiting · ▸ working · ● waiting · ○ idle · 💤 asleep · ⚫ stopped · 🔍 watcher
```

### Session status

| Glyph | Status | Meaning |
|-------|--------|---------|
| `▸` | **working** | Claude is actively running a tool or agent right now |
| `●` | **waiting** | Claude needs *your* input (permission prompt / question). The row is flagged with a yellow `►` in the gutter, and the total is summarized as `N waiting` in the footer |
| `○` | **idle** | Claude is running and resting at the prompt |
| `💤` | **asleep** | The tmux session/pane is alive but the Claude process has exited — reclaimed by the idle-watchdog (SIGTERM after idle days) or quit manually. Resume instantly with `claude --resume <session-id>` (NOT `--continue`) |
| `⚫` | **stopped** | No session for that project |
| `🔍` | **watcher** | A limit-watcher daemon is active for that session |

### Category colors

Each `[Category]` in `projects.conf` is auto-assigned a color (letter chip +
title + divider), so categories are easy to tell apart. Override any category's
color from a preset palette in the Settings Web UI (Organisation tab → the
swatch on the category header). Overrides are stored in a **separate**
`group-colors.conf` (`categoryname|colorname`) so `projects.conf` is never
touched. Yellow and red are reserved for status signals and excluded from the
palette.

### Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `<letter>` | Open/create session for that project |
| `<letter>n` | Force a new session for that project |
| `<letter>n-c` | New session with `--continue` |
| `<letter>n-r` | New session with `--resume` (picker) |
| `<letter>n-p` | New session with `--permission-mode plan` |
| `<letter>n-b` | New session with browser support (`--chrome` + browser MCPs, opt-in) |
| `<letter>n-v` | New session with `--verbose` |
| `<letter>n-cf` | New session with `--continue --fork-session` |
| `<letter>n=<backend>` | New session with an alternative backend (provided by a local plugin) |
| `<letter>g` | Start a GSD orchestration session (needs the GSD companion plugin, requires `.planning/ROADMAP.md`) |
| `<letter>k` | Kill ALL sessions in that project (asks for a `y/N` confirmation) |
| `<letter>remove` | Remove project (with confirmation) |
| `n` | Create a new free session (interactive prompt) |
| `n /path` | Create a new free session at a given path |
| `add /path` | Add a project to the registry |
| `<number>` | Attach to a free session by number |
| `<number>k` | Kill session by number (press literal `k` to confirm) |
| `1,2,3k` | Kill multiple sessions by number, comma-separated (press literal `k` to confirm) |
| `watch<number>` | Start a limit-watcher for that session number |
| `limit` | Open the Limit Watcher Manager |
| `config` | View/change settings |
| `recover` | Recover / rescan sessions |
| `r` | Refresh dashboard |
| `h` / `help` | Show help |
| `q` | Quit |

## Session Naming Convention

Sessions are named `cc-<project>-<name>`, where `<project>` is the project's
registered name (from `projects.conf`) and `<name>` is either a user-supplied
session label or an auto-generated one. Both segments are sanitized (lowercase,
no spaces) before being joined.

## tmux Integration

cccc discovers sessions by scanning tmux for sessions matching `cc-*`:

```bash
tmux list-sessions | grep "^cc-"
```

Manual tmux sessions can be made visible to cccc by naming them `cc-<name>`.

## Configuration

cccc reads its project registry from a fixed path — `~/.config/claude-control/projects.conf` —
resolved dynamically on every run; there is no environment-variable override for this
location today.

## Limit Watcher Manager

`cccc limit` opens an interactive **Limit Watcher Manager** — a non-blocking control panel
for background rate-limit watcher daemons. One daemon per session, each running in its own
tmux session and persisting after the menu is closed.

### Menu layout

```
🔍 LIMIT WATCHER MANAGER
────────────────────────────────────────────────────────
   1  🔍 cc-myproject-main                     watching
   2     cc-frontend-dev                       active
   3     cc-api-work                           ⏸ rate-limited  resets 12am (Europe/Berlin) in 43 min
────────────────────────────────────────────────────────
Commands:  watch N[,M,...] | w N[,M,...] | watch a   start watcher(s)
           k N[,M,...]                              stop watcher(s)
           q / <Enter>                              quit
```

All watchable sessions are listed — both `cc-*` (cccc-managed) and bare-name sessions
(e.g. worker sessions spawned by an external orchestration workflow, like
`myproject-worker`). Daemon sessions (`limit-watcher-*`, `conductor-*`) are
excluded. Sorted by name for stable numbering.

### Commands

| Command | Effect |
|---|---|
| `watch N` or `w N` | Start watcher for session N |
| `watch N,M,...` | Start watchers for multiple sessions (comma-separated) |
| `watch a` | Start watchers for ALL listed sessions |
| `k N` / `k N,M,...` / `k a` | Stop watcher(s) for one, several, or all sessions |
| `q` or Enter | Quit the manager |

Invalid selections are rejected atomically — no partial application.

### Daemon model

Each watcher runs as a tmux session: `limit-watcher-<session-name>`

```bash
bash "$CC_SCRIPT_DIR/limit-watcher.sh" '<session>'
```

- Watchers **persist** after the menu is closed (`q` does not kill them).
- A watcher session exits naturally when its target session disappears.
- Killing any session via cccc (`<n>k` or `<letter>k`) also kills the associated
  `limit-watcher-*` session automatically.
- An external orchestration workflow can use the same naming convention
  (`limit-watcher-<worker>`) — watchers it spawns appear in `cccc limit` and
  can be managed from there.
- Log file: `~/.local/log/gsd-limit-watcher-<slug>.log`

### Dashboard 🔍 indicator

The main `cccc` dashboard shows 🔍 next to any session that has an active
`limit-watcher-<session>` tmux session. It appears alongside the session-status
glyphs in the footer legend:

```
▸ working · ● waiting · ○ idle · 💤 asleep · ⚫ stopped · 🔍 watcher
```

---

## Settings Web UI (cccc settings)

```bash
cccc settings              # bind 127.0.0.1 only, auto-open the browser (primary command)
cccc settings --lan        # also bind all network interfaces (auto-open stays on)
cccc settings --no-open    # bind 127.0.0.1 only, suppress browser auto-open
cccc webui                 # legacy alias: bind all network interfaces, print links, no auto-open
cccc webui --local         # legacy alias: bind 127.0.0.1 only, auto-open the browser
```

`cccc settings` launches a local, self-contained web editor with two tabs:
**Organisation** (the project registry, `~/.config/claude-control/projects.conf`)
and **Einstellungen** (all 10 `~/.config/claude-control/settings.conf` keys —
`PERMISSION_MODE`, `PERMISSION_MODE_FALLBACK`, `MODEL`, `MEMORY_LIMIT_MB`,
`CLAUDE_BIN`, `EXTRA_FLAGS`, `LIMIT_WATCHER`, `AUTO_TRUST`, `SHOW_LOGO`,
`IDLE_WATCHDOG`), each
rendered with a type-correct widget (enum dropdowns, number/text inputs, a
checkbox). It starts a Python-stdlib-only, multi-threaded HTTP server (zero
npm/pip/CDN — fully offline). Organisation is the default-visible tab; switch
to Einstellungen via the header tab bar. Settings changes only take effect for
newly launched sessions (a note to this effect is shown next to the Save
button).

- **`cccc settings`** (no flags) binds `127.0.0.1` only and auto-opens your
  default browser — the new local-first default.
- **`--lan`** (opt-in, combinable with either command name) additionally binds
  `0.0.0.0` (all interfaces) so the editor is reachable from other devices on
  your network; auto-open still applies unless `--no-open` is also given. A
  **no-authentication** warning is printed whenever bound to all interfaces.
- **`--no-open`** (opt-in) suppresses the browser auto-open without changing
  the bind host.
- **`cccc webui`** (no flags) remains a backward-compatible alias that
  preserves the pre-existing default exactly: binds `0.0.0.0` (all
  interfaces), prints the reachable URLs, and does **not** auto-open a
  browser.
- **`cccc webui --local`** (deprecated but still functional) is a synonym for
  the `cccc settings` default: binds `127.0.0.1` only and auto-opens the
  browser.

The script is `cccc/cc-webui.py` (flags: `--host`, `--port`, `--no-browser`,
`--config`, `--settings`, `--selftest`). `cccc settings`/`cccc webui` resolve
it next to the installed `cccc` binary first, then fall back to the repo
checkout path.

### Remote access & security

The Settings Web UI has **no authentication** — anyone who can reach `host:port`
can edit `projects.conf` and `settings.conf`. LAN exposure is now an explicit
opt-in: use `cccc settings --lan` (or the `cccc webui` alias, which still
exposes it by default for backward compatibility). When binding externally,
prefer the **Tailscale** URL (private to your tailnet) over the LAN URL, and
avoid untrusted networks.

If a remote device can't connect, the **macOS Application Firewall** is most likely
dropping incoming connections to `python3`. Fix via System Settings > Network >
Firewall (allow `python3`, or toggle the firewall off), or headless over SSH:

```bash
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate off
```

### What it does

- **Add / remove projects** (name + absolute path) per section.
- **Drag-and-drop reorder** projects within a section and across sections, using
  native HTML5 drag-and-drop (no external libraries).
- **Section management:** add, rename, delete (projects move to "no section"), and
  reorder whole sections (▲/▼ buttons).
- **Live a–z mapping:** because cccc assigns dashboard letters by project line order
  across the whole file, the editor recomputes and shows the resulting letters as
  you rearrange (reserved letters `h`, `n`, `q`, `r` are skipped, mirroring cccc).

### Ordering = dashboard letters

The order projects appear in the file directly determines the a–z hotkeys in the
`cccc` dashboard. Reordering in the WebUI changes those letters — this is the
intended feature. Changes take effect the next time `cccc` renders.

### Saving, backups, and comments

- On Save the server writes a **timestamped backup** first
  (`~/.config/claude-control/projects.conf.bak-<YYYYmmdd-HHMMSS>`), then writes
  the file **atomically** (temp file in the same directory + `os.replace`).
- Output is **byte-compatible** with cccc's parser: section order, project order,
  `name|path` with no spaces around the pipe, non-ASCII names, and
  space-containing paths are all preserved.
- **Comments are not preserved:** free-floating `#` comment lines are dropped on
  save (none exist today; any prior content remains in the backup file).

### JSON API contract

The server exposes these routes (on the bind host — `127.0.0.1` for the
`cccc settings` default, otherwise all interfaces):

- `GET /` → the single inlined HTML page (Organisation + Einstellungen tabs).
- `GET /api/config` → `{ "sections": [...], "unsectioned": [...], "path": "...", "letters": ["a","b",...] }`.
  Section and project order mirror file order.
- `PUT /api/config` → same shape in the body. Validates, backs up, writes
  atomically. Returns `{ "ok": true, "backup": "<path>", "letters": [...], "warnings": [...] }`
  on success, or HTTP `400 { "ok": false, "error": "..." }` on a contract-violating
  payload (empty name/path; `|`, `[`, `]` or leading `#` in a name; `[`, `]` or
  newline in a section name).
- `GET /api/settings` → `{ "PERMISSION_MODE": "...", "PERMISSION_MODE_FALLBACK": "...", "MODEL": "...", "MEMORY_LIMIT_MB": "...", "CLAUDE_BIN": "...", "EXTRA_FLAGS": "...", "LIMIT_WATCHER": "...", "AUTO_TRUST": "...", "SHOW_LOGO": "...", "IDLE_WATCHDOG": "..." }`
  — all 10 `settings.conf` keys, defaults applied for any key not present in the file.
- `PUT /api/settings` → same shape in the body. Re-validates every key against
  the same whitelist as `cccc config`/`write_setting()` (server-side, not just
  client-side), backs up, writes atomically. Returns
  `{ "ok": true, "backup": "<path>", "warnings": [] }` on success, or HTTP
  `400 { "ok": false, "error": "..." }` on an invalid enum value or a
  `CLAUDE_BIN` value containing shell metacharacters.

### Verify

```bash
cccc settings                                # opens browser at http://127.0.0.1:8787 (or next free port)
cccc settings --lan                          # also prints every reachable network-interface link, browser still auto-opens
cccc settings --no-open                      # binds 127.0.0.1, no browser
cccc webui                                   # legacy alias: prints every reachable network-interface link (no auto-open)
cccc webui --local                           # legacy alias: opens browser at http://127.0.0.1:8787
lsof -iTCP -sTCP:LISTEN -nP | grep 8787    # cccc settings → 127.0.0.1:8787 ; cccc settings --lan / cccc webui → *:8787
python3 ~/.local/bin/cc-webui.py --selftest   # 'selftest OK' = round-trip stable (projects.conf + settings.conf)
# From another device, confirm reachability (replace with one of the printed URLs' IP):
curl -s -o /dev/null -w "%{http_code}\n" http://<printed-ip>:8787/   # expect 200
```

---

## Orphan Process Cleanup

Claude Code can leave orphaned processes when sessions don't terminate cleanly.
cccc ships a `claude-cleanup` reaper (invoked by `cccc cleanup`) that is safe for
all managed sessions. Cleanup is **not** run inline by the dashboard — it happens
only when you invoke it manually, or via the optional launchd schedule below.

### Manual Cleanup

```bash
# Clean orphans with details
cccc cleanup

# Dry-run (show orphans without killing)
cccc cleanup -n
```

### Safety Mechanism

The cleanup only kills processes that match ALL criteria:
- `PPID = 1` (reparented to init = parent died)
- `TTY = ??` (detached from terminal)
- `comm = claude` (the CLI binary)

This protects:
- ✅ Active tmux sessions (have real TTY)
- ✅ claude-mem plugin workers (have PPID ≠ 1)
- ✅ Claude.app processes

### Optional Background Cleanup (launchd)

`install.sh` can optionally install a launchd schedule (macOS only) that runs
`claude-cleanup` **twice daily at 04:00 and 12:00** as a safety net. The daemon
is labelled `com.user.claude-cleanup` and logs to
`~/.local/log/claude-cleanup/latest.log`:

```bash
# Check daemon status
launchctl list | grep claude-cleanup

# View cleanup log
cat ~/.local/log/claude-cleanup/latest.log

# Manually trigger
launchctl start com.user.claude-cleanup

# Disable
launchctl bootout gui/$(id -u)/com.user.claude-cleanup
```

### The `claude-cleanup` command

`install.sh` installs `claude-cleanup` to `~/.local/bin/` as a standalone binary
(the same reaper `cccc cleanup` calls):

```bash
claude-cleanup            # Kill orphans
claude-cleanup --dry-run  # Show what would be killed without killing
claude-cleanup --force    # Skip the 24h minimum-age check
```

## Troubleshooting

### Sessions Not Showing

Verify tmux session naming:
```bash
tmux list-sessions
```

Sessions must be named `cc-*` to appear in cccc.

### Project Not Found

Check projects.conf format:
```bash
cat ~/.config/claude-control/projects.conf
```

Each line must be: `name|/absolute/path`

### Permission Issues

Ensure cccc is executable:
```bash
chmod +x ~/.local/bin/cccc
```

### tmux Not Found

Install tmux:
```bash
# macOS
brew install tmux

# Ubuntu/Debian
sudo apt install tmux
```

## Alternative backends via the plugin system

Sessions can be started with an alternative LLM backend instead of Anthropic Claude,
using the `=<name>` hook syntax:

```
an=myBackend          New session in project 'a' using the 'myBackend' backend
an-c=myBackend         New session with --continue via 'myBackend'
anmyname=myBackend    New session named 'myname' via 'myBackend'
```

Backends are **not** part of the public Core — they are provided by a local plugin
that a Core hook point (`cccc_hook_resolve_backend`) delegates to when present. With
no backend plugin installed, the `=<name>` syntax is simply unavailable and cccc
behaves as a plain Claude Code session launcher.

To add your own backend(s), write a plugin that implements
`cccc_hook_resolve_backend`. See `CONTRIBUTING.md`'s plugin-authoring section for
the hook contract, the three available hook points, and a worked example.

---

## Advanced Usage

### Custom Session Creation

Create a session with a specific name and directory, visible to cccc, without
going through `cccc new` (which requires a project already registered in
`projects.conf`):

```bash
# Using tmux directly (visible in cccc — must start with "cc-" to be discovered)
tmux new-session -d -s cc-custom-name -c /path/to/project
tmux send-keys -t cc-custom-name 'claude' C-m
```

### Scripted Session Management

```bash
# Non-interactive session creation (SSH-friendly) — prints the created
# session name and returns without attaching. <name> is required.
cccc new myproject mysession

# List registered projects
cccc list

# Kill a specific session by name
cccc kill cc-myproject-mysession
```

### Integrating with Other Tools

cccc can be integrated into shell aliases or scripts:

```bash
# .zshrc or .bashrc
alias work='cccc new work-project main'
alias personal='cccc new personal main'
```
