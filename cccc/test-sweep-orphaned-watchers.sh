#!/bin/bash
# test-sweep-orphaned-watchers.sh — Phase 10 Plan 03 (CLEANUP-03/04) regression
# test for cc/cc's sweep_orphaned_watchers(), the in-process replacement for the
# retired scripts/watcher-cleanup.sh launchd daemon.
#
# Proves:
#   1. A limit-watcher-* session whose target session is still alive is KEPT.
#   2. A limit-watcher-* session whose target session no longer exists (orphan)
#      is KILLED.
#   3. A malformed limit-watcher- session (empty suffix) is SKIPPED, never
#      killed with an empty target.
#   4. Exact-match: a limit-watcher-a orphan is unaffected by the existence of
#      limit-watcher-ab's target (no prefix-match false negative).
#
# MANDATORY per CLAUDE.md "tmux in Test-Suites & Skripten — Pflicht-Sandbox"
# (QA-03): this test spawns REAL tmux sessions, so it unsets TMUX and uses a
# private per-PID TMUX_TMPDIR before any tmux call, and tears down via
# `tmux kill-server` (scoped to that private socket) + `rm -rf`. Every
# kill-session/has-session target in the test itself is guarded non-empty and
# uses exact names — never the default socket, never an empty -t.
#
# Run: bash cc/test-sweep-orphaned-watchers.sh
# Exit 0 = all assertions pass; Exit 1 = one or more failures.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CC="$SCRIPT_DIR/cccc"

FAIL=0

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1${2:+ ($2)}"; FAIL=$(( FAIL + 1 )); }

# ---------------------------------------------------------------------------
# Sandbox setup (MANDATORY, QA-03): never touch the user's default tmux
# server. unset TMUX (it beats TMUX_TMPDIR when tmux resolves "current
# session") and point every tmux call at a private per-PID socket dir,
# created BEFORE any tmux invocation.
# ---------------------------------------------------------------------------

unset TMUX
TMUX_TMPDIR="/tmp/cc-sweeporphan-$$"
mkdir -p "$TMUX_TMPDIR"
export TMUX_TMPDIR

cleanup() {
    tmux kill-server 2>/dev/null
    rm -rf "$TMUX_TMPDIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Load the REAL cc/cc functions without launching the dashboard. Point
# CC_PLUGINS_DIR at an empty, nonexistent sandbox dir BEFORE sourcing so
# load_plugins() (invoked unconditionally at source-time, even under CC_TEST=1)
# never loads this machine's real local plugins
# (~/.config/claude-control/plugins/*.sh) into the test shell.
# ---------------------------------------------------------------------------

export CC_PLUGINS_DIR="$TMUX_TMPDIR/no-plugins-here"
CC_TEST=1 source "$CC"

# ---------------------------------------------------------------------------
# Fixture setup.
#
#   limit-watcher-alive  + live target session "alive"        -> KEPT
#   limit-watcher-dead   + NO target session "dead"            -> KILLED (orphan)
#   limit-watcher-       (malformed, empty suffix)              -> SKIPPED
#   limit-watcher-a      + NO target session "a"                -> KILLED (orphan)
#   limit-watcher-ab     + live target session "ab"             -> KEPT
#     (proves limit-watcher-a's orphan-kill is unaffected by "ab" existing)
# ---------------------------------------------------------------------------

tmux new-session -d -s "alive" -- sleep 300
tmux new-session -d -s "ab" -- sleep 300
tmux new-session -d -s "limit-watcher-alive" -- sleep 300
tmux new-session -d -s "limit-watcher-dead" -- sleep 300
tmux new-session -d -s "limit-watcher-" -- sleep 300
tmux new-session -d -s "limit-watcher-a" -- sleep 300
tmux new-session -d -s "limit-watcher-ab" -- sleep 300
sleep 1

sweep_orphaned_watchers

# ---------------------------------------------------------------------------
# Assertions.
# ---------------------------------------------------------------------------

if tmux has-session -t "=limit-watcher-alive" 2>/dev/null; then
    pass "keep/limit-watcher-alive-kept-target-exists"
else
    fail "keep/limit-watcher-alive-kept-target-exists" "watcher was killed even though its target is alive"
fi

if ! tmux has-session -t "=limit-watcher-dead" 2>/dev/null; then
    pass "orphan/limit-watcher-dead-killed"
else
    fail "orphan/limit-watcher-dead-killed" "orphaned watcher survived the sweep"
fi

if tmux has-session -t "=limit-watcher-" 2>/dev/null; then
    pass "malformed/limit-watcher--skipped"
else
    fail "malformed/limit-watcher--skipped" "malformed-name session was killed instead of skipped"
fi

if ! tmux has-session -t "=limit-watcher-a" 2>/dev/null; then
    pass "exact-match/limit-watcher-a-killed-despite-ab-existing"
else
    fail "exact-match/limit-watcher-a-killed-despite-ab-existing" "orphan survived — possible prefix-match false negative from 'ab' target"
fi

if tmux has-session -t "=limit-watcher-ab" 2>/dev/null; then
    pass "exact-match/limit-watcher-ab-kept"
else
    fail "exact-match/limit-watcher-ab-kept" "watcher with a live target was killed"
fi

# ---------------------------------------------------------------------------
# Teardown (guarded non-empty, exact targets — the private socket is destroyed
# wholesale by the trap, but clean up explicitly for clarity/defense-in-depth).
# ---------------------------------------------------------------------------

for s in alive ab limit-watcher-alive limit-watcher-dead "limit-watcher-" limit-watcher-a limit-watcher-ab; do
    [[ -n "$s" ]] && tmux kill-session -t "=$s" 2>/dev/null
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo "RESULT: $FAIL failures"
exit $(( FAIL > 0 ? 1 : 0 ))
