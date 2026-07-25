#!/bin/bash
# test-limit-watcher-injection.sh — Phase 9 Plan 03 (LWATCH-04/05/06, CR-01
# gap-closure) sandboxed regression test for cc/cc's start_limit_watcher().
#
# Re-runs the exact CR-01 command-injection PoC (a tmux session name with an
# embedded single quote) against the REAL, fixed start_limit_watcher() and
# proves the injection no longer fires. Also runs a paired kill-cascade
# assertion proving stop_limit_watcher() still tears down a session spawned
# via the new argv/exec form.
#
# MANDATORY per CLAUDE.md "tmux in Test-Suites & Skripten — Pflicht-Sandbox"
# (QA-03): this test spawns REAL tmux sessions, so it unsets TMUX and uses a
# private per-PID TMUX_TMPDIR before any tmux call, and tears down via
# `tmux kill-server` (scoped to that private socket) + `rm -rf`. Every
# kill-session/has-session target is guarded non-empty — never an empty-target
# kill on the default socket.
#
# Run: bash cc/test-limit-watcher-injection.sh
# Exit 0 = all assertions pass; Exit 1 = one or more failures.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CC="$SCRIPT_DIR/cccc"

FAIL=0

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1${2:+ ($2)}"; FAIL=$(( FAIL + 1 )); }

# Poll instead of a fixed sleep: a fresh TMUX_TMPDIR means this file's first
# tmux call has to cold-start a new private-socket server, whose latency
# varies a lot more on a shared/virtualized CI runner than on a local Mac —
# a fixed 1s sleep proved too short on GitHub Actions macos-latest even
# though it was 100% reliable locally.
wait_for_session() {
    local target="$1" i=0
    while (( i < 50 )); do
        tmux has-session -t "$target" 2>/dev/null && return 0
        sleep 0.1
        (( i++ ))
    done
    return 1
}

# Prefix-match variant for session names containing a bare trailing '#':
# CI run 29367169233's diagnostic capture showed tmux 3.7 (installed fresh
# via brew on the macos-latest runner) silently drops a trailing lone '#'
# from a session name at creation time, while local tmux 3.6a preserves it
# byte-for-byte — the live session came back as "...poc_marker " (no '#'),
# so an EXACT has-session match against our shell-side name (still holding
# the '#') never matches on that tmux version. list-sessions + a fixed-
# string prefix match on everything before the '#' is stable across both.
wait_for_session_prefix() {
    local name_prefix="$1" i=0
    while (( i < 50 )); do
        tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -qF "$name_prefix" && return 0
        sleep 0.1
        (( i++ ))
    done
    return 1
}

# ---------------------------------------------------------------------------
# Sandbox setup (MANDATORY, QA-03): never touch the user's default tmux
# server. unset TMUX (it beats TMUX_TMPDIR when tmux resolves "current
# session") and point every tmux call at a private per-PID socket dir,
# created BEFORE any tmux invocation.
# ---------------------------------------------------------------------------

unset TMUX
TMUX_TMPDIR="/tmp/cc-limitwatch-injtest-$$"
mkdir -p "$TMUX_TMPDIR"
export TMUX_TMPDIR

