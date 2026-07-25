#!/bin/bash
# test-auto-trust.sh — Phase 10 Plan 04 (TRUST-01/02/03/04) automated harness
# for cc/cc's trust_path_defensively() helper and the on-add/always/off
# AUTO_TRUST modes.
#
# CRITICAL SAFETY: every test in this file operates against a per-test TEMP
# COPY of a fabricated ~/.claude.json fixture. HOME is redirected to a private
# per-PID temp directory BEFORE cc/cc is sourced, so trust_path_defensively()
# (which reads "$HOME/.claude.json" fresh on every call) can never reach the
# maintainer's real ~/.claude.json. This test NEVER touches $HOME/.claude.json
# on the real, unmodified HOME.
#
# Run: bash cc/test-auto-trust.sh
# Exit 0 = all assertions pass; Exit 1 = one or more failures.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CC="$SCRIPT_DIR/cccc"

FAIL=0

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1${2:+ ($2)}"; FAIL=$(( FAIL + 1 )); }

# This suite asserts trust_path_defensively()'s JSON edits via jq. macOS ships
# no jq, so SKIP cleanly (rather than emit confusing FAILs) when it is absent —
# same portability posture as the `expect` guard on the pty cases below.
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

# ---------------------------------------------------------------------------
# Redirect HOME to a private per-test temp dir BEFORE sourcing cc/cc, so
# trust_path_defensively's "$HOME/.claude.json" resolves to our fixture, never
# the maintainer's real file. TMPDIR (test harness scratch space) is kept
# separate from HOME (the fixture directory) for clarity.
# ---------------------------------------------------------------------------
TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/cc-auto-trust-test-home-XXXXXX")"
cleanup() { rm -rf "$TEST_HOME"; }
trap cleanup EXIT

export HOME="$TEST_HOME"

CC_TEST=1 source "$CC"

# ---------------------------------------------------------------------------
# Fixture helpers — write/read a fresh ~/.claude.json for each case so tests
# do not interfere with each other's state.
# ---------------------------------------------------------------------------
CLAUDE_JSON="$HOME/.claude.json"

write_fixture() {
    cat > "$CLAUDE_JSON" <<'JSON'
{
  "projects": {
    "/tmp/fixture/project-with-false": {
      "hasTrustDialogAccepted": false,
      "allowedTools": ["Bash"]
    },
    "/tmp/fixture/project-missing-key": {
      "allowedTools": ["Read"],
      "mcpServers": {"foo": {}}
    },
    "/tmp/fixture/project-other": {
      "hasTrustDialogAccepted": true
    }
  }
}
JSON
}

# ---------------------------------------------------------------------------
# Case 1: missing file — trust_path_defensively on a non-existent
# HOME/.claude.json returns 0 and creates nothing.
# ---------------------------------------------------------------------------
rm -f "$CLAUDE_JSON" "${CLAUDE_JSON}.bak"
trust_path_defensively "/tmp/fixture/some-path"
rc=$?
if [[ "$rc" -eq 0 ]]; then
    pass "missing-file/returns-0"
else
    fail "missing-file/returns-0" "rc=$rc"
fi
if [[ ! -f "$CLAUDE_JSON" ]]; then
    pass "missing-file/creates-nothing"
else
    fail "missing-file/creates-nothing" "file was created"
fi

# ---------------------------------------------------------------------------
# Case 2: invalid JSON — garbage content returns 0 and leaves the file
# byte-identical (no write, no backup-corruption).
# ---------------------------------------------------------------------------
rm -f "${CLAUDE_JSON}.bak"
printf 'this is not json { [ broken' > "$CLAUDE_JSON"
before_sum="$(shasum "$CLAUDE_JSON" | awk '{print $1}')"
trust_path_defensively "/tmp/fixture/some-path"
rc=$?
after_sum="$(shasum "$CLAUDE_JSON" | awk '{print $1}')"
if [[ "$rc" -eq 0 ]]; then
    pass "invalid-json/returns-0"
else
    fail "invalid-json/returns-0" "rc=$rc"
fi
if [[ "$before_sum" == "$after_sum" ]]; then
    pass "invalid-json/file-unchanged"
else
    fail "invalid-json/file-unchanged" "checksum changed"
fi

