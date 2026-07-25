# claude-idle-watchdog (opt-in RAM reclaim)

A long-running, macOS-only launchd daemon that reclaims RAM from idle/abandoned
cccc sessions. **Opt-in and default OFF** — installing it never changes any
running session's behavior until you explicitly enable it.

## Why

A `claude` CLI process's memory never shrinks while it runs (monotonic V8
heap) — only quitting frees it. On a machine running many `cccc` sessions at
once, sessions that were opened, used, and then forgotten about still hold
their full memory footprint indefinitely. `claude-idle-watchdog` is the one
mechanism that actually reclaims that memory instead of just capping it.

## What it does

Two independent policies, both scoped to `cc-*` tmux sessions only:

- **Baseline reaper** — any session **detached AND idle for more than 2
  days** is quit, regardless of memory pressure (obviously abandoned).
- **Pressure valve** — while free memory is **sustained below a floor**
  (default 12%, checked across two consecutive polls), the daemon quits
  idle+detached sessions (oldest-idle first) until pressure clears or a cap
  on quits-per-run is hit.

**Reclaim action is `kill -TERM` of the session's `claude` process — never
`tmux kill-session`, never key injection.** This is safe and loss-free:

- Claude continuously flushes every message to its own session transcript, so
  nothing is lost.
- On SIGTERM, Claude prints its own resume line into the pane:
  `Resume this session with: claude --resume <session-id>`.
- The tmux session, pane, working directory, and scrollback all survive —
  only the foreground `claude` process exits, dropping you to a shell prompt
  in the same pane.

**Resume with `claude --resume <session-id>`, not `--continue`.** With
multiple sessions open in the same project directory, `--continue` resumes
whichever session was most recently active — not necessarily the one you
meant. `--resume <session-id>` is unambiguous.

## Safety guards

- Only operates on `cc-*` sessions; explicitly excludes any session whose
  name matches `limit-watcher-|conductor-|gsd-|watcher-`.
- Never touches a session that is currently attached (someone watching it).
- Refuses to act on an empty/blank session name.
- **Freeze-guard:** before reclaiming, it captures the pane, waits, and
  re-captures — if the content changed (a spinner, streaming output, tool
  results), the session is actively working and is skipped.
- Fails safe: if free-memory% can't be read, it assumes the machine is
  healthy and does nothing.

## The opt-in gate (two independent layers)

This daemon is designed to never run unattended on a machine that never
asked for it:

1. **cccc's `IDLE_WATCHDOG` setting** (`off|on`, default `off`) — editable via
   the terminal `cccc config` menu or `cccc settings` web UI. Flipping it to
   `on` only has any effect if the daemon's launchd job is *already
   installed* (see below) — the setting reconciles an existing installation,
   it never installs one itself.
2. **The daemon re-checks the same setting on every single poll pass** and
   skips all reclaim logic when it's off. This is deliberately redundant with
   (1): the daemon stays inert even if its launchd job gets loaded through
   some path outside of cccc's own control.

**Platform gate:** the daemon checks `uname -s` before doing anything else
and exits cleanly on any non-macOS platform — its memory-pressure signal is
macOS-only.

## Installing

`./install.sh` offers this daemon as an optional step (macOS only, skipped
non-interactively unless you answer the prompt). Accepting the offer:

- copies the daemon script to `~/.local/bin/claude-idle-watchdog`
- writes its launchd job to `~/Library/LaunchAgents/com.user.claude-idle-watchdog.plist`

It deliberately does **not** load or start the daemon — vendoring the files
to disk is a separate step from actually running them. To start it:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.claude-idle-watchdog.plist
```

Then opt in to actual reclaiming via cccc's settings (`cccc config`, option
`IDLE_WATCHDOG`, or the `cccc settings` web UI) — it defaults to `off` even
once the daemon is loaded.

To stop or reload it:

```bash
launchctl bootout gui/$(id -u)/com.user.claude-idle-watchdog
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.claude-idle-watchdog.plist
```

## Verifying and tuning

```bash
# Is it running?
launchctl print gui/$(id -u)/com.user.claude-idle-watchdog | grep -E 'state =|pid ='

# What WOULD it reclaim right now, without side effects
claude-idle-watchdog --dry-run --once

# Tail its log
tail -f ~/.local/log/claude-idle-watchdog.log
```

Tuning knobs (environment variables — set in the launchd plist or your
shell):

| Var | Default | Meaning |
|---|---|---|
| `CIW_POLL` | 60 | seconds between passes |
| `CIW_IDLE_2D` | 172800 | baseline-reaper idle threshold (2 days, in seconds) |
| `CIW_IDLE_PRESSURE` | 1800 | pressure-valve idle threshold (30 min, in seconds) |
| `CIW_FREE_FLOOR` | 12 | engage the pressure valve when free memory % drops below this (sustained) |
| `CIW_MAX_QUITS` | 5 | cap on reclaims per pressure event |
| `CIW_SETTLE` | 3 | pause (seconds) after a reclaim before re-reading pressure |

Flags: `--dry-run` (log only, take no action), `--once` (single pass, useful
for testing).

## Sharp edges — read before setting `IDLE_WATCHDOG=on`

- Getting back into a reclaimed session requires
  `claude --resume <session-id>`, **not** `--continue`. Any tooling or muscle
  memory that assumes `--continue` is equivalent will silently resume the
  wrong conversation if multiple sessions share a project directory.
- macOS-only, opt-in, default off by design. On a shared/multi-user machine,
  don't enable it without understanding that it reclaims *any* idle `cc-*`
  session matching its criteria — not just sessions you personally started.
