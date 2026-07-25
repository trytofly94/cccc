# Contributing to cccc

Thanks for your interest in contributing. This document covers how to run the
test suite locally, how the plugin system works if you want to extend cccc
without modifying Core, and how this public repo relates to the private
development flow it's synced from.

## Running the tests locally

cccc's tests are plain bash scripts under `cccc/`, each self-contained and
runnable directly — no test runner or package manager required.

1. **Clone the repo** and `cd` into it.
2. **Run the whole suite** by globbing `cccc/test-*.sh` — this is exactly what CI
   does, so the list never goes stale as tests are added or removed:

   ```bash
   for t in cccc/test-*.sh; do
     echo "=== $t ==="
     bash "$t" || { echo "FAILED: $t"; break; }
   done
   ```

   The suite currently ships 13 scripts (`test-about-logo`,
   `test-auto-mode-supported`, `test-auto-trust`, `test-exact-match`,
   `test-idle-watchdog-gate`, `test-idle-watchdog-sync`, `test-limit-watcher`,
   `test-limit-watcher-injection`, `test-plugin-loader`,
   `test-settings-injection`, `test-settings-webui`,
   `test-sweep-orphaned-watchers`, `test-trust-dialog-detect`). To run just one,
   invoke it directly, e.g. `bash cccc/test-plugin-loader.sh`.

3. **Check the exit code.** Every script follows the same convention: exit `0`
   means all assertions passed, exit `1` means one or more failed. The loop above
   stops at the first non-zero exit so you can debug it.

4. **tmux-spawning tests are sandboxed.** A few tests (`test-exact-match.sh`,
   `test-limit-watcher-injection.sh`, `test-sweep-orphaned-watchers.sh`) spawn
   real tmux sessions. They unset `TMUX` and use a private, per-PID
   `TMUX_TMPDIR` before any tmux call, and tear down via `tmux kill-server`
   scoped to that private socket. They never touch your default tmux server or
   any session you already have running — see the header comment in each file
   for the exact mechanism if you're extending them.

5. **Some tests use fixture `HOME` redirection.** `test-auto-trust.sh`
   redirects `HOME` to a private per-PID temp directory before sourcing
   `cccc/cccc`, so it never reads or writes your real `~/.claude.json`.

When adding a new bash source file, add a matching `test-<name>.sh` alongside
it and wire it into your own CI/PR description the same way the existing
tests are structured — self-contained, exit-code driven, and sandboxed against
real state (tmux sessions, `$HOME`, config files) wherever the code under test
touches them.

## Plugin authoring

cccc's Core (`cccc/cccc`) intentionally has no built-in support for
alternative backend definitions, custom dashboard integrations, or
session-lifecycle hooks beyond what ships in this repo. Instead, Core exposes
a small, stable **hook-point contract** that optional local plugins can
implement.

### How plugins load

Plugins are plain bash files at:

```
~/.config/claude-control/plugins/*.sh
```

This directory is **not part of the repo** and is never synced publicly —
it's your own local extension point. On startup, cccc sources every `*.sh`
file found there (if the directory exists; its total absence is the normal,
supported "no plugins" state). Each file is sourced with its own shell-option
state isolated from Core and from every other plugin, and a plugin that fails
to source (syntax error, non-zero `exit`) is skipped with a warning rather
than aborting the dashboard.

### The hook points

A plugin defines one or more of the following functions. Core checks whether
each function exists (via `declare -f`) before calling it, so a plugin only
needs to implement the hooks it cares about:

- **Backend resolution hook** — called when a session is started with the
  `<letter>n=<name>` syntax (e.g. to route the session through an alternative
  API endpoint/model). The plugin resolves `<name>` to whatever connection
  details it needs and exposes them back to Core.
- **Dashboard status-column hook** — called once per session row while the
  dashboard renders, so a plugin can contribute an extra status badge or
  indicator column without Core needing to know anything about what that
  badge represents.
- **Session-kill companion hook** — called when a session is killed, so a
  plugin can clean up anything it started alongside that session (e.g. a
  companion background process) without Core needing plugin-specific
  teardown logic.

Core's own code never references a specific plugin, a specific backend name,
or a specific external tool — that separation is what keeps Core generic and
publishable. If you're building a plugin, treat `~/.config/claude-control/`
as your own local sandbox: read whatever config file format you like, define
the hook function(s) you need, and Core will call them at the right time.

### Local-only, never committed

Because plugin files live outside the repo, they're the right place for
anything environment-specific: personal paths, private API keys/tokens,
machine-specific automation. None of that belongs in a pull request against
this repo — Core stays generic, plugins stay local.

## How this repo relates to private development

This is the public export of a Core that's developed and iterated on in a
private working repo, then synced out here on a periodic, repeatable basis.
The exact mechanism — an allowlist-based export script plus a mandatory
leak scan — is documented in `docs/RELEASE-SPLIT.md` (coming in a follow-up
release; if that file doesn't exist yet in your checkout, the sync process
hasn't been published as a doc yet, but the principle holds: Core code here
is always what a stranger needs to run cccc, with nothing private mixed in).

## Pull requests

- Keep changes scoped to Core behavior — anything backend-specific or
  personal-environment-specific belongs in a local plugin (see above), not in
  a PR.
- Run the relevant test scripts locally before opening a PR (see "Running the
  tests locally").
- Describe what you changed and why in the PR description; link an issue if
  one exists.
