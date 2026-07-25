#!/bin/bash
# test-limit-watcher.sh — Phase 9 Plan 02 (LWATCH-04/05/06) automated harness for
# cc/cc's maybe_start_limit_watcher() auto/manual/off gate.
#
# Verifies: LIMIT_WATCHER=auto starts the watcher, manual/off do not, the gate
# never aborts the caller's control flow (always returns 0), and the structural
# wiring (5 gated call sites, vendored path present / old skills-dir path
# absent, watch<number> manual path still ungated).
#
# Run: bash cc/test-limit-watcher.sh
# Exit 0 = all assertions pass; Exit 1 = one or more failures.
#
# NOTE: this test is pure sourcing + a stubbed start_limit_watcher() — it never
# spawns a real tmux session and never reads/writes
# ~/.config/claude-control/settings.conf (CC_SET_LIMIT_WATCHER is assigned
# directly in this shell). If any FUTURE extension of this file spawns a real
# `limit-watcher-*` tmux session, it MUST use the private per-PID-socket
# sandbox (unset TMUX, set a per-PID TMUX_TMPDIR, guard every kill target) per
# the global tmux-test-isolation rule (QA-03).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CC="$SCRIPT_DIR/cccc"

FAIL=0

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1${2:+ ($2)}"; FAIL=$(( FAIL + 1 )); }

# ---------------------------------------------------------------------------
# Load cc/cc's functions without launching the dashboard, then stub the real
# watcher-spawning function so no tmux session is ever created. Point
# CC_PLUGINS_DIR at an empty, nonexistent sandbox dir BEFORE sourcing so
# load_plugins() (invoked unconditionally at source-time, even under CC_TEST=1)
# never loads this machine's real local plugins
# (~/.config/claude-control/plugins/*.sh) into the test shell.
# ---------------------------------------------------------------------------

export CC_PLUGINS_DIR="${TMPDIR:-/tmp}/cc-limitwatch-noplugins-$$"
CC_TEST=1 source "$CC"

start_limit_watcher() { echo "STARTED:$1"; }

# ---------------------------------------------------------------------------
# Functional cases: auto starts, manual/off do not, gate always returns 0
# ---------------------------------------------------------------------------

CC_SET_LIMIT_WATCHER=auto
out="$(maybe_start_limit_watcher sX)"
rc=$?
if [[ "$out" == "STARTED:sX" ]]; then
    pass "gate/auto-starts-watcher"
else
    fail "gate/auto-starts-watcher" "output='$out'"
fi
if [[ "$rc" -eq 0 ]]; then
    pass "gate/auto-returns-0"
else
    fail "gate/auto-returns-0" "rc=$rc"
fi

CC_SET_LIMIT_WATCHER=manual
out="$(maybe_start_limit_watcher sX)"
rc=$?
if [[ -z "$out" ]]; then
    pass "gate/manual-does-not-start-watcher"
else
    fail "gate/manual-does-not-start-watcher" "output='$out'"
fi
if [[ "$rc" -eq 0 ]]; then
    pass "gate/manual-returns-0"
else
    fail "gate/manual-returns-0" "rc=$rc"
fi

CC_SET_LIMIT_WATCHER=off
out="$(maybe_start_limit_watcher sX)"
rc=$?
if [[ -z "$out" ]]; then
    pass "gate/off-does-not-start-watcher"
else
    fail "gate/off-does-not-start-watcher" "output='$out'"
fi
if [[ "$rc" -eq 0 ]]; then
    pass "gate/off-returns-0"
else
    fail "gate/off-returns-0" "rc=$rc"
fi

# ---------------------------------------------------------------------------
# Structural cases: grep the source file for the expected wiring
# ---------------------------------------------------------------------------

count=$(grep -c 'maybe_start_limit_watcher "' "$CC")
if [[ "$count" -eq 5 ]]; then
    pass "structure/5-gated-call-sites"
else
    fail "structure/5-gated-call-sites" "found $count"
fi

if grep -q 'CC_SCRIPT_DIR/limit-watcher.sh' "$CC"; then
    pass "structure/vendored-path-present"
else
    fail "structure/vendored-path-present"
fi

if ! grep -qE 'skills/[^/]*/limit-watcher.sh' "$CC"; then
    pass "structure/old-path-absent"
else
    fail "structure/old-path-absent"
fi

if grep -q 'start_limit_watcher "\$sess_name"' "$CC"; then
    pass "structure/watch-number-still-ungated"
else
    fail "structure/watch-number-still-ungated"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo "RESULT: $FAIL failures"
exit $(( FAIL > 0 ? 1 : 0 ))