cleanup() {
    tmux kill-server 2>/dev/null
    rm -rf "$TMUX_TMPDIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Stub watcher — a fast, self-contained stand-in for the real 465-line
# limit-watcher.sh. Its body just sleeps so `tmux has-session` can observe a
# live spawn without waiting on/parsing the real watcher's behavior.
#
# Lifetime must comfortably outlast this file's own has-session poll window
# (up to ~5s) plus whatever cold-start latency the environment adds — a
# prior 5s stub lifetime raced the poll bound on a loaded GitHub Actions
# macos runner: by the time the last poll attempt ran, the stub process
# had already exited, tmux tore down the now-empty session, and — since it
# was the sole session on this private socket — the server itself exited
# too ("no server running" observed via diagnostic capture, run 29366662176).
# 60s leaves an order-of-magnitude margin; the test kills the session itself
# right after asserting, so the stub is never actually left running that long.
# ---------------------------------------------------------------------------

STUBDIR="$TMUX_TMPDIR/stub"
mkdir -p "$STUBDIR"
cat > "$STUBDIR/limit-watcher.sh" <<'STUB'
#!/bin/bash
sleep 60
STUB
chmod +x "$STUBDIR/limit-watcher.sh"

# ---------------------------------------------------------------------------
# Load the REAL cc/cc functions (start_limit_watcher, stop_limit_watcher,
# is_watcher_active) without launching the dashboard, then point
# CC_SCRIPT_DIR at the stub so the argv form targets it, not the real
# watcher. Point CC_PLUGINS_DIR at an empty, nonexistent sandbox dir BEFORE
# sourcing so load_plugins() (invoked unconditionally at source-time, even
# under CC_TEST=1) never loads this machine's real local plugins
# (~/.config/claude-control/plugins/*.sh) into the test shell.
# ---------------------------------------------------------------------------

export CC_PLUGINS_DIR="$TMUX_TMPDIR/no-plugins-here"
CC_TEST=1 source "$CC"
CC_SCRIPT_DIR="$STUBDIR"

# ---------------------------------------------------------------------------
# CR-01 PoC: session name with an embedded single quote — the exact
# breakout pattern from 09-REVIEW.md. With the OLD spliced-shell-string
# form, tmux would `sh -c` the string, the quote would close early and
# `; touch $MARKER #` would execute. With the argv/exec fix, tmux execs
# `bash <stub> "$session_name"` directly and the touch never runs.
# ---------------------------------------------------------------------------

MARKER="$TMUX_TMPDIR/poc_marker"
rm -f "$MARKER"

session_name="evil'; touch $MARKER #"

start_output=$(start_limit_watcher "$session_name" 2>&1)
start_rc=$?

# Everything up to (not including) a bare trailing '#' is stable across tmux
# versions — only the '#' itself (and anything after it) is at risk of being
# dropped at creation time on some tmux versions. Nothing follows the '#' in
# this PoC string, so the prefix is the full name modulo that one character.
name_prefix="limit-watcher-${session_name%%#*}"

# Positive-spawn check FIRST: prove start_limit_watcher actually attempted
# and completed a spawn for this pathological name, rather than silently
# no-op'ing on the embedded characters. A silent no-op would also leave the
# marker absent and would otherwise produce a false pass below.
if [[ -n "$session_name" ]] && wait_for_session_prefix "$name_prefix"; then
    pass "injection/watcher-spawned-for-pathological-name"
else
    fail "injection/watcher-spawned-for-pathological-name"
    # Diagnostics only (CI-vs-local divergence, #13-04) — does not affect
    # pass/fail, just makes the next run's log self-explanatory instead of
    # requiring another push-and-observe round to learn what happened.
    echo "DIAG start_limit_watcher rc=$start_rc output=[$start_output]" >&2
    echo "DIAG expected name prefix: $name_prefix" >&2
    echo "DIAG live sessions on this socket:" >&2
    tmux list-sessions -F '#{session_name}' 2>&1 | sed 's/^/DIAG   /' >&2
fi

if [[ ! -e "$MARKER" ]]; then
    pass "injection/marker-not-created"
else
    fail "injection/marker-not-created" "marker file exists — injection fired"
fi

# Teardown this session before the next assertion (guarded non-empty target).
# Resolve the actual live name first (rather than assuming it byte-matches
# our shell-side session_name — see name_prefix comment above) so the kill
# still uses an exact, non-empty '=' target per QA-03, just against tmux's
# real, possibly '#'-truncated name.
actual_session_name=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -F "$name_prefix" | head -1)
if [[ -n "$actual_session_name" ]]; then
    tmux kill-session -t "=${actual_session_name}" 2>/dev/null
fi

# ---------------------------------------------------------------------------
# Kill-cascade assertion: proves the invocation-form change did not break
# stop_limit_watcher()'s paired teardown path.
# ---------------------------------------------------------------------------

benign_name="benign_name"
start_limit_watcher "$benign_name" >/dev/null

if [[ -n "$benign_name" ]] && wait_for_session "=limit-watcher-${benign_name}"; then
    pass "kill-cascade/watcher-spawned"
else
    fail "kill-cascade/watcher-spawned"
fi

stop_limit_watcher "$benign_name" >/dev/null

if [[ -n "$benign_name" ]] && ! tmux has-session -t "=limit-watcher-${benign_name}" 2>/dev/null; then
    pass "kill-cascade/watcher-stopped"
else
    fail "kill-cascade/watcher-stopped" "session still alive after stop_limit_watcher"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo "RESULT: $FAIL failures"
exit $(( FAIL > 0 ? 1 : 0 ))
