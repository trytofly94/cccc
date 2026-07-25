#!/usr/bin/env bash
# test-settings-webui.sh — Phase 15 Plan 01 (SETUI-05/06) regression test for
# cc-webui.py's settings.conf data layer (parse/validate/serialize/atomic
# write) and the /api/settings GET+PUT HTTP handlers, plus a bash<->Python
# enum drift guard proving cccc/cccc write_setting()'s whitelist and
# cc-webui.py's SETTINGS_ENUMS constants cannot silently diverge.
#
# No tmux is spawned by this file, so the tmux-sandbox rule (QA-03) does not
# apply -- but the background python3 HTTP server it spawns for the live
# smoke test is still torn down via a trap, guarded by a non-empty-PID check.
#
# Run: bash cccc/test-settings-webui.sh
# Exit 0 = all assertions pass; Exit 1 = one or more failures.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEBUI="$SCRIPT_DIR/cc-webui.py"

FAIL=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1${2:+ ($2)}"; FAIL=$(( FAIL + 1 )); }

TMPDIR_TEST="$(mktemp -d "${TMPDIR:-/tmp}/cc-settings-webui-test.XXXXXX")"
SERVER_PID=""

cleanup() {
    if [[ -n "$SERVER_PID" ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Part 1: Python-level assertions (parse/validate/serialize/atomic_write) and
# the bash<->Python enum drift guard, run in one python3 process that loads
# cc-webui.py via importlib (the filename has a hyphen and is not import-safe
# by name).
# ---------------------------------------------------------------------------

PY_RESULT="$TMPDIR_TEST/py_result.txt"

set +e
python3 - "$WEBUI" "$TMPDIR_TEST" > "$PY_RESULT" 2>&1 <<'PYEOF'
import importlib.util
import os
import re
import sys

webui_path, tmpdir = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("ccwebui_under_test", webui_path)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

results = []


def check(ok, label, detail=""):
    results.append((ok, label, detail))


# (1) read_settings on a missing path yields documented defaults.
r = m.read_settings(os.path.join(tmpdir, "nonexistent-settings.conf"))
check(r.get("PERMISSION_MODE") == "auto", "defaults/PERMISSION_MODE-auto",
      "got %r" % (r.get("PERMISSION_MODE"),))
check(r.get("MEMORY_LIMIT_MB") == "6144", "defaults/MEMORY_LIMIT_MB-6144",
      "got %r" % (r.get("MEMORY_LIMIT_MB"),))
# IDLE_WATCHDOG (v4.0 final feature step, opt-in idle-session reclaim daemon)
# MUST default to "off" -- a missing/absent settings.conf must never reclaim.
check(r.get("IDLE_WATCHDOG") == "off", "defaults/IDLE_WATCHDOG-off",
      "got %r" % (r.get("IDLE_WATCHDOG"),))


# (2) validate_settings rejects the four named bad-value cases, each via a
# raised ValueError.
def expect_reject(model, label):
    try:
        m.validate_settings(model)
        check(False, label, "no ValueError raised")
    except ValueError as exc:
        check(True, label, str(exc))


expect_reject({"PERMISSION_MODE": "bogus"}, "reject/PERMISSION_MODE-bogus")
# PERMISSION_MODE_FALLBACK's whitelist deliberately excludes "auto" (it is a
# degrade TARGET, never itself "auto") -- this must be rejected too.
expect_reject({"PERMISSION_MODE_FALLBACK": "auto"}, "reject/PERMISSION_MODE_FALLBACK-auto")
expect_reject({"CLAUDE_BIN": "claude; rm -rf /"}, "reject/CLAUDE_BIN-metachar")
expect_reject({"MEMORY_LIMIT_MB": "notnum"}, "reject/MEMORY_LIMIT_MB-notnum")
expect_reject({"IDLE_WATCHDOG": "bogus"}, "reject/IDLE_WATCHDOG-bogus")
expect_reject({"IDLE_WATCHDOG": "true"}, "reject/IDLE_WATCHDOG-true-not-on")

# (2b) CR-01 regression: newline/CR/NUL rejection across every settings key
# (16-01-PLAN.md Task 1, closes .planning/phases/15-settings-web-ui/15-REVIEW.md
# CR-01). validate_settings() must reject ANY string value containing \n, \r,
# or \x00 -- not just CLAUDE_BIN's shell-metachar subset.
expect_reject(
    {"CLAUDE_BIN": "claude\nPERMISSION_MODE=bypassPermissions"},
    "reject/CLAUDE_BIN-newline-injection-exact-CR01-payload",
)
expect_reject({"MODEL": "claude-opus\rextra"}, "reject/MODEL-cr")
expect_reject({"EXTRA_FLAGS": "--foo\n--bar"}, "reject/EXTRA_FLAGS-newline")
expect_reject({"CLAUDE_BIN": "claude\x00bin"}, "reject/CLAUDE_BIN-nul")

# SEC-03 preservation: normal free-text flags (spaces, dashes) must still be
# accepted -- the fix must not over-restrict legitimate launch-flag syntax.
try:
    m.validate_settings({
        "EXTRA_FLAGS": "--dangerously-skip-permissions --model foo",
        "CLAUDE_BIN": "/usr/local/bin/claude",
    })
    check(True, "accept/free-text-flags-with-spaces-dashes")
except ValueError as exc:
    check(False, "accept/free-text-flags-with-spaces-dashes", str(exc))

# End-to-end: prove the exact CR-01 payload is stopped by validate_settings()
# BEFORE it can ever reach serialize_settings() -- and, separately, prove the
# injection mechanism itself is real (i.e. this isn't a vacuous test) by
# showing that serialize+reparse of the SAME unvalidated payload would indeed
# have overridden PERMISSION_MODE, exactly as CR-01 reproduced.
cr01_payload = {"CLAUDE_BIN": "claude\nPERMISSION_MODE=bypassPermissions"}
try:
    m.validate_settings(cr01_payload)
    check(False, "reject/CR01-payload-blocked-before-serialize",
          "no ValueError raised -- injection path still reachable")
except ValueError:
    check(True, "reject/CR01-payload-blocked-before-serialize")
    full_model = dict(m.SETTINGS_DEFAULTS)
    full_model.update(cr01_payload)
    text = m.serialize_settings(full_model)
    reparsed = m.parse_settings_conf(text)
    check(reparsed.get("PERMISSION_MODE") == "bypassPermissions",
          "reject/CR01-payload-would-have-injected-if-unvalidated",
          "got %r" % (reparsed.get("PERMISSION_MODE"),))

# (3) full serialize -> parse round-trip of a valid 10-key model is identity.
valid_model = {
    "PERMISSION_MODE": "acceptEdits",
    "PERMISSION_MODE_FALLBACK": "plan",
    "MODEL": "claude-opus",
    "MEMORY_LIMIT_MB": "8192",
    "CLAUDE_BIN": "claude",
    "EXTRA_FLAGS": "--verbose",
    "LIMIT_WATCHER": "manual",
    "AUTO_TRUST": "always",
    "SHOW_LOGO": "false",
    "IDLE_WATCHDOG": "on",
}
text = m.serialize_settings(valid_model)
roundtrip = m.parse_settings_conf(text)
check(roundtrip == valid_model, "roundtrip/serialize-parse-identity",
      "got %r" % (roundtrip,))

# (4) atomic_write on a temp file in this per-PID temp dir creates a `.bak-*`
# backup on the second write (none on the first, since there's nothing to
# back up yet).
target = os.path.join(tmpdir, "atomic-target.conf")
b1 = m.atomic_write(target, "PERMISSION_MODE=auto\n")
b2 = m.atomic_write(target, "PERMISSION_MODE=plan\n")
check(b1 is None, "atomic_write/first-write-no-backup", "got %r" % (b1,))
check(b2 is not None and os.path.exists(b2) and ".bak-" in b2,
      "atomic_write/second-write-creates-backup", "backup=%r" % (b2,))

# ---------------------------------------------------------------------------
# Drift guard: extract cccc/cccc write_setting()'s bash enum case-label
# literals and assert every one of them is a member of the corresponding
# cc-webui.py SETTINGS_ENUMS constant. A future bash-side enum addition that
# isn't mirrored in Python fails HERE instead of silently accepting/rejecting
# mismatched values at runtime.
# ---------------------------------------------------------------------------

cc_path = os.path.join(os.path.dirname(webui_path), "cccc")
with open(cc_path, "r", encoding="utf-8") as f:
    cc_text = f.read()

start = cc_text.find("write_setting() {")
check(start != -1, "drift/write_setting-found-in-cccc")
end = cc_text.find("\n}\n", start) if start != -1 else -1
body = cc_text[start:end] if start != -1 and end != -1 else ""


def bash_enum_literals(key):
    pattern = r'%s\)\s*\n\s*case "\$value" in\s*\n\s*([^\n]+)\)' % re.escape(key)
    match = re.search(pattern, body)
    if not match:
        return None
    return tuple(match.group(1).split("|"))


for key in ("PERMISSION_MODE", "PERMISSION_MODE_FALLBACK", "LIMIT_WATCHER",
            "AUTO_TRUST", "SHOW_LOGO", "IDLE_WATCHDOG"):
    bash_values = bash_enum_literals(key)
    check(bash_values is not None, "drift/%s-extracted-from-bash" % key,
          "body empty or pattern not found" if bash_values is None else "")
    if bash_values is not None:
        py_values = m.SETTINGS_ENUMS.get(key, ())
        missing = [v for v in bash_values if v not in py_values]
        check(not missing, "drift/%s-bash-subset-of-python" % key,
              "bash=%r python=%r missing=%r" % (bash_values, py_values, missing))

# ---------------------------------------------------------------------------
# Emit PASS/FAIL lines for the bash harness to re-tally and print.
# ---------------------------------------------------------------------------
fail_count = 0
for ok, label, detail in results:
    if ok:
        print("PASS %s" % label)
    else:
        print("FAIL %s%s" % (label, (" (" + detail + ")") if detail else ""))
        fail_count += 1

sys.exit(1 if fail_count else 0)
PYEOF
PY_RC=$?
set -e

while IFS= read -r line; do
    case "$line" in
        PASS\ *) pass "${line#PASS }" ;;
        FAIL\ *) fail "${line#FAIL }" ;;
        *) echo "$line" ;;
    esac
