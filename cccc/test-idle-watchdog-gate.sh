#!/usr/bin/env bash
# test-idle-watchdog-gate.sh — v4.0 final feature step (opt-in idle-watchdog,
# default OFF, .planning/cccc-public-release-brief.md #8) sandboxed regression
# test for system/bin/claude-idle-watchdog's OWN settings-gate + platform
# gate — the belt-and-suspenders check the daemon runs independently of
# cccc/cccc's sync_idle_watchdog() (see test-idle-watchdog-sync.sh for that
# half), so the daemon is safe even if something loads it outside of cccc's
# control.
#
# Runs the REAL script via `--dry-run --once` against a fully sandboxed
# HOME + CC_CONFIG_DIR (mktemp dirs, torn down via EXIT trap) — never reads
# or writes the real ~/.config/claude-control/settings.conf or
# ~/.local/log/claude-idle-watchdog.log. Because the settings-gate check runs
# BEFORE any tmux session enumeration, none of these assertions require tmux
# or a running Claude session, and (when disabled/non-Darwin) never touch any
# real system session.
#
# Run: bash cccc/test-idle-watchdog-gate.sh
# Exit 0 = all assertions pass; Exit 1 = one or more failures.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHDOG="$SCRIPT_DIR/../system/bin/claude-idle-watchdog"

FAIL=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1${2:+ ($2)}"; FAIL=$(( FAIL + 1 )); }

# Use an array so a repo path containing spaces never word-splits when the
# watchdog is invoked (both the direct-exec and `bash <script>` forms).
WATCHDOG_CMD=("$WATCHDOG")
[[ -x "$WATCHDOG" ]] || WATCHDOG_CMD=(bash "$WATCHDOG")

TMPDIR_TEST="$(mktemp -d "${TMPDIR:-/tmp}/cc-idle-watchdog-gate-test.XXXXXX")"
cleanup() { rm -rf "$TMPDIR_TEST"; }
trap cleanup EXIT

run_watchdog() {
    # Args: <fake-HOME> <fake-CC_CONFIG_DIR> [extra PATH prefix dir]
    local fake_home="$1" fake_cfg="$2" extra_path="${3:-}"
    mkdir -p "$fake_home" "$fake_cfg"
    if [[ -n "$extra_path" ]]; then
        PATH="$extra_path:$PATH" HOME="$fake_home" CC_CONFIG_DIR="$fake_cfg" \
            "${WATCHDOG_CMD[@]}" --dry-run --once >"$fake_home/stdout.log" 2>&1
    else
        HOME="$fake_home" CC_CONFIG_DIR="$fake_cfg" \
            "${WATCHDOG_CMD[@]}" --dry-run --once >"$fake_home/stdout.log" 2>&1
    fi
}

# ===========================================================================
# Assertion 1 — settings.conf ABSENT entirely: default is off, no reclaim,
# graceful exit 0.
# ===========================================================================

HOME1="$TMPDIR_TEST/home-absent"
CFG1="$TMPDIR_TEST/cfg-absent"
run_watchdog "$HOME1" "$CFG1"
RC1=$?
LOG1="$HOME1/.local/log/claude-idle-watchdog.log"

if [[ "$RC1" -eq 0 ]]; then
    pass "gate/absent-settings-exit-0"
else
    fail "gate/absent-settings-exit-0" "exit code $RC1"
fi
if [[ -f "$LOG1" ]] && grep -q 'IDLE_WATCHDOG is off' "$LOG1"; then
    pass "gate/absent-settings-logs-disabled"
else
    fail "gate/absent-settings-logs-disabled" "log: $(cat "$LOG1" 2>/dev/null)"
fi

# ===========================================================================
# Assertion 2 — IDLE_WATCHDOG=off explicit: same behavior as absent.
# ===========================================================================

