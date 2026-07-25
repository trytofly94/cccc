#!/bin/bash
# test-plugin-loader.sh — Phase 8 Plan 01 (PLUG-01) automated harness for
# cc/cc's generic load_plugins() loader.
#
# Verifies: fail-safe skip of a syntax-broken plugin, absorption of a
# top-level `exit` of ANY status (exit 1 AND the exit-0 canary-regression
# case), no set-o leakage from a plugin that runs `set -euo pipefail`, that
# good plugins on either side of the broken/exit fixtures still load, and
# that an absent plugins directory is a silent no-op.
#
# Run: bash cc/test-plugin-loader.sh
# Exit 0 = all assertions pass; Exit 1 = one or more failures.
#
# NOTE: this test is pure sourcing — it never spawns tmux. Any FUTURE
# extension of this file that touches real tmux sessions (e.g. to verify
# cccc_hook_on_kill_session) MUST use the private per-PID-socket sandbox
# (unset TMUX, set a per-PID TMUX_TMPDIR) and must NEVER issue an
# empty-target `kill-session` — see the global tmux-test-isolation rule
# (QA-03), which applies retroactively to any tmux-spawning test written
# before Phase 13 formally lands it.

# NOTE: deliberately NOT `set -u` here — this harness asserts that errexit/
# nounset/pipefail are each OFF in the host shell after sourcing cc/cc (the
# no-leak assertion below); starting the harness itself with nounset ON
# would make that assertion meaningless (it would just observe our own
# baseline instead of detecting a leak from 30-poison.sh).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CC="$SCRIPT_DIR/cccc"

FAIL=0

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1${2:+ ($2)}"; FAIL=$(( FAIL + 1 )); }

# ---------------------------------------------------------------------------
# Temp fixture tree + cleanup
# ---------------------------------------------------------------------------
TESTDIR=$(mktemp -d) || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TESTDIR"' EXIT

mkdir -p "$TESTDIR/plugins"

# 10-good.sh — defines a marker function and a marker variable.
cat > "$TESTDIR/plugins/10-good.sh" <<'ENDPLUGIN'
CC_TEST_MARKER_10="loaded"
cc_test_marker_fn_10() { echo "10-good"; }
ENDPLUGIN

# 20-broken.sh — deliberate syntax error (unterminated string literal).
cat > "$TESTDIR/plugins/20-broken.sh" <<'ENDPLUGIN'
echo "this string is never terminated
ENDPLUGIN

# 30-poison.sh — runs set -euo pipefail at top level, defines a marker.
cat > "$TESTDIR/plugins/30-poison.sh" <<'ENDPLUGIN'
set -euo pipefail
CC_TEST_MARKER_30="loaded"
ENDPLUGIN

# 40-exit.sh — idiomatic non-zero-abort top-level exit.
cat > "$TESTDIR/plugins/40-exit.sh" <<'ENDPLUGIN'
exit 1
ENDPLUGIN

# 41-exit-zero.sh — idiomatic clean-bail guard-clause top-level exit.
# Ordered lexically AFTER 40-exit and BEFORE 50-good: this is the case a
# bare rc check would WRONGLY treat as safe and then real-source into a
# silent cc death (the canary-marker regression this fixture pins).
cat > "$TESTDIR/plugins/41-exit-zero.sh" <<'ENDPLUGIN'
exit 0
ENDPLUGIN

# 50-good.sh — defines a SECOND marker function, ordered after both
# broken/exit fixtures to prove the loader continues past them.
cat > "$TESTDIR/plugins/50-good.sh" <<'ENDPLUGIN'
CC_TEST_MARKER_50="loaded"
cc_test_marker_fn_50() { echo "50-good"; }
ENDPLUGIN

# ---------------------------------------------------------------------------
# Assertion block 1: populated plugins dir
# ---------------------------------------------------------------------------