done < "$PY_RESULT"

if [[ $PY_RC -ne 0 ]] && ! grep -q '^FAIL' "$PY_RESULT"; then
    # python3 itself crashed (traceback) rather than emitting FAIL lines.
    fail "python-harness/no-traceback" "python3 exited $PY_RC without emitting FAIL lines; see output above"
fi

# ---------------------------------------------------------------------------
# Part 2: live-server smoke test -- start a real cc-webui.py HTTP server,
# GET /api/settings (expect the 10 keys), PUT a bad PERMISSION_MODE (expect
# HTTP 400), then tear down. Guard every kill with a non-empty PID check.
# ---------------------------------------------------------------------------

PROJECTS_TMP="$TMPDIR_TEST/projects.conf"
SETTINGS_TMP="$TMPDIR_TEST/settings.conf"
printf 'demo|/tmp\n' > "$PROJECTS_TMP"

SERVER_LOG="$TMPDIR_TEST/server.log"
python3 "$WEBUI" --config "$PROJECTS_TMP" --settings "$SETTINGS_TMP" \
    --host 127.0.0.1 --no-browser > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!

URL=""
# 20s budget (200 x 0.1s): GitHub-hosted macos-latest runners have been observed
# taking several seconds longer than a local dev machine to schedule and start
# the python3 child process under CI load. Also bail out early (rather than
# spinning the full budget) if the server process has already died, so the
# failure message carries the real crash reason instead of a generic timeout.
for _ in $(seq 1 200); do
    if grep -q '^URL=' "$SERVER_LOG" 2>/dev/null; then
        URL=$(grep '^URL=' "$SERVER_LOG" | head -1 | cut -d= -f2-)
        break
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        break
    fi
    sleep 0.1