HOME2="$TMPDIR_TEST/home-off"
CFG2="$TMPDIR_TEST/cfg-off"
mkdir -p "$CFG2"
printf 'IDLE_WATCHDOG=off\n' > "$CFG2/settings.conf"
run_watchdog "$HOME2" "$CFG2"
LOG2="$HOME2/.local/log/claude-idle-watchdog.log"

if [[ -f "$LOG2" ]] && grep -q 'IDLE_WATCHDOG is off' "$LOG2"; then
    pass "gate/explicit-off-logs-disabled"
else
    fail "gate/explicit-off-logs-disabled" "log: $(cat "$LOG2" 2>/dev/null)"
fi

# ===========================================================================
# Assertion 3 — IDLE_WATCHDOG=on: gate does NOT fire; startup line reflects
# "on".
# ===========================================================================

HOME3="$TMPDIR_TEST/home-on"
CFG3="$TMPDIR_TEST/cfg-on"
mkdir -p "$CFG3"
printf 'IDLE_WATCHDOG=on\n' > "$CFG3/settings.conf"
run_watchdog "$HOME3" "$CFG3"
LOG3="$HOME3/.local/log/claude-idle-watchdog.log"

if [[ -f "$LOG3" ]] && grep -q 'IDLE_WATCHDOG=on' "$LOG3" && ! grep -q 'IDLE_WATCHDOG is off' "$LOG3"; then
    pass "gate/explicit-on-does-not-skip"
else
    fail "gate/explicit-on-does-not-skip" "log: $(cat "$LOG3" 2>/dev/null)"
fi

# ===========================================================================
# Assertion 4 — log-dedup: --once runs TWO passes; a disabled daemon must log
# the "is off" transition exactly ONCE, not once per pass (no log spam).
# ===========================================================================

# `grep -c` prints its count ("0" on no match) AND exits 1 when there are zero
# matches; a trailing `|| echo 0` would then append a SECOND "0", yielding a
# two-line "0\n0" that breaks the arithmetic `-eq` test. Drop it and default an
# empty result (file absent) to 0 instead.
DEDUP_COUNT=$(grep -c 'IDLE_WATCHDOG is off' "$LOG1" 2>/dev/null)
DEDUP_COUNT=${DEDUP_COUNT:-0}
if [[ "$DEDUP_COUNT" -eq 1 ]]; then
    pass "gate/disabled-message-logged-exactly-once-across-two-passes"
else
    fail "gate/disabled-message-logged-exactly-once-across-two-passes" "count=$DEDUP_COUNT"
fi

# ===========================================================================
# Assertion 5 — platform gate: non-Darwin uname -> graceful exit 0, no log
# directory ever created (gate runs before LOG_DIR setup).
# ===========================================================================

FAKE_BIN="$TMPDIR_TEST/fakebin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/uname" <<'EOF'
#!/bin/bash
echo "Linux"
EOF
chmod +x "$FAKE_BIN/uname"

HOME5="$TMPDIR_TEST/home-nonmacos"
CFG5="$TMPDIR_TEST/cfg-nonmacos"
mkdir -p "$CFG5"
printf 'IDLE_WATCHDOG=on\n' > "$CFG5/settings.conf"
run_watchdog "$HOME5" "$CFG5" "$FAKE_BIN"
RC5=$?

if [[ "$RC5" -eq 0 ]]; then
    pass "gate/non-darwin-exit-0"
else
    fail "gate/non-darwin-exit-0" "exit code $RC5"
fi
if grep -qi 'macOS-only' "$HOME5/stdout.log" 2>/dev/null; then
    pass "gate/non-darwin-logs-platform-message"
else
    fail "gate/non-darwin-logs-platform-message" "stdout: $(cat "$HOME5/stdout.log" 2>/dev/null)"
fi
if [[ ! -d "$HOME5/.local/log" ]]; then
    pass "gate/non-darwin-never-creates-log-dir"
else
    fail "gate/non-darwin-never-creates-log-dir" "$HOME5/.local/log was created despite the platform gate"
fi

echo "RESULT: $FAIL failures"
exit $(( FAIL > 0 ? 1 : 0 ))
