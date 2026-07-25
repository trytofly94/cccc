# Changelog

All notable changes to the cccc (Claude Code Control Center) project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [4.0.2] - 2026-07-25

### Changed
- **Interactive `add` — pick a category by letter instead of typing it.** When
  adding a project from the dashboard (`add <path>`), the category step now
  lists the existing categories each with a letter; type the letter to file the
  project under that category, type a new name to create a category, or leave it
  empty for none. Previously you had to remember and retype the exact category
  name. (With no categories yet, it falls back to the free-text prompt.)

## [4.0.1] - 2026-07-25

### Fixed
- **Settings Web UI — anti-DNS-rebinding protection.** Requests whose `Host`
  header does not match the server's bind address are now rejected with `403`
  (and the connection closed). This closes a vector by which a malicious web
  page could reach the localhost/LAN settings API via DNS rebinding and achieve
  code execution through `CLAUDE_BIN`/`EXTRA_FLAGS` on the next session launch.
- **Orphan cleanup no longer kills unrelated daemons.** `claude-cleanup` now
  reaps an orphaned `node`/`bun`/`python` process only when its command line
  shows Claude provenance (references `~/.claude/`, `@anthropic`, an
  `anthropic-ai` path, or a `claude` wrapper). Previously any daemonized
  node/python process older than 24h could be killed (pm2, Jupyter, home-grown
  servers, MCP gateways).
- **`cc json` works on Linux.** Added a GNU `stat -c %Y` fallback; the BSD-only
  `stat -f %m` meant the snapshot cache never refreshed on Linux and could abort
  `cccc json` outright in the lock path.
- **No more infinite render loop on closed stdin** (e.g. `cccc </dev/null`, an
  SSH `exec` with no TTY) — the dashboard and recovery loops now exit on EOF.
- **Project selection codes no longer collide with command suffixes.** With 30+
  projects, `zk`/`zg` were mis-parsed as "kill all sessions in project z" /
  "start a GSD session in project z"; multi-letter codes now never end in a
  command letter, and projects beyond #44 (triple-letter codes) are reachable.
- **Apostrophes in folder names** (e.g. `Client's Work`) no longer break
  the launch — the session started as a bare shell before.
- **Empty-model saves can no longer wipe `projects.conf`.** The Settings Web UI
  refuses an empty project set over a non-empty file (`409`) and disables Save
  until the config has loaded. Web UI writes are now thread-safe (per-request
  temp file), reject `\r`/`\x00` in names/paths, and partial settings `PUT`s
  upsert instead of resetting omitted keys to defaults.
- **Installer now installs `limit-watcher.sh`**, so rate-limit auto-resume works
  after `./install.sh` (the watcher failed silently before).
- Dashboard footer/legend and in-app help are now English and accurate (removed
  the non-working `quit`/`settings` hints; status legend reads
  working/waiting/idle/asleep/stopped).

### Changed
- **The `cc` compatibility symlink is now opt-in** (`./install.sh
  --with-cc-symlink`) so it no longer shadows the system C compiler;
  `link-cc-compat.sh` refuses to overwrite a `cc` it didn't create.
- Installer copies are atomic (temp file + rename); dead variables removed so
  `shellcheck -S warning` (run in CI) is clean; `claude-cleanup` recognizes
  Linux's `?` TTY marker and the launchd plist uses the correct
  `StandardOutPath` key.
- Documentation corrected: the shipped cleanup daemon is
  `com.user.claude-cleanup` (twice daily, 04:00 + 12:00); the settings list is
  the full 10 keys; `cccc list` lists projects; SETUP updated to v4.0.1 /
  bash 3.2+ and now lists `jq` (required) and `python3` (optional).
- Test suites sandbox the plugin directory, drive the logo test under a pty, add
  a `jq` skip-guard, and drop machine-specific temp paths.

## [4.0.0] - 2026-07-16

### Added
- **Redesigned dashboard** — projects are now grouped under the `[Category]`
  headers from `projects.conf`, each category rendered under a full-width
  `──[ Category ]──` divider (underlined name). Sessions nest under their
  project with tree connectors (`├─`/`└─`).
- **Per-category colors** — every category is auto-assigned a distinct color
  applied to its letter chip, title, and divider, so categories are easy to
  tell apart. Overridable from a preset palette in the Settings Web UI
  (Organisation tab → the swatch on a category header); overrides are stored in
  a **separate** `group-colors.conf` (`categoryname|colorname`) so the
  safety-critical `projects.conf` format is never touched. Yellow and red are
  reserved for status and excluded from the palette.
