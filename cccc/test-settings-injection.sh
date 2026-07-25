#!/usr/bin/env bash
# test-settings-injection.sh — Phase 16 Plans 02 (SEC-02) sandboxed
# regression test for cccc/cccc's write_setting() and load_settings().
#
# Re-runs the bash-side counterpart of the CR-01 newline-injection PoC
# (15-REVIEW.md) against the REAL, fixed write_setting()/load_settings()
# and proves: (1) an embedded \n/\r in any value is rejected before it ever
# reaches settings.conf, (2) normal free-text CLAUDE_BIN/EXTRA_FLAGS values
# still round-trip verbatim (SEC-03 — the fix must not be a blanket-reject
# tautology), (3) load_settings() defensively skips an already-poisoned
# parsed value and falls back to defaults, (4) load_settings() still adopts
# a real custom value verbatim (the mandatory positive assertion that would
# have caught the BLOCKER-1 *$'\0'* tautology bug), and (5) load_settings()
# adopts a CRLF-terminated settings.conf identically to an LF one.
#
# No tmux is spawned by this file, so the QA-03 tmux-sandbox rule does not
# apply — but CONFIG_DIR/SETTINGS_FILE are still sandboxed to an mktemp dir,
# torn down via an EXIT trap, so this test never touches the real
# ~/.config/claude-control/settings.conf (STATE.md: "Phases 8-13 MUST NOT
# modify or delete settings.conf on this machine" — the same care applies
# here even though this is Phase 16).
#
# Run: bash cccc/test-settings-injection.sh
# Exit 0 = all assertions pass; Exit 1 = one or more failures.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CC="$SCRIPT_DIR/cccc"

FAIL=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1${2:+ ($2)}"; FAIL=$(( FAIL + 1 )); }

TMPDIR_TEST="$(mktemp -d "${TMPDIR:-/tmp}/cc-settings-injection-test.XXXXXX")"

