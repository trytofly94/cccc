#!/bin/bash
# test-about-logo.sh — Phase 14 Plan 03 (BRAND-02/03/04) fixture-based unit
# tests for cc/cc's render_logo(), cmd_about(), and the SHOW_LOGO settings
# round-trip.
#
# render_logo()'s first line is `[[ -t 1 ]] || return 0`, so capturing it via
# command substitution (never a TTY) always yields empty output regardless of
# the SHOW_LOGO/CC_NO_LOGO settings — a genuine regression in setting-based
# suppression would go undetected. Cases 1-3 therefore drive render_logo under
# a real pty via `expect` (same pattern as test-auto-trust.sh) so `[[ -t 1 ]]`
# is true and the settings actually gate the output; they SKIP (not fail) when
# `expect` is unavailable.
#
# Run: bash cc/test-about-logo.sh
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
# matches the isolation convention established by cc/test-trust-dialog-detect.sh.
# ---------------------------------------------------------------------------
TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/cc-about-logo-test-home-XXXXXX")"
cleanup() { rm -rf "$TEST_HOME"; }
trap cleanup EXIT
export HOME="$TEST_HOME"

CC_TEST=1 source "$CC"

# ---------------------------------------------------------------------------
# Cases 1-3: drive render_logo() under a REAL pty (via expect) so its
# `[[ -t 1 ]]` guard is satisfied and the SHOW_LOGO / CC_NO_LOGO settings
# actually decide whether the logo renders. Under command substitution alone
# stdout is never a TTY, so all three would trivially "emit empty" and a real
# suppression regression would ship undetected. "Claude Code Control Center"
# (render_logo's final tagline line) is the presence marker. CC_NO_LOGO is
# passed as 0 (== unset for render_logo's `${CC_NO_LOGO:-0}` check) or 1.
# ---------------------------------------------------------------------------
LOGO_MARKER="Claude Code Control Center"

run_render_logo_pty() {
    # Args: <CC_SET_SHOW_LOGO value> <CC_NO_LOGO value>
    local show_logo="$1" no_logo="$2"
    CC_PATH="$CC" SL="$show_logo" NL="$no_logo" \
    expect -c '
        set timeout 5
        log_user 1
        spawn bash -c "CC_TEST=1 source \"$env(CC_PATH)\"; CC_SET_SHOW_LOGO=\"$env(SL)\"; CC_NO_LOGO=\"$env(NL)\"; render_logo"
        expect eof
    ' 2>/dev/null
}

if command -v expect >/dev/null 2>&1; then
    # Case 1: SHOW_LOGO=false under a real TTY -> logo suppressed.
    out="$(run_render_logo_pty false 0)"
    if [[ "$out" != *"$LOGO_MARKER"* ]]; then
        pass "render_logo/SHOW_LOGO=false/suppressed-under-tty"
    else
        fail "render_logo/SHOW_LOGO=false/suppressed-under-tty" "logo rendered despite SHOW_LOGO=false"
    fi

    # Case 2: CC_NO_LOGO=1 under a real TTY -> suppressed even with SHOW_LOGO=true.
    out="$(run_render_logo_pty true 1)"
    if [[ "$out" != *"$LOGO_MARKER"* ]]; then
        pass "render_logo/CC_NO_LOGO=1/suppressed-under-tty"
    else
        fail "render_logo/CC_NO_LOGO=1/suppressed-under-tty" "logo rendered despite CC_NO_LOGO=1"
    fi

    # Case 3: SHOW_LOGO=true, no CC_NO_LOGO, under a real TTY -> logo IS rendered
    # (proves the guard is TTY-gated, not unconditionally empty).
    out="$(run_render_logo_pty true 0)"
    if [[ "$out" == *"$LOGO_MARKER"* ]]; then
        pass "render_logo/SHOW_LOGO=true/renders-under-tty"
    else
        fail "render_logo/SHOW_LOGO=true/renders-under-tty" "logo NOT rendered under a real TTY"
    fi
else
    echo "SKIP render_logo/SHOW_LOGO=false/suppressed-under-tty (expect not installed)"
    echo "SKIP render_logo/CC_NO_LOGO=1/suppressed-under-tty (expect not installed)"
    echo "SKIP render_logo/SHOW_LOGO=true/renders-under-tty (expect not installed)"
fi

# ---------------------------------------------------------------------------
# Case 4: cmd_about() output contains $VERSION and the repo URL.
# ---------------------------------------------------------------------------
out="$(cmd_about)"
if [[ "$out" == *"$VERSION"* ]]; then
    pass "cmd_about/contains-version"
else
    fail "cmd_about/contains-version" "out='$out' VERSION='$VERSION'"
fi
if [[ "$out" == *"github.com/trytofly94/cccc"* ]]; then
    pass "cmd_about/contains-repo-url"
else
    fail "cmd_about/contains-repo-url" "out='$out'"
fi

# ---------------------------------------------------------------------------
# Case 5: SHOW_LOGO settings round-trip via write_setting() — true|false
# whitelist accepted, anything else rejected (validate-case in write_setting()).
# ---------------------------------------------------------------------------
write_setting SHOW_LOGO false
rc=$?
if [[ "$rc" -eq 0 ]]; then
    pass "write_setting/SHOW_LOGO=false/accepted"
else
    fail "write_setting/SHOW_LOGO=false/accepted" "rc=$rc"
fi

write_setting SHOW_LOGO garbage
rc=$?
if [[ "$rc" -ne 0 ]]; then
    pass "write_setting/SHOW_LOGO=garbage/rejected"
else
    fail "write_setting/SHOW_LOGO=garbage/rejected" "rc=$rc"
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