- **Live session status** — each session shows one of `▸ working`, `● waiting`,
  `○ idle`, `💤 asleep`, or `⚫ stopped`. A session that needs your input
  (`waiting`) is flagged with a yellow `►` in the gutter and summarized as
  `N waiting` in the footer legend.
- **`💤 asleep` status** — marks a session whose tmux pane is alive but whose
  Claude process has exited (reclaimed by the opt-in idle-watchdog after idle
  days, or quit manually). It is detected authoritatively from the pane's
  foreground process, independent of tmux attach state, and resumes instantly
  via `claude --resume <session-id>` (not `--continue`). The status is reported
  consistently in both the dashboard and the `cc json` payload (so companion
  clients can distinguish a parked/resumable session from a live-idle one).
- Truecolor palette with a graceful 16-color fallback on terminals that don't
  advertise `COLORTERM`, and a refreshed startup logo.

### Changed
- **`<letter>k` (kill all sessions in a project) now requires confirmation** —
  it prints how many sessions would be killed and waits for an explicit `y`;
  anything else (including a bare Enter) cancels. Previously it killed every
  session in the project immediately on the keypress.
- The dashboard renders progressively again (header first, rows build up) after
  briefly buffering during development; `asleep` rows skip the trust-dialog scan
  (no Claude process to prompt) for a faster paint.

### Added (Settings UI, Web UI, and rename, earlier in the 4.0 line)
- cccc: **`cccc settings`** — a new primary command for the Settings Web UI,
  local-first by default (binds `127.0.0.1`, auto-opens the browser). The web
  UI gained a two-tab layout: **Organisation** (the existing `projects.conf`
  editor, unchanged, default-visible) and a new **Einstellungen** tab exposing
  all 9 `settings.conf` keys (`PERMISSION_MODE`, `PERMISSION_MODE_FALLBACK`,
  `MODEL`, `MEMORY_LIMIT_MB`, `CLAUDE_BIN`, `EXTRA_FLAGS`, `LIMIT_WATCHER`,
  `AUTO_TRUST`, `SHOW_LOGO`) with type-correct widgets (enum dropdowns,
  number/text inputs, a checkbox), backed by new `GET`/`PUT /api/settings`
  endpoints that re-validate every key server-side against the same whitelist
  as `cccc config`/`write_setting()`, write atomically, and back up first. Two
  orthogonal opt-in flags, `--lan` (bind all network interfaces) and
  `--no-open` (suppress browser auto-open), are combinable with either
  `cccc settings` or the pre-existing `cccc webui` alias, whose own no-flag
  default is unchanged (binds all interfaces, does not auto-open). The
  dashboard's status line is now Settings-branded (`⚙ Settings:`) and reports
  a bind-aware URL — `127.0.0.1` under the local-only default, a LAN IP only
  for an actual `0.0.0.0`/`::` bind — so the surfaced link always resolves.
- cc: **`cc webui`** — a local, self-contained web editor for `projects.conf`.
  Starts a Python-stdlib-only HTTP server (zero npm/pip/CDN, fully offline) bound
  to `127.0.0.1` and opens the default browser. Supports add/remove projects,
  HTML5 drag-and-drop reorder within and across sections (order drives the a–z
  dashboard letters, reserved h/n/q/r), and full section management
  (add/rename/delete/reorder). Saves are byte-compatible with cc's parser, written
  atomically (temp file + `os.replace`) after a timestamped backup
  (`projects.conf.bak-<timestamp>`). New file `cccc/cc-webui.py`. Note: free-floating
  `#` comments are not preserved on save (none exist today; the backup retains any
  prior content).
- cc: **`cc webui` external access** — `cc webui` now binds `0.0.0.0` (all
  interfaces) so the editor is reachable over the local IP and Tailscale, and
  prints the reachable URLs (local / LAN / Tailscale, auto-detected) instead of
  auto-opening the browser — copy the link onto whatever device you're using. The
  server is multi-threaded (concurrent clients) and prints a NO-AUTHENTICATION
  warning plus a macOS-firewall hint. Use `cc webui --local` for the previous
  127.0.0.1-only + auto-open behavior. `cc-webui.py` gains a `--host` flag.
- cc: **WebUI link in the dashboard** — when a `cc webui` server is running, the
  `cc` dashboard shows its copyable LAN URL (`http://<lan-ip>:<port>`) as the very
  first line; a faint "not running" hint shows otherwise. Port is auto-detected
  from the live process; the LAN IP resolves via the default-route interface
  (macOS `ipconfig`, Linux `hostname -I` fallback). Detection is zero-cost when no
  server runs (pgrep short-circuits before lsof).