done

if [[ -n "$URL" ]]; then
    pass "smoke/server-started"
else
    if kill -0 "$SERVER_PID" 2>/dev/null; then
        SERVER_STATE="still running (timed out waiting for URL= line)"
    else
        # Guard the `wait` under `set -euo pipefail`: a crashed server exits
        # non-zero, and an unguarded `wait` would propagate that rc and abort
        # the script (via set -e) BEFORE this diagnostic fail line prints.
        wait "$SERVER_PID" 2>/dev/null && rc=0 || rc=$?
        SERVER_STATE="process exited (rc=$rc)"
    fi
    fail "smoke/server-started" "$SERVER_STATE; log: $(cat "$SERVER_LOG" 2>/dev/null)"
fi

if [[ -n "$URL" ]]; then
    GET_BODY=$(curl -s "$URL/api/settings" || true)
    GET_KEY_COUNT=$(printf '%s' "$GET_BODY" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(sum(1 for k in d if k != "path"))
except Exception:
    print(-1)
' 2>/dev/null || echo -1)
    if [[ "$GET_KEY_COUNT" == "10" ]]; then
        pass "smoke/get-settings-10-keys"
    else
        fail "smoke/get-settings-10-keys" "got $GET_KEY_COUNT keys; body: $GET_BODY"
    fi

    PUT_STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X PUT "$URL/api/settings" \
        -H 'Content-Type: application/json' \
        -d '{"PERMISSION_MODE":"bogus"}' || echo "000")
    if [[ "$PUT_STATUS" == "400" ]]; then
        pass "smoke/put-bad-permission-mode-400"
    else
        fail "smoke/put-bad-permission-mode-400" "got HTTP $PUT_STATUS"
    fi
else
    fail "smoke/get-settings-10-keys" "skipped -- server did not start"
    fail "smoke/put-bad-permission-mode-400" "skipped -- server did not start"
fi

if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo "RESULT: $FAIL failures"
exit $(( FAIL > 0 ? 1 : 0 ))