# ---------------------------------------------------------------------------
# Case 3: key already set (false) — never upgraded to true.
# ---------------------------------------------------------------------------
write_fixture
trust_path_defensively "/tmp/fixture/project-with-false"
val=$(jq -r '.projects["/tmp/fixture/project-with-false"].hasTrustDialogAccepted' "$CLAUDE_JSON")
if [[ "$val" == "false" ]]; then
    pass "key-false/not-upgraded"
else
    fail "key-false/not-upgraded" "value=$val"
fi

# ---------------------------------------------------------------------------
# Case 4: valid new write — missing key gets written, sibling keys preserved,
# .bak exists, and other projects' entries are untouched.
# ---------------------------------------------------------------------------
write_fixture
rm -f "${CLAUDE_JSON}.bak"
trust_path_defensively "/tmp/fixture/project-missing-key"
val=$(jq -r '.projects["/tmp/fixture/project-missing-key"].hasTrustDialogAccepted' "$CLAUDE_JSON")
if [[ "$val" == "true" ]]; then
    pass "missing-key/written-true"
else
    fail "missing-key/written-true" "value=$val"
fi
sib_tools=$(jq -r '.projects["/tmp/fixture/project-missing-key"].allowedTools | @json' "$CLAUDE_JSON")
if [[ "$sib_tools" == '["Read"]' ]]; then
    pass "missing-key/sibling-allowedTools-preserved"
else
    fail "missing-key/sibling-allowedTools-preserved" "value=$sib_tools"
fi
sib_mcp=$(jq -r '.projects["/tmp/fixture/project-missing-key"].mcpServers | @json' "$CLAUDE_JSON")
if [[ "$sib_mcp" == '{"foo":{}}' ]]; then
    pass "missing-key/sibling-mcpServers-preserved"
else
    fail "missing-key/sibling-mcpServers-preserved" "value=$sib_mcp"
fi
if [[ -f "${CLAUDE_JSON}.bak" ]]; then
    pass "missing-key/backup-exists"
else
    fail "missing-key/backup-exists" "no .bak file"
fi
other_val=$(jq -r '.projects["/tmp/fixture/project-other"].hasTrustDialogAccepted' "$CLAUDE_JSON")
if [[ "$other_val" == "true" ]]; then
    pass "missing-key/other-project-untouched"
else
    fail "missing-key/other-project-untouched" "value=$other_val"
fi

# ---------------------------------------------------------------------------
# load_settings once so CC_SET_PERMISSION_MODE/MODEL/MEMORY_LIMIT_MB/CLAUDE_BIN
# get their documented safe defaults (no settings.conf exists under our
# redirected TEST_HOME) — needed below by start_claude_session's helper calls
# (cc_permission_flag/cc_model_flag/cc_node_opts). CC_SET_AUTO_TRUST is
# overridden per-case after this call.
# ---------------------------------------------------------------------------
load_settings

# ---------------------------------------------------------------------------
# Case 5/6: cmd_add() on-add mode (TRUST-01) — these cases exercise the
# `[[ -t 0 ]]` TTY guard, which requires a REAL pty (a piped stdin is never a
# tty, so it would always short-circuit the guard rather than testing the
# interactive-consent path). `expect` drives a pty-attached `bash -c` child
# that sources cc/cc fresh and calls cmd_add, then sends a scripted answer to
# the interactive prompt. Guarded by `command -v expect` for portability —
# skips (does not fail) if expect is unavailable on the runner.
# ---------------------------------------------------------------------------
run_cmd_add_pty() {
    local proj_name="$1" proj_dir="$2" answer="$3"
    CC_PATH="$CC" PROJ_NAME="$proj_name" PROJ_DIR="$proj_dir" ANSWER="$answer" \
    expect -c '
        set timeout 5
        log_user 0
        spawn bash -c "CC_TEST=1 source \"$env(CC_PATH)\"; cmd_add \"$env(PROJ_NAME)\" \"$env(PROJ_DIR)\""
        expect {
            "Pre-trust this folder" {
                send "$env(ANSWER)\r"
            }
            timeout { exit 1 }
        }
        expect eof
    ' >/dev/null 2>&1
}

