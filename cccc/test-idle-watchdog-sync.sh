#!/usr/bin/env bash
# test-idle-watchdog-sync.sh — v4.0 final feature step (opt-in idle-watchdog,
# default OFF, .planning/cccc-public-release-brief.md #8) sandboxed regression
# test for cccc/cccc's sync_idle_watchdog().
#
# Proves the three safety gates that make "flipping IDLE_WATCHDOG toggles the
# launchd job" safe to ship:
#   1. Platform gate — a non-Darwin `uname -s` is a hard no-op, zero launchctl
#      calls, regardless of setting value or plist presence.
#   2. Plist-existence gate — if the daemon was never installed (no plist at
#      CC_LAUNCH_AGENTS_DIR/<label>.plist), sync_idle_watchdog() never creates
#      or loads anything; the setting stays purely declarative.
#   3. Value routing — "on" issues bootout (idempotent reload) + bootstrap;
#      "off" issues bootout only, never bootstrap.
#
# Every launchctl call is captured via a redefinition of
# _idle_watchdog_launchctl() (bash allows redefining a function after
# sourcing) -- this test NEVER execs a real `launchctl` and NEVER touches the
# real gui/<uid>/com.user.claude-idle-watchdog launchd namespace.
#
# No tmux is spawned by this file, so the QA-03 tmux-sandbox rule does not
# apply. CC_LAUNCH_AGENTS_DIR is sandboxed to an mktemp dir, torn down via an
# EXIT trap, so this test never touches the real ~/Library/LaunchAgents.
#
# Run: bash cccc/test-idle-watchdog-sync.sh
# Exit 0 = all assertions pass; Exit 1 = one or more failures.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CC="$SCRIPT_DIR/cccc"

FAIL=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1${2:+ ($2)}"; FAIL=$(( FAIL + 1 )); }

TMPDIR_TEST="$(mktemp -d "${TMPDIR:-/tmp}/cc-idle-watchdog-sync-test.XXXXXX")"
cleanup() { rm -rf "$TMPDIR_TEST"; }
trap cleanup EXIT

# Sandbox CC_LAUNCH_AGENTS_DIR (mirrors IDLE_WATCHDOG_PLIST's CC_CONFIG_DIR-style
# override) BEFORE sourcing, so IDLE_WATCHDOG_PLIST never resolves to the real
# ~/Library/LaunchAgents. Also point CC_PLUGINS_DIR at an empty dir, same as
# test-settings-injection.sh, so this machine's real local plugins never load.
export CC_LAUNCH_AGENTS_DIR="$TMPDIR_TEST/LaunchAgents"
export CC_PLUGINS_DIR="$TMPDIR_TEST/no-plugins-here"
mkdir -p "$CC_LAUNCH_AGENTS_DIR"

CC_TEST=1 source "$CC"

# Recording stub for _idle_watchdog_launchctl(). CALLS is a newline-joined
# log of every invocation's args, reset before each assertion group.
CALLS=""
_idle_watchdog_launchctl() {
    CALLS="${CALLS}$*"$'\n'
}

PLIST_PATH="$CC_LAUNCH_AGENTS_DIR/com.user.claude-idle-watchdog.plist"

# ===========================================================================
# Gate 1 — plist NOT installed: sync_idle_watchdog() must be a total no-op,
# regardless of CC_SET_IDLE_WATCHDOG, as long as uname is Darwin.
# ===========================================================================

if [[ "$(uname -s)" == "Darwin" ]]; then
    CALLS=""
    CC_SET_IDLE_WATCHDOG="on"
    sync_idle_watchdog
    if [[ -z "$CALLS" ]]; then
        pass "gate/plist-missing-on-is-noop"
    else
        fail "gate/plist-missing-on-is-noop" "expected zero launchctl calls, got: $CALLS"
    fi

    CALLS=""
    CC_SET_IDLE_WATCHDOG="off"
    sync_idle_watchdog
    if [[ -z "$CALLS" ]]; then
        pass "gate/plist-missing-off-is-noop"
    else
        fail "gate/plist-missing-off-is-noop" "expected zero launchctl calls, got: $CALLS"
    fi
else
    pass "gate/plist-missing-on-is-noop (skipped, non-Darwin: $(uname -s))"
    pass "gate/plist-missing-off-is-noop (skipped, non-Darwin: $(uname -s))"
fi

# ===========================================================================
# Gate 2 — platform gate: non-Darwin uname is a hard no-op EVEN WITH the
# plist present and IDLE_WATCHDOG=on. Shadow uname with a function (bash
# resolves a function before PATH) so this assertion runs identically on
# every CI platform, not just non-macOS runners.
# ===========================================================================

: > "$PLIST_PATH"   # now "installed" for the remaining assertions

uname() { echo "Linux"; }
CALLS=""
CC_SET_IDLE_WATCHDOG="on"
sync_idle_watchdog
if [[ -z "$CALLS" ]]; then
    pass "gate/non-darwin-is-noop-even-with-plist-and-on"
else
    fail "gate/non-darwin-is-noop-even-with-plist-and-on" "expected zero launchctl calls, got: $CALLS"
fi
unset -f uname

# ===========================================================================
# Gate 3 — value routing (Darwin + plist installed, real conditions for this
# test's own platform going forward)
# ===========================================================================

uname() { echo "Darwin"; }

CALLS=""
CC_SET_IDLE_WATCHDOG="on"
sync_idle_watchdog
if printf '%s' "$CALLS" | grep -q '^bootout '; then
    pass "sync/on-issues-bootout"
else
    fail "sync/on-issues-bootout" "CALLS=[$CALLS]"
fi
if printf '%s' "$CALLS" | grep -q '^bootstrap '; then
    pass "sync/on-issues-bootstrap"
else
    fail "sync/on-issues-bootstrap" "CALLS=[$CALLS]"
fi
if printf '%s' "$CALLS" | grep -q "$PLIST_PATH"; then
    pass "sync/on-bootstrap-references-correct-plist-path"
else
    fail "sync/on-bootstrap-references-correct-plist-path" "CALLS=[$CALLS]"
fi

CALLS=""
CC_SET_IDLE_WATCHDOG="off"
sync_idle_watchdog
if printf '%s' "$CALLS" | grep -q '^bootout '; then
    pass "sync/off-issues-bootout"
else
    fail "sync/off-issues-bootout" "CALLS=[$CALLS]"
fi
if printf '%s' "$CALLS" | grep -q '^bootstrap '; then
    fail "sync/off-does-not-issue-bootstrap" "CALLS=[$CALLS]"
else
    pass "sync/off-does-not-issue-bootstrap"
fi

unset -f uname

echo "RESULT: $FAIL failures"
exit $(( FAIL > 0 ? 1 : 0 ))