cleanup() {
    rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Load the REAL cccc/cccc functions (write_setting, load_settings) without
# launching the dashboard. Point CC_PLUGINS_DIR at an empty, nonexistent
# sandbox dir BEFORE sourcing so load_plugins() (invoked unconditionally at
# source-time, even under CC_TEST=1) never loads this machine's real local
# plugins (~/.config/claude-control/plugins/*.sh) — both to keep this test
# fully sandboxed (never touch real machine state) and because at least one
# real local plugin's own nested shellopts save/restore collides with
# load_plugins()'s identically-named local variable under `set -u`,
# unrelated to anything this phase changes.
# ---------------------------------------------------------------------------

export CC_PLUGINS_DIR="$TMPDIR_TEST/no-plugins-here"
CC_TEST=1 source "$CC"

# Point CONFIG_DIR/SETTINGS_FILE at a fresh sandbox dir for the write_setting
# assertions below (Task 1). Task 2's load_settings assertions repoint these
# again as needed.
CONFIG_DIR="$TMPDIR_TEST/write-sandbox"
SETTINGS_FILE="$CONFIG_DIR/settings.conf"

# ===========================================================================
# Task 1 — write_setting() preventive guard (SEC-02) + free-text preservation
# (SEC-03) + anti-tautology
# ===========================================================================

# --- Assertion: CLAUDE_BIN with the exact CR-01 payload is rejected -------
mkdir -p "$CONFIG_DIR"
: > "$SETTINGS_FILE"
before_hash=$(md5 -q "$SETTINGS_FILE" 2>/dev/null || md5sum "$SETTINGS_FILE" | awk '{print $1}')

write_setting "CLAUDE_BIN" $'claude\nPERMISSION_MODE=bypassPermissions' && rc=0 || rc=$?
if [[ "$rc" -eq 1 ]]; then
    pass "write_setting/claude_bin-newline-rejected"
else
    fail "write_setting/claude_bin-newline-rejected" "expected rc=1, got rc=$rc"
fi

after_hash=$(md5 -q "$SETTINGS_FILE" 2>/dev/null || md5sum "$SETTINGS_FILE" | awk '{print $1}')
if [[ "$before_hash" == "$after_hash" ]] && ! grep -q "PERMISSION_MODE=bypassPermissions" "$SETTINGS_FILE"; then
    pass "write_setting/claude_bin-newline-file-unchanged"
else
    fail "write_setting/claude_bin-newline-file-unchanged" "SETTINGS_FILE was modified by a rejected write"
fi

# --- Assertion: EXTRA_FLAGS with an embedded CR is rejected ---------------
write_setting "EXTRA_FLAGS" $'foo\rbar' && rc=0 || rc=$?
if [[ "$rc" -eq 1 ]]; then
    pass "write_setting/extra_flags-cr-rejected"
else
    fail "write_setting/extra_flags-cr-rejected" "expected rc=1, got rc=$rc"
fi

# --- Assertion: MODEL with an embedded newline is rejected -----------------
write_setting "MODEL" $'a\nb' && rc=0 || rc=$?
if [[ "$rc" -eq 1 ]]; then
    pass "write_setting/model-newline-rejected"
else
    fail "write_setting/model-newline-rejected" "expected rc=1, got rc=$rc"
fi

# --- Assertion (SEC-03 preservation): EXTRA_FLAGS free text round-trips ---
write_setting "EXTRA_FLAGS" "--dangerously-skip-permissions --model foo" && rc=0 || rc=$?
if [[ "$rc" -eq 0 ]]; then
    pass "write_setting/extra_flags-freetext-accepted"
else
    fail "write_setting/extra_flags-freetext-accepted" "expected rc=0, got rc=$rc"
fi
if grep -qxF "EXTRA_FLAGS=--dangerously-skip-permissions --model foo" "$SETTINGS_FILE"; then
    pass "write_setting/extra_flags-freetext-roundtrips-verbatim"
else
    fail "write_setting/extra_flags-freetext-roundtrips-verbatim" "value not found verbatim in SETTINGS_FILE"
fi

# --- Assertion (SEC-03 preservation): CLAUDE_BIN normal path accepted -----
write_setting "CLAUDE_BIN" "/usr/local/bin/claude" && rc=0 || rc=$?
if [[ "$rc" -eq 0 ]]; then
    pass "write_setting/claude_bin-normal-path-accepted"
else
    fail "write_setting/claude_bin-normal-path-accepted" "expected rc=0, got rc=$rc"
fi

# --- Assertion (anti-tautology): a legitimate short enum value is NOT rejected
write_setting "PERMISSION_MODE" "plan" && rc=0 || rc=$?
if [[ "$rc" -eq 0 ]]; then
    pass "write_setting/permission_mode-plan-not-rejected"
else
    fail "write_setting/permission_mode-plan-not-rejected" "expected rc=0, got rc=$rc (newline guard is a tautology?)"
fi

# --- Assertions (IDLE_WATCHDOG, v4.0 final feature step — opt-in, default off) ---
write_setting "IDLE_WATCHDOG" "on" && rc=0 || rc=$?
if [[ "$rc" -eq 0 ]]; then
    pass "write_setting/idle_watchdog-on-accepted"
else
    fail "write_setting/idle_watchdog-on-accepted" "expected rc=0, got rc=$rc"
fi
if grep -qxF "IDLE_WATCHDOG=on" "$SETTINGS_FILE"; then
    pass "write_setting/idle_watchdog-on-roundtrips-verbatim"
else
    fail "write_setting/idle_watchdog-on-roundtrips-verbatim" "value not found verbatim in SETTINGS_FILE"
fi

write_setting "IDLE_WATCHDOG" "off" && rc=0 || rc=$?
if [[ "$rc" -eq 0 ]]; then
    pass "write_setting/idle_watchdog-off-accepted"
else
    fail "write_setting/idle_watchdog-off-accepted" "expected rc=0, got rc=$rc"
fi

write_setting "IDLE_WATCHDOG" "bogus" && rc=0 || rc=$?
if [[ "$rc" -eq 1 ]]; then
    pass "write_setting/idle_watchdog-bogus-rejected"
else
    fail "write_setting/idle_watchdog-bogus-rejected" "expected rc=1, got rc=$rc"
fi
if grep -qxF "IDLE_WATCHDOG=bogus" "$SETTINGS_FILE"; then
    fail "write_setting/idle_watchdog-bogus-not-written" "rejected value was written to SETTINGS_FILE"
else
    pass "write_setting/idle_watchdog-bogus-not-written"
fi

# --- Assertion: the guard returns 1 (validation), never 2 (I/O), and runs
# before any file/dir is created when CONFIG_DIR is a fresh, nonexistent dir.
FRESH_CONFIG_DIR="$TMPDIR_TEST/fresh-nonexistent-dir"
CONFIG_DIR="$FRESH_CONFIG_DIR"
SETTINGS_FILE="$CONFIG_DIR/settings.conf"

write_setting "MODEL" $'a\nb' && rc=0 || rc=$?
if [[ "$rc" -eq 1 ]]; then
    pass "write_setting/fresh-dir-rejected-with-validation-code"
else
    fail "write_setting/fresh-dir-rejected-with-validation-code" "expected rc=1, got rc=$rc"
fi
if [[ ! -e "$FRESH_CONFIG_DIR" ]]; then
    pass "write_setting/fresh-dir-not-created-before-guard"
else
    fail "write_setting/fresh-dir-not-created-before-guard" "CONFIG_DIR was created despite validation failure"
fi

# ===========================================================================
# Task 2 — load_settings() trailing-CR normalization + defensive post-parse
# control-char skip, plus mandatory positive-adoption and CRLF assertions
# ===========================================================================

LOAD_SANDBOX="$TMPDIR_TEST/load-sandbox"
mkdir -p "$LOAD_SANDBOX"
CONFIG_DIR="$LOAD_SANDBOX"

# --- Assertion (1, NEGATIVE — defensive skip): a hand-written settings.conf
# line with an EMBEDDED (non-trailing) \r must be skipped, falling back to
# the documented default rather than adopting the poisoned value.
SETTINGS_FILE="$LOAD_SANDBOX/negative.conf"
printf 'CLAUDE_BIN=foo\rbar\n' > "$SETTINGS_FILE"

load_settings

if [[ "$CC_SET_CLAUDE_BIN" == "claude" ]]; then
    pass "load_settings/embedded-cr-falls-back-to-default"
else
    fail "load_settings/embedded-cr-falls-back-to-default" "CC_SET_CLAUDE_BIN=[$CC_SET_CLAUDE_BIN], expected default 'claude'"
fi

# --- Assertion (2, MANDATORY POSITIVE — the assertion that would have caught
# BLOCKER-1): a CLEAN, LF-terminated settings.conf with REAL custom values
# must be adopted verbatim, NOT reverted to defaults.
SETTINGS_FILE="$LOAD_SANDBOX/positive.conf"
printf 'CLAUDE_BIN=/usr/local/bin/claude\nPERMISSION_MODE=plan\n' > "$SETTINGS_FILE"

load_settings

if [[ "$CC_SET_CLAUDE_BIN" == "/usr/local/bin/claude" ]]; then
    pass "load_settings/positive-adoption-claude_bin"
else
    fail "load_settings/positive-adoption-claude_bin" "CC_SET_CLAUDE_BIN=[$CC_SET_CLAUDE_BIN], expected '/usr/local/bin/claude' (guard is a tautology?)"
fi
if [[ "$CC_SET_PERMISSION_MODE" == "plan" ]]; then
    pass "load_settings/positive-adoption-permission_mode"
else
    fail "load_settings/positive-adoption-permission_mode" "CC_SET_PERMISSION_MODE=[$CC_SET_PERMISSION_MODE], expected 'plan' (guard is a tautology?)"
fi

# --- Assertion (IDLE_WATCHDOG default-off): a settings.conf that doesn't
# mention IDLE_WATCHDOG at all -- exactly the shape of every settings.conf
# written before this feature existed -- must resolve to "off", never "on".
SETTINGS_FILE="$LOAD_SANDBOX/no-idle-watchdog-key.conf"
printf 'CLAUDE_BIN=/usr/local/bin/claude\n' > "$SETTINGS_FILE"

load_settings

if [[ "$CC_SET_IDLE_WATCHDOG" == "off" ]]; then
    pass "load_settings/idle_watchdog-defaults-off-when-key-absent"
else
    fail "load_settings/idle_watchdog-defaults-off-when-key-absent" "CC_SET_IDLE_WATCHDOG=[$CC_SET_IDLE_WATCHDOG], expected 'off'"
fi

# --- Assertion (IDLE_WATCHDOG positive adoption + bogus-value fallback) ---
SETTINGS_FILE="$LOAD_SANDBOX/idle-watchdog-on.conf"
printf 'IDLE_WATCHDOG=on\n' > "$SETTINGS_FILE"

load_settings

if [[ "$CC_SET_IDLE_WATCHDOG" == "on" ]]; then
    pass "load_settings/idle_watchdog-positive-adoption-on"
else
    fail "load_settings/idle_watchdog-positive-adoption-on" "CC_SET_IDLE_WATCHDOG=[$CC_SET_IDLE_WATCHDOG], expected 'on'"
fi

SETTINGS_FILE="$LOAD_SANDBOX/idle-watchdog-bogus.conf"
printf 'IDLE_WATCHDOG=bogus\n' > "$SETTINGS_FILE"

load_settings

if [[ "$CC_SET_IDLE_WATCHDOG" == "off" ]]; then
    pass "load_settings/idle_watchdog-bogus-value-falls-back-to-off"
else
    fail "load_settings/idle_watchdog-bogus-value-falls-back-to-off" "CC_SET_IDLE_WATCHDOG=[$CC_SET_IDLE_WATCHDOG], expected fallback 'off'"
fi

# --- Assertion (3, MANDATORY CRLF REGRESSION): a CRLF-terminated
# settings.conf with a legitimate custom value must be adopted EXACTLY (no
# trailing \r), not reverted to default and not skipped by the guard —
# proving the strip-then-guard ordering makes CRLF parse like LF.
SETTINGS_FILE="$LOAD_SANDBOX/crlf.conf"
printf 'CLAUDE_BIN=/usr/local/bin/claude\r\n' > "$SETTINGS_FILE"

load_settings

if [[ "$CC_SET_CLAUDE_BIN" == "/usr/local/bin/claude" ]]; then
    pass "load_settings/crlf-adopted-no-trailing-cr"
else
    fail "load_settings/crlf-adopted-no-trailing-cr" "CC_SET_CLAUDE_BIN=[$CC_SET_CLAUDE_BIN] (length ${#CC_SET_CLAUDE_BIN}), expected '/usr/local/bin/claude'"
fi

# ===========================================================================
# Summary
# ===========================================================================

echo "RESULT: $FAIL failures"
exit $(( FAIL > 0 ? 1 : 0 ))
