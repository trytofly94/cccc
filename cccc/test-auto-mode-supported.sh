#!/bin/bash
# test-auto-mode-supported.sh — Phase 14 Plan 02 (BRAND-05, D-09/D-10)
# fixture-based unit tests for cc/cc's auto_mode_supported() proactive
# model-entitlement check and its cc_permission_flag() integration
# (including the backend-session safe-fallback special case, T-14-05).
#
# Run: bash cc/test-auto-mode-supported.sh
# Exit 0 = all assertions pass; Exit 1 = one or more failures.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CC="$SCRIPT_DIR/cccc"

FAIL=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1${2:+ ($2)}"; FAIL=$(( FAIL + 1 )); }

# ---------------------------------------------------------------------------
# Redirect HOME to a private per-test temp dir BEFORE sourcing cc/cc, so
# load_plugins() finds no ~/.config/claude-control/plugins directory and
# never sources the maintainer's real local plugins into this test's shell —
# matches the isolation convention established by cc/test-auto-trust.sh.
# ---------------------------------------------------------------------------
TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/cc-auto-mode-test-home-XXXXXX")"
cleanup() {
    rm -rf "$TEST_HOME"
    # cc_permission_flag's one-time-warning sentinel is PID-keyed ($$) — clean
    # up this test process's own sentinel file so repeated local test runs
    # never start "pre-warned".
    rm -f "${TMPDIR:-/tmp}/.cccc-auto-fallback-warned.$$"
    rm -f $TEST_HOME/stderr.log
}
trap cleanup EXIT
export HOME="$TEST_HOME"

CC_TEST=1 source "$CC"

# ---------------------------------------------------------------------------
# auto_mode_supported() classification
# ---------------------------------------------------------------------------
if auto_mode_supported "opus"; then
    pass "auto_mode_supported/opus-alias-entitled"
else
    fail "auto_mode_supported/opus-alias-entitled"
fi

if auto_mode_supported "sonnet"; then
    pass "auto_mode_supported/sonnet-alias-entitled"
else
    fail "auto_mode_supported/sonnet-alias-entitled"
fi

if auto_mode_supported ""; then
    pass "auto_mode_supported/empty-model-is-claude-default-entitled"
else
    fail "auto_mode_supported/empty-model-is-claude-default-entitled"
fi

if ! auto_mode_supported "claude-3-5-haiku"; then
    pass "auto_mode_supported/pre-4.6-haiku-unentitled"
else
    fail "auto_mode_supported/pre-4.6-haiku-unentitled"
fi

# ---------------------------------------------------------------------------
# cc_permission_flag() — non-auto modes pass through unchanged, regardless
# of backend arg, and never consult auto_mode_supported.
# ---------------------------------------------------------------------------
CC_SET_PERMISSION_MODE="plan"
CC_SET_MODEL="claude-3-5-haiku"
out="$(cc_permission_flag 2>/dev/null)"
if [[ "$out" == "--permission-mode plan" ]]; then
    pass "cc_permission_flag/non-auto-mode-passthrough"
else
    fail "cc_permission_flag/non-auto-mode-passthrough" "out='$out'"
fi

out="$(cc_permission_flag "mybackend" 2>/dev/null)"
if [[ "$out" == "--permission-mode plan" ]]; then
    pass "cc_permission_flag/non-auto-mode-passthrough-with-backend-arg"
else
    fail "cc_permission_flag/non-auto-mode-passthrough-with-backend-arg" "out='$out'"
fi

# ---------------------------------------------------------------------------
# cc_permission_flag() — auto mode, non-backend, entitled model -> auto,
# no warning.
# ---------------------------------------------------------------------------
CC_SET_PERMISSION_MODE="auto"
CC_SET_MODEL="opus"
unset CC_AUTO_FALLBACK_WARNED 2>/dev/null || true
out="$(cc_permission_flag 2>$TEST_HOME/stderr.log)"
warn="$(cat $TEST_HOME/stderr.log)"
if [[ "$out" == "--permission-mode auto" ]]; then
    pass "cc_permission_flag/auto-entitled-model-emits-auto"
else
    fail "cc_permission_flag/auto-entitled-model-emits-auto" "out='$out'"
fi
if [[ -z "$warn" ]]; then
    pass "cc_permission_flag/auto-entitled-model-no-warning"
else
    fail "cc_permission_flag/auto-entitled-model-no-warning" "warn='$warn'"
fi

# ---------------------------------------------------------------------------
# cc_permission_flag() — auto mode, non-backend, unentitled model ->
# PERMISSION_MODE_FALLBACK (default = "default") + one-time warning (not
# re-printed on second call). Public safety posture (Phase 14 reconciliation):
# the shipped default fallback is permission-prompting, never unattended.
# ---------------------------------------------------------------------------
CC_SET_PERMISSION_MODE="auto"
unset CC_SET_PERMISSION_MODE_FALLBACK 2>/dev/null || true
CC_SET_MODEL="claude-3-5-haiku"
unset CC_AUTO_FALLBACK_WARNED 2>/dev/null || true
out="$(cc_permission_flag 2>$TEST_HOME/stderr.log)"
warn1="$(cat $TEST_HOME/stderr.log)"
if [[ "$out" == "--permission-mode default" ]]; then
    pass "cc_permission_flag/auto-unentitled-model-falls-back-to-default"