- rename: **cc → cccc** — the tool's public-facing name is now `cccc`; `cc`
  remains as a transitional symlink so existing integrations (including CC
  Pocket's SSH-driven `cc json` calls) keep working unchanged.

### Changed (earlier in the 4.0 line)
- install: `./install.sh` copies `cccc`, `cc-webui.py`, and `limit-watcher.sh`
  into `~/.local/bin` (atomic temp-file + rename); re-run the installer to update
  (see UPDATE_GUIDE.md).
- cc: `cc limit` is now a persistent **Limit Watcher Manager**. Start/stop background
  limit-watcher daemons per session; the dashboard shows 🔍 for sessions with an active
  watcher. Watchers run as `limit-watcher-<session>` tmux sessions and persist after
  closing the menu.
- cc: Limit Watcher Manager now lists **all** tmux sessions (not just `claude-*`) —
  sessions started by other tools are visible and watchable too.
- cc: `limit-watcher-*` and other background daemon sessions are hidden from the main
  dashboard and free sessions list — they appear only as 🔍 indicators on the watched session.
- cc: Limit Watcher Manager and dashboard are now fully bash 3.2 compatible (macOS system
  shell): replaced `declare -A` associative arrays with `grep`-based lookup, and `${var,,}`
  lowercase with `tr`.
- `limit-watcher.sh`: startup output reduced to one line on stdout; full detail goes to
  log file only (`tail -f ~/.local/log/gsd-limit-watcher-<slug>.log`).

## [3.1.0] - 2026-06-05

### Added
- cc: `recover` command (also `RECOVER`) — enters recovery mode from the dashboard, listing
  closed Claude Code sessions with project name, last-active time, and a one-line summary.
  Type a session number to resume it via `claude --resume`; press `q` to return to the
  main dashboard without starting a session. The command is now listed in `h`/`help`.

## [3.0.0] - 2026-05-09

### Removed
- **HAPI middleware layer**: cc now calls `claude` directly in tmux sessions
- HAPI LaunchAgent (`com.hapi.server.plist`) — no longer needed
- HAPI wrapper script (`/opt/homebrew/bin/hapi`) — no longer needed
- HAPI Fork component and all associated TypeScript infrastructure
- `HAPI_WORKING_DIR` working directory mechanism — tmux `-c` flag handles cwd natively

### Changed
- **cc session creation**: `start_claude_session()` now invokes `claude --dangerously-skip-permissions --model sonnet` directly
- **Chrome Automations**: squash-mittwoch.sh and squash-dienstag.sh use `claude -p` directly via tmux
- Project CLAUDE.md updated to reflect direct-claude architecture
- README.md updated to remove HAPI Fork component description

### Migration Notes
- No user action required — existing tmux sessions continue unaffected
- `hapi` command no longer available (binary removed)
- Working directories are now preserved natively via `tmux new-session -c <path>`

## [0.2.0] - 2026-01-22

### Added
- Comprehensive working directory fix implementation
- Debug logging system for wrapper and core functions
- Automated test scripts for session verification
- Session cleanup utilities for old cached sessions
- Comprehensive troubleshooting documentation
- Improved parsing robustness for the autonomous-workflow companion tooling used
  during development (not part of this public repo's shipped Core)

### Fixed
- **Critical: Sessions now start in correct project directories**
- **Critical: workflow-status parsing failure** - fixed incorrect parsing of status
  documents with various header formats (##, ###, ####, etc.) and completion markers

### Changed
- Working directory preservation mechanism implemented and verified

## [0.1.0] - 2026-01-20

### Added
- Initial cccc (Claude Code Control Center) setup with session management
- cc (Claude Code Control Center) - Terminal-based tmux session manager
- Shared project registry (`~/.config/claude-control/projects.conf`)
- Comprehensive setup documentation
- Architecture documentation

### Features

#### cc (Claude Code Control Center)
- Interactive dashboard showing all Claude sessions
- Quick project switching with letter-based keyboard shortcuts
- Session creation, attachment, and management
- Project registry with custom names and paths
- Visual status indicators (active/detached/stopped)
- Support for various Claude Code flags (--continue, --resume, --permission-mode plan, etc.)

### Documentation
- Complete setup guide (docs/SETUP.md)
- cc reference guide (docs/CC_REFERENCE.md)
- Architecture overview in README.md

## Support

For issues, questions, or contributions:
- GitHub Issues: https://github.com/trytofly94/cccc/issues
- Documentation: See docs/ directory

---

**Legend:**
- `Added` - New features
- `Changed` - Changes in existing functionality
- `Deprecated` - Soon-to-be removed features
- `Removed` - Removed features
- `Fixed` - Bug fixes
- `Security` - Vulnerability fixes
