#!/bin/bash
# test-exact-match.sh — Phase 10 Plan 03 (CLEANUP-03/04, CR-01 carry-over)
# regression test for the '=' exact-match + empty-target guard fix applied to
# is_watcher_active()/start_limit_watcher()/stop_limit_watcher()/kill_session()
# in cc/cc.
#
# Proves two Tampering-class bugs (09-REVIEW.md CR-01) are closed:
#   1. Prefix collision: a session name that is a PREFIX of another live
#      session's name must never be affected by a kill/stop targeting the
#      shorter name (tmux's default -t matching is prefix-based, not exact).
#   2. Empty-target kill: an empty session name must never issue a live
#      tmux kill-session/has-session call (the "current session" footgun).
#
# MANDATORY per CLAUDE.md "tmux in Test-Suites & Skripten — Pflicht-Sandbox"
# (QA-03): this test spawns REAL tmux sessions, so it unsets TMUX and uses a
# private per-PID TMUX_TMPDIR before any tmux call, and tears down via
# `tmux kill-server` (scoped to that private socket) + `rm -rf`. Every
# kill-session/has-session target in the test itself is guarded non-empty and
# uses exact names — never the default socket, never an empty -t.
#
# Run: bash cc/test-exact-match.sh
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
TMUX_TMPDIR="/tmp/cc-exactmatch-$$"
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
# Test 1: is_watcher_active "" returns non-zero and issues NO tmux call
# (empty-target guard). We cannot directly observe "no tmux call was made",
# so we assert the documented contract: non-zero return on empty input.
# ---------------------------------------------------------------------------

if ! is_watcher_active ""; then
    pass "empty-target/is_watcher_active-returns-nonzero"
else
    fail "empty-target/is_watcher_active-returns-nonzero"
fi

# ---------------------------------------------------------------------------
# Test 2: prefix collision on limit-watcher-* sessions. With live sessions
# limit-watcher-foo and limit-watcher-foo-2, stop_limit_watcher "foo" must
# kill ONLY limit-watcher-foo; limit-watcher-foo-2 must survive.
# ---------------------------------------------------------------------------

tmux new-session -d -s "limit-watcher-foo" -- sleep 300
tmux new-session -d -s "limit-watcher-foo-2" -- sleep 300
sleep 1

stop_limit_watcher "foo" >/dev/null

if ! tmux has-session -t "=limit-watcher-foo" 2>/dev/null; then
    pass "prefix-collision/limit-watcher-foo-killed"
else
    fail "prefix-collision/limit-watcher-foo-killed" "target session still alive"
fi

if tmux has-session -t "=limit-watcher-foo-2" 2>/dev/null; then
    pass "prefix-collision/limit-watcher-foo-2-survives"
else
    fail "prefix-collision/limit-watcher-foo-2-survives" "sibling session was killed — prefix match bug"
fi

# Teardown (guarded non-empty, exact target).
[[ -n "limit-watcher-foo-2" ]] && tmux kill-session -t "=limit-watcher-foo-2" 2>/dev/null

# ---------------------------------------------------------------------------
# Test 3: prefix collision on cc-* sessions. With live sessions cc-foo and
# cc-foo-2, kill_session "cc-foo" must kill ONLY cc-foo; cc-foo-2 survives.
# ---------------------------------------------------------------------------

tmux new-session -d -s "cc-foo" -- sleep 300
tmux new-session -d -s "cc-foo-2" -- sleep 300
sleep 1

kill_session "cc-foo" >/dev/null 2>&1

if ! tmux has-session -t "=cc-foo" 2>/dev/null; then
    pass "prefix-collision/cc-foo-killed"
else
    fail "prefix-collision/cc-foo-killed" "target session still alive"
fi

if tmux has-session -t "=cc-foo-2" 2>/dev/null; then
    pass "prefix-collision/cc-foo-2-survives"
else
    fail "prefix-collision/cc-foo-2-survives" "sibling session was killed — prefix match bug"
fi

# Teardown (guarded non-empty, exact target).
[[ -n "cc-foo-2" ]] && tmux kill-session -t "=cc-foo-2" 2>/dev/null

# ---------------------------------------------------------------------------
# Test 4: kill_session "" performs NO tmux kill-session (empty-target guard),
# asserted by confirming an unrelated live session on the private socket
# survives an empty-target kill attempt.
# ---------------------------------------------------------------------------

tmux new-session -d -s "cc-sentinel" -- sleep 300
sleep 1

kill_session "" >/dev/null 2>&1

if tmux has-session -t "=cc-sentinel" 2>/dev/null; then
    pass "empty-target/kill_session-no-op"
else
    fail "empty-target/kill_session-no-op" "sentinel session was killed — empty-target kill fired"
fi

# Teardown (guarded non-empty, exact target).
[[ -n "cc-sentinel" ]] && tmux kill-session -t "=cc-sentinel" 2>/dev/null

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo "RESULT: $FAIL failures"
exit $(( FAIL > 0 ? 1 : 0 ))