else
    fail "cc_permission_flag/auto-unentitled-model-falls-back-to-default" "out='$out'"
fi
if [[ -n "$warn1" ]]; then
    pass "cc_permission_flag/auto-unentitled-model-warns-once-first-call"
else
    fail "cc_permission_flag/auto-unentitled-model-warns-once-first-call" "warn1='$warn1'"
fi

out2="$(cc_permission_flag 2>$TEST_HOME/stderr.log)"
warn2="$(cat $TEST_HOME/stderr.log)"
if [[ "$out2" == "--permission-mode default" && -z "$warn2" ]]; then
    pass "cc_permission_flag/auto-unentitled-model-second-call-no-repeat-warning"
else
    fail "cc_permission_flag/auto-unentitled-model-second-call-no-repeat-warning" "out2='$out2' warn2='$warn2'"
fi

# ---------------------------------------------------------------------------
# cc_permission_flag() — PERMISSION_MODE_FALLBACK is configurable: an
# unentitled model honors whatever fallback target the user configured,
# not a hardcoded value. Covers bypassPermissions (opt-in unattended) and
# acceptEdits (a third distinct target) to prove it's not just a 2-way switch.
# ---------------------------------------------------------------------------
CC_SET_PERMISSION_MODE="auto"
CC_SET_MODEL="claude-3-5-haiku"

CC_SET_PERMISSION_MODE_FALLBACK="bypassPermissions"
rm -f "${TMPDIR:-/tmp}/.cccc-auto-fallback-warned.$$"
outf1="$(cc_permission_flag 2>/dev/null)"
if [[ "$outf1" == "--permission-mode bypassPermissions" ]]; then
    pass "cc_permission_flag/fallback-configurable-bypassPermissions"
else
    fail "cc_permission_flag/fallback-configurable-bypassPermissions" "outf1='$outf1'"
fi

CC_SET_PERMISSION_MODE_FALLBACK="acceptEdits"
rm -f "${TMPDIR:-/tmp}/.cccc-auto-fallback-warned.$$"
outf2="$(cc_permission_flag 2>/dev/null)"
if [[ "$outf2" == "--permission-mode acceptEdits" ]]; then
    pass "cc_permission_flag/fallback-configurable-acceptEdits"
else
    fail "cc_permission_flag/fallback-configurable-acceptEdits" "outf2='$outf2'"
fi
unset CC_SET_PERMISSION_MODE_FALLBACK 2>/dev/null || true

# ---------------------------------------------------------------------------
# cc_permission_flag() — auto mode, backend session (non-empty first arg):
# ALWAYS degrades to PERMISSION_MODE_FALLBACK, even with an entitled
# CC_SET_MODEL, because auto_mode_supported is skipped entirely for backend
# sessions (T-14-05). Uses the shipped default fallback ("default") here —
# the configurability itself is already covered above.
# ---------------------------------------------------------------------------
CC_SET_PERMISSION_MODE="auto"
CC_SET_MODEL="opus"
unset CC_SET_PERMISSION_MODE_FALLBACK 2>/dev/null || true
unset CC_AUTO_FALLBACK_WARNED 2>/dev/null || true
rm -f "${TMPDIR:-/tmp}/.cccc-auto-fallback-warned.$$"
outb="$(cc_permission_flag "mybackend" 2>$TEST_HOME/stderr.log)"
rm -f $TEST_HOME/stderr.log
if [[ "$outb" == "--permission-mode default" ]]; then
    pass "cc_permission_flag/auto-backend-session-always-falls-back-even-entitled-model"
else
    fail "cc_permission_flag/auto-backend-session-always-falls-back-even-entitled-model" "outb='$outb'"
fi
if [[ "$outb" != *"--permission-mode auto"* ]]; then
    pass "cc_permission_flag/auto-backend-session-never-emits-auto"
else
    fail "cc_permission_flag/auto-backend-session-never-emits-auto" "outb='$outb'"
fi

# ---------------------------------------------------------------------------
# Call site: start_claude_session() must pass "$backend" through.
# ---------------------------------------------------------------------------
if grep -q 'cc_permission_flag "\$backend"' "$CC"; then
    pass "call-site/start_claude_session-passes-backend-arg"
else
    fail "call-site/start_claude_session-passes-backend-arg"
fi

echo ""
if [[ "$FAIL" -eq 0 ]]; then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "$FAIL TEST(S) FAILED"
    exit 1
fi
