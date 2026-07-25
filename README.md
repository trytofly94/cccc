# cccc — Claude Code Control Center

![demo](docs/demo.gif)

A terminal toolkit for managing Claude Code sessions via tmux. Built around a single focused tool:

1. **cccc (Claude Code Control Center)** - Terminal-based session manager using tmux

## Overview

cccc enables seamless Claude Code session management from the desktop terminal. Sessions are created in the correct project directory without any middleware — tmux's native `-c <path>` flag handles working directory preservation.

### Key Benefits

- **Unified Session Management**: Interactive dashboard shows all Claude sessions across projects
- **Project Registry Integration**: Curated project list with quick letter-based selection
- **Direct Claude Integration**: No middleware layer — sessions start with correct cwd via tmux
- **Configurable Launch Behavior**: Permission mode, model, memory limit, and extra flags are set via `settings.conf` / `cccc config` — the shipped public default is `PERMISSION_MODE=auto` (Claude Code's supervised auto-accept mode for entitled models), falling back to the configurable `PERMISSION_MODE_FALLBACK` (public default: `default`, i.e. permission-prompting) when auto isn't actually available
- **Self-Hosted**: No external dependencies, runs entirely on your local machine
- **Extensible via Plugins**: Optional local plugins (backends, status badges, kill hooks) live outside the repo — see [Plugin authoring](CONTRIBUTING.md#plugin-authoring)

## Components

### cccc (Claude Code Control Center)

A bash script providing an interactive terminal dashboard for managing Claude Code sessions within tmux.

Features:
- **Categorized dashboard** — projects are grouped under the `[Category]` headers
  from `projects.conf`; each category gets its own color on the letter chip and
  title, and sessions nest under their project as a tree
- **Live session status at a glance** — every session shows one of
  `▸ working` · `● waiting` · `○ idle` · `💤 asleep` · `⚫ stopped`, and any session
  that needs *your* input is flagged with a yellow `►` plus an `N waiting` footer
  summary. `💤 asleep` marks a session whose tmux pane is alive but whose Claude
  process was reclaimed/quit — resume it instantly with `claude --resume <id>`
- **Per-category colors** — auto-assigned, and overridable from a preset palette
  in the Settings Web UI (stored in a separate `group-colors.conf`, so
  `projects.conf` is never touched)
- Quick project switching with keyboard shortcuts; session attachment/detachment
- Project registry with custom names; context tracking across sessions
- Optional local Settings Web UI (`cccc settings`) — a two-tab, local-first, auto-opening browser editor for `projects.conf` (Organisation tab, with the category color picker) and `settings.conf` (Einstellungen tab); the `cccc webui` alias remains for its original LAN-bind, no-auto-open behavior

Location: `cccc/cccc`

## Installation

For complete step-by-step instructions, see the [Setup Guide](docs/SETUP.md).

### Target Platform

- **macOS** — primary target, tested.
- **Linux** — best-effort; core tmux/bash functionality should work, but it is not
  actively tested on every distro. Report issues if you hit platform-specific gaps.
- **Windows** — not supported in this milestone (no WSL-specific testing or docs).

### Quick Start

```bash
# Clone the repository
git clone https://github.com/trytofly94/cccc.git
cd cccc

# Run the installer (copies cccc, cc-webui.py, claude-cleanup to ~/.local/bin,
# creates ~/.config/claude-control/, checks dependencies)
./install.sh

# Run cccc
cccc
```

`install.sh` is idempotent — safe to re-run any time (e.g. after `git pull`) to
pick up updates. See the [Update Guide](docs/UPDATE_GUIDE.md) for details.

The command is `cccc`. If you also want the shorter `cc` alias, opt in with
`./install.sh --with-cc-symlink` — it is **off by default** because `cc` is the
system C compiler and the alias would shadow it on your `PATH`.

### Prerequisites

- macOS or Linux
- **tmux** (required) — `brew install tmux`
- **jq** (required) — `brew install jq`
- **Claude Code CLI** installed (`claude` in PATH)
- **python3** (optional) — only needed for `cccc settings` (or its `cccc webui`
  alias); everything else works without it

`install.sh` checks for `tmux` and `jq` and will not proceed without them, and
warns (non-fatally) if `python3` is missing.

## Usage

### cccc Commands

```bash
cccc              # Open interactive dashboard
cccc list         # List projects
cccc cleanup      # Kill orphaned Claude processes
cccc cleanup -n   # Dry-run: show orphans without killing
cccc settings     # Local Settings Web UI: projects.conf + settings.conf (requires python3, auto-opens browser)
cccc webui        # Legacy alias: same UI, binds LAN, no auto-open (requires python3)
```

### Dashboard Navigation

```
  a  frontend        ~/test-projects/frontend
  b  myproject       ~/projects/myproject

<letter>       # Create or attach to session for that project
<letter>n      # Force a new session for that project
<letter>n-c    # New session with --continue
<letter>n-b    # New session with browser support (Claude-in-Chrome, opt-in)
<number>       # Attach to free session by number
<number>k      # Kill session by number
r              # Refresh dashboard
q              # Quit
```

On first run, if `~/.config/claude-control/projects.conf` doesn't exist or has no
real entries yet, cccc offers a short first-start wizard to add your first
project before showing the (otherwise empty) dashboard.

## Configuration

### Project Registry

cccc reads from `~/.config/claude-control/projects.conf`:

```
project-name|/full/path/to/project
another-project|/path/to/another
```

`install.sh` creates a commented example file on first install; it never
overwrites an existing one.

### Settings

Optional per-machine defaults live in `~/.config/claude-control/settings.conf`
(all keys are optional — omit any you don't want to override):

```
# PERMISSION_MODE=auto                # default|acceptEdits|plan|auto|bypassPermissions
# PERMISSION_MODE_FALLBACK=default    # default|acceptEdits|plan|bypassPermissions — target when auto is unavailable
# MODEL=                              # e.g. sonnet, opus (empty = claude's own default)
# MEMORY_LIMIT_MB=6144                # NODE_OPTIONS --max-old-space-size guard
# CLAUDE_BIN=claude                   # path or command name for the claude binary
# EXTRA_FLAGS=                        # extra flags appended to every claude invocation
# LIMIT_WATCHER=auto                  # auto|manual|off
# AUTO_TRUST=on-add                   # on-add|always|off
# SHOW_LOGO=true                      # true|false — show the cccc logo on startup
# IDLE_WATCHDOG=off                   # off|on — opt-in RAM reclaim of idle sessions, macOS-only, see docs/IDLE_WATCHDOG.md
```

`install.sh` writes this file (fully commented, at documented defaults) on
first install; it never overwrites an existing one.

### Optional: `cccc settings`

`cccc settings` starts a local, Python-stdlib-only web editor (no npm/pip/CDN
dependencies, fully offline) with two tabs: **Organisation** (the
`projects.conf` project registry) and **Einstellungen** (all 10
`settings.conf` keys, with typed inputs and validation). By default it binds
to `127.0.0.1` and auto-opens your browser. Two orthogonal opt-in flags are
available: `--lan` (bind to all network interfaces, for remote/Tailscale/SSH
access) and `--no-open` (skip the browser auto-open). It requires
**python3** — everything else in cccc works without it. If python3 isn't
installed, `cccc settings` prints a clear error and the rest of cccc is
unaffected.

The older `cccc webui` command remains as a backward-compatible alias for the
same UI, preserving its original default behavior (binds all network
interfaces, does not auto-open the browser) so existing remote-access
workflows keep working unchanged.

## Architecture

```
+------------------+
|    cccc (tmux)   |
|  Terminal-based  |
+--------+---------+
         |
         |  tmux new-session -c <path>
         |  NODE_OPTIONS='--max-old-space-size=6144' \
         |    <flags from settings.conf, via build_claude_launch_cmd()>
         |  (default: PERMISSION_MODE=auto; browser opt-in via -b suffix: adds --chrome)
         |
+--------v-----------+
|   Claude Code CLI  |
|   (per session)    |
|   cwd: correct     |
+--------------------+
```

Sessions are created with `tmux new-session -c <project-path>` which natively preserves the working directory. Claude Code inherits the cwd directly — no wrapper scripts or environment variable tricks required. Browser support (Claude-in-Chrome) is opt-in per session via the `-b` suffix rather than always-on, to keep the default per-session footprint small.

## FAQ / Troubleshooting

**Q: `cccc settings` says python3 is required — do I need it for normal usage?**
No. `python3` is only required for the optional `cccc settings` (or its
`cccc webui` alias) local web editor. The dashboard, session management, and
cleanup commands work without it.

**Q: Sessions start in the wrong directory.**
Create a fresh session — cccc always uses `tmux new-session -c <path>`. If the
issue persists, check `~/.config/claude-control/projects.conf` for the correct
path.

**Q: Orphaned Claude processes are piling up.**
Run `cccc cleanup -n` for a dry-run, then `cccc cleanup` to kill them. See
[Update Guide](docs/UPDATE_GUIDE.md) for the optional launchd schedule.

### Remote usage (SSH / Tailscale / Termius)

By default, `cccc settings` binds only to `127.0.0.1` (local machine only).
To expose it to another device on your network, use the explicit `--lan`
opt-in (`cccc settings --lan`) — or the `cccc webui` alias, which still binds
to your machine's network interfaces by default for backward compatibility.
Either way, this is a generic remote-access pattern, not something specific
to any one tool:

- **SSH port forwarding**: `ssh -L 8000:localhost:<port> user@your-mac` and then
  open `http://localhost:8000` locally.
- **A mesh VPN (e.g. Tailscale)**: install it on both the host machine and the
  remote device, then reach the host's Tailscale IP directly — no port
  forwarding needed, and the connection stays private to your own network.
- **An SSH terminal app on mobile** (Termius is one example client): use it to
  SSH into the host machine and attach to a `cccc`-managed tmux session
  directly from a phone or tablet, independent of the WebUI.

None of these require cccc-specific configuration — they're standard ways to
reach a service bound to a machine you can already SSH into.

## Documentation

- [Setup Guide](docs/SETUP.md) - Complete installation instructions
- [cccc Reference](docs/CC_REFERENCE.md) - Full cccc command reference
- [Update Guide](docs/UPDATE_GUIDE.md) - How to update an existing install
- [Idle Watchdog](docs/IDLE_WATCHDOG.md) - Optional RAM-reclaim daemon for idle sessions (opt-in, default off)
- [Contributing](CONTRIBUTING.md) - Running tests, plugin authoring, release process
- [Changelog](CHANGELOG.md) - All changes and version history

## Development

cccc is built with [GSD](https://github.com/open-gsd/gsd-core) (Git. Ship. Done.), an agent-driven workflow of plan → build → verify with structured code-review passes. Short tags in code comments like `CR-01`, `WR-02`, `QA-03`, `TRUST-01` are review-finding provenance markers kept intentionally as an audit trail — not external or broken references.

## License

- cccc: [MIT License](LICENSE)

## Acknowledgments

- Claude Code by Anthropic