CC_TEST=1 CC_PLUGINS_DIR="$TESTDIR/plugins" source "$CC" 2>"$TESTDIR/stderr.log"
SRC_RC=$?

# (1) sourcing returned 0 AND the test process is still alive past this
# point — proving BOTH 40-exit.sh's `exit 1` AND 41-exit-zero.sh's
# `exit 0` were absorbed by the loader's canary probe and did NOT kill the
# host shell (reaching this line at all is part of the proof; the explicit
# rc check is the second half).
if [[ "$SRC_RC" -eq 0 ]]; then
    pass "loader/host-shell-survives-exit-1-and-exit-0"
else
    fail "loader/host-shell-survives-exit-1-and-exit-0" "source returned $SRC_RC"
fi

# (2) stderr.log names all three of 20-broken.sh, 40-exit.sh, 41-exit-zero.sh
STDERR_LOG="$(cat "$TESTDIR/stderr.log" 2>/dev/null)"
for badfile in "20-broken.sh" "40-exit.sh" "41-exit-zero.sh"; do
    if echo "$STDERR_LOG" | grep -q "failed to load plugin.*$badfile"; then
        pass "loader/warns-$badfile"
    else
        fail "loader/warns-$badfile" "no 'failed to load plugin' warning found for $badfile"
    fi
done

# (3) 10-good.sh's marker function/variable AND 50-good.sh's marker (ordered
# after the broken/exit fixtures) are defined — fail-safe continue.
if declare -f cc_test_marker_fn_10 >/dev/null 2>&1; then
    pass "loader/10-good-function-defined"
else
    fail "loader/10-good-function-defined"
fi

if [[ "${CC_TEST_MARKER_10:-}" == "loaded" ]]; then
    pass "loader/10-good-variable-defined"
else
    fail "loader/10-good-variable-defined" "CC_TEST_MARKER_10='${CC_TEST_MARKER_10:-<unset>}'"
fi

if declare -f cc_test_marker_fn_50 >/dev/null 2>&1; then
    pass "loader/50-good-function-defined-after-broken-and-exit-fixtures"
else
    fail "loader/50-good-function-defined-after-broken-and-exit-fixtures"
fi

# (4) errexit / nounset / pipefail are each explicitly OFF in the host
# shell after loading 30-poison.sh — proving no set-o leak. Three
# independent assertions, not only a combined snapshot.
get_shopt_state() {
    set -o | awk -v n="$1" '$1==n{print $2}'
}

for optname in errexit nounset pipefail; do
    state="$(get_shopt_state "$optname")"
    if [[ "$state" == "off" ]]; then
        pass "loader/no-leak-$optname-off"
    else
        fail "loader/no-leak-$optname-off" "expected off, got '$state'"
    fi
done

if [[ "${CC_TEST_MARKER_30:-}" == "loaded" ]]; then
    pass "loader/30-poison-still-loaded"
else
    fail "loader/30-poison-still-loaded" "CC_TEST_MARKER_30='${CC_TEST_MARKER_30:-<unset>}'"
fi

# ---------------------------------------------------------------------------
# Assertion block 2: absent plugins directory is a silent no-op
# ---------------------------------------------------------------------------

CC_PLUGINS_DIR="/no/such/dir" CC_TEST=1 source "$CC" 2>"$TESTDIR/stderr-absent.log"
ABSENT_RC=$?

if [[ "$ABSENT_RC" -eq 0 ]]; then
    pass "loader/absent-dir-returns-0"
else
    fail "loader/absent-dir-returns-0" "source returned $ABSENT_RC"
fi

if [[ ! -s "$TESTDIR/stderr-absent.log" ]]; then
    pass "loader/absent-dir-empty-stderr"
else
    fail "loader/absent-dir-empty-stderr" "stderr: $(cat "$TESTDIR/stderr-absent.log")"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo "RESULT: $FAIL failures"
exit $(( FAIL > 0 ? 1 : 0 ))
