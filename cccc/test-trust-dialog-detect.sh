#!/bin/bash
# test-trust-dialog-detect.sh — Phase 10 Plan 05 (TRUST-05) fixture-based unit
# tests for cc/cc's get_trust_dialog_marker() detector.
#
# Live reproduction of the real folder-trust dialog was unreliable across 4
# attempts (10-RESEARCH.md Pitfall 2) — this test NEVER spawns a real tmux
# session or dialog. `tmux` is stubbed to a bash function that echoes one of
# four fixture strings for `capture-pane`, so the detector's grep logic is
# exercised deterministically and independent of any live Claude Code process.
#
# Run: bash cc/test-trust-dialog-detect.sh
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
# never sources the maintainer's real local plugins into this test's
# shell — matches the isolation convention established by
# cc/test-auto-trust.sh.
# ---------------------------------------------------------------------------
TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/cc-trust-dialog-test-home-XXXXXX")"
cleanup() { rm -rf "$TEST_HOME"; }
trap cleanup EXIT
export HOME="$TEST_HOME"

CC_TEST=1 source "$CC"

# ---------------------------------------------------------------------------
# Stub tmux: capture-pane returns the fixture set in $FIXTURE_PANE_TEXT.
# Any other subcommand is a silent no-op success (return 0) — this test only
# exercises get_trust_dialog_marker(), which uses capture-pane exclusively.
# ---------------------------------------------------------------------------
FIXTURE_PANE_TEXT=""
tmux() {
    case "$1" in
        capture-pane)
            printf '%s' "$FIXTURE_PANE_TEXT"
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Case 1: legacy phrasing match — "Do you trust the files in this folder?"
# ---------------------------------------------------------------------------
FIXTURE_PANE_TEXT="Claude Code
Do you trust the files in this folder?
  1. Yes, proceed
  2. No, exit"
out="$(get_trust_dialog_marker "sess-legacy")"
if [[ -n "$out" && "$out" == *"waiting for trust"* ]]; then
    pass "legacy-phrasing/matches-and-emits-marker"
else
    fail "legacy-phrasing/matches-and-emits-marker" "out='$out'"
fi

# ---------------------------------------------------------------------------
# Case 2: newer phrasing match — "is this a project you created or one you
# trust"
# ---------------------------------------------------------------------------
FIXTURE_PANE_TEXT="Claude Code
Is this a project you created or one you trust?
  Yes / No"
out="$(get_trust_dialog_marker "sess-newer")"
if [[ -n "$out" && "$out" == *"waiting for trust"* ]]; then
    pass "newer-phrasing/matches-and-emits-marker"
else
    fail "newer-phrasing/matches-and-emits-marker" "out='$out'"
fi

# ---------------------------------------------------------------------------
# Case 3: non-match — normal chat output emits EMPTY, never an error.
# ---------------------------------------------------------------------------
FIXTURE_PANE_TEXT="Claude Code
> Fix the login button bug
I'll look into the login button issue now.
Reading src/components/Login.tsx..."
out="$(get_trust_dialog_marker "sess-normal")"
rc=$?
if [[ -z "$out" ]]; then
    pass "non-match/emits-empty"
else
    fail "non-match/emits-empty" "out='$out'"
fi
if [[ "$rc" -eq 0 ]]; then
    pass "non-match/returns-0"
else
    fail "non-match/returns-0" "rc=$rc"
fi

# ---------------------------------------------------------------------------
# Case 4: independence from CC_SET_AUTO_TRUST — matches identically with the
# setting off / on-add / always.
# ---------------------------------------------------------------------------
FIXTURE_PANE_TEXT="Do you trust the files in this folder?"
for mode in off on-add always; do
    CC_SET_AUTO_TRUST="$mode"
    out="$(get_trust_dialog_marker "sess-independence-$mode")"
    if [[ -n "$out" && "$out" == *"waiting for trust"* ]]; then
        pass "independence/CC_SET_AUTO_TRUST=$mode/still-matches"
    else
        fail "independence/CC_SET_AUTO_TRUST=$mode/still-matches" "out='$out'"
    fi
done
unset CC_SET_AUTO_TRUST

# ---------------------------------------------------------------------------
# Case 5: capture-pane failure (session gone / tmux error) — detector must
# still return 0 and emit nothing, never blocking the dashboard render.
# ---------------------------------------------------------------------------
tmux() { return 1; }
out="$(get_trust_dialog_marker "sess-gone")"
rc=$?
if [[ -z "$out" && "$rc" -eq 0 ]]; then
    pass "capture-pane-failure/silent-and-returns-0"
else
    fail "capture-pane-failure/silent-and-returns-0" "out='$out' rc=$rc"
fi

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
echo ""
if [[ "$FAIL" -eq 0 ]]; then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "$FAIL TEST(S) FAILED"
    exit 1
fi