if command -v expect >/dev/null 2>&1; then
    # Case 5: on-add, answer "y" — writes.
    write_fixture
    PROJ_Y_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cc-auto-trust-onadd-y-XXXXXX")"
    run_cmd_add_pty "test-onadd-y" "$PROJ_Y_DIR" "y"
    RESOLVED_Y="$(cd "$PROJ_Y_DIR" && pwd -P)"
    val=$(jq -r --arg d "$RESOLVED_Y" '.projects[$d].hasTrustDialogAccepted // "missing"' "$CLAUDE_JSON")
    if [[ "$val" == "true" ]]; then
        pass "on-add/y-answer-writes"
    else
        fail "on-add/y-answer-writes" "value=$val"
    fi
    rm -rf "$PROJ_Y_DIR"

    # Case 6: on-add, answer "n" — does NOT write.
    write_fixture
    PROJ_N_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cc-auto-trust-onadd-n-XXXXXX")"
    run_cmd_add_pty "test-onadd-n" "$PROJ_N_DIR" "n"
    RESOLVED_N="$(cd "$PROJ_N_DIR" && pwd -P)"
    val=$(jq -r --arg d "$RESOLVED_N" '.projects[$d].hasTrustDialogAccepted // "missing"' "$CLAUDE_JSON")
    if [[ "$val" == "missing" ]]; then
        pass "on-add/n-answer-no-write"
    else
        fail "on-add/n-answer-no-write" "value=$val"
    fi
    rm -rf "$PROJ_N_DIR"
else
    echo "SKIP on-add/y-answer-writes (expect not installed)"
    echo "SKIP on-add/n-answer-no-write (expect not installed)"
fi

# ---------------------------------------------------------------------------
# Case 7: on-add invoked with stdin from /dev/null (no TTY) — must NOT write,
# proving the `[[ -t 0 ]] || return 0` guard short-circuits BEFORE the `read`
# can treat an EOF/empty input as consent nobody gave. A plain redirected
# stdin (no pty) is naturally never a tty, so no `expect` is needed here.
# ---------------------------------------------------------------------------
write_fixture
PROJ_NOTTY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cc-auto-trust-onadd-notty-XXXXXX")"
bash -c "CC_TEST=1 source \"$CC\"; cmd_add test-onadd-notty \"$PROJ_NOTTY_DIR\"" < /dev/null >/dev/null 2>&1
RESOLVED_NOTTY="$(cd "$PROJ_NOTTY_DIR" && pwd -P)"
val=$(jq -r --arg d "$RESOLVED_NOTTY" '.projects[$d].hasTrustDialogAccepted // "missing"' "$CLAUDE_JSON")
if [[ "$val" == "missing" ]]; then
    pass "on-add/no-tty-no-write"
else
    fail "on-add/no-tty-no-write" "value=$val"
fi
rm -rf "$PROJ_NOTTY_DIR"

# ---------------------------------------------------------------------------
# Case 8/9: start_claude_session() always/off modes (TRUST-02/03). `tmux` is
# stubbed to a no-op so these tests never spawn a real tmux session (this
# file's role is a stubbed unit test, not an integration test — real-tmux
# exact-match/sweep regressions are covered by cc/test-exact-match.sh and
# cc/test-sweep-orphaned-watchers.sh under the QA-03 private-socket sandbox).
# ---------------------------------------------------------------------------
tmux() { return 0; }

# Case 8: always — silently writes before spawn.
write_fixture
ALWAYS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cc-auto-trust-always-XXXXXX")"
CC_SET_AUTO_TRUST=always
start_claude_session "test-onalways-sess" "$ALWAYS_DIR" "" "" >/dev/null 2>&1
val=$(jq -r --arg d "$ALWAYS_DIR" '.projects[$d].hasTrustDialogAccepted // "missing"' "$CLAUDE_JSON")
if [[ "$val" == "true" ]]; then
    pass "always/writes-before-spawn"
else
    fail "always/writes-before-spawn" "value=$val"
fi
rm -rf "$ALWAYS_DIR"

# Case 9: off — ~/.claude.json is never opened/written; byte-identical after
# an off-mode spawn-hook call.
write_fixture
OFF_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cc-auto-trust-off-XXXXXX")"
CC_SET_AUTO_TRUST=off
before_sum="$(shasum "$CLAUDE_JSON" | awk '{print $1}')"
start_claude_session "test-onoff-sess" "$OFF_DIR" "" "" >/dev/null 2>&1
after_sum="$(shasum "$CLAUDE_JSON" | awk '{print $1}')"
if [[ "$before_sum" == "$after_sum" ]]; then
    pass "off/claude-json-byte-unchanged"
else
    fail "off/claude-json-byte-unchanged" "checksum changed"
fi
rm -rf "$OFF_DIR"

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
