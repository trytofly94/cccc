#!/usr/bin/env bash
# GSD Limit-Watcher — monitors a Claude Code tmux session for rate limits and auto-resumes
#
# Usage: bash limit-watcher.sh <session>
#
#   <session>         tmux target (session name or session:window, e.g. "autobooks-worker:0")
#
# Standalone-only fork of the private GSD companion plugin's limit-watcher (the Conductor-mode
# original). This copy has no Conductor coupling — no --limitwatch flag, no conductor-<session>
# scan. See the private GSD companion plugin's documentation for the Conductor-mode original.
#
# Outputs timestamped status lines to stdout (visible via tmux attach).
# Also writes to a log file:
#   ~/.local/log/gsd-limit-watcher-<session>.log
#
# Debug: tail -f ~/.local/log/gsd-limit-watcher-<session>.log

set -euo pipefail

# Sleep-guard: re-exec under caffeinate -i if not already wrapped.
# caffeinate -i holds the IOPreventsSystemSleep power assertion for this
# process tree — macOS cannot idle-sleep while it is active. The env-var
# sentinel (CC_CAFFEINATED) prevents infinite re-exec.
# Reusable by any cc daemon: source this script or copy the pattern.
with_sleep_guard() {
    if [[ "${CC_CAFFEINATED:-}" != "1" ]] && command -v caffeinate &>/dev/null; then
        exec env CC_CAFFEINATED=1 caffeinate -i bash "${BASH_SOURCE[0]}" "$@"
    fi
}
with_sleep_guard "$@"

WORKER="${1:-}"

if [[ -z "$WORKER" ]]; then
    echo "[LW] ERROR: No session name provided."
    echo "[LW] Usage: bash limit-watcher.sh <session>"
    exit 1
fi

# Strip window index for session-level operations (conductor name, has-session checks)
WORKER_SESSION="${WORKER%%:*}"
# CR-01/T-10-02: catches the narrower case where WORKER is non-empty but strips to
# empty (e.g. ":0") — the WORKER check above only guards the un-stripped value.
[[ -z "$WORKER_SESSION" ]] && { echo "[LW] ERROR: empty session name after strip." >&2; exit 1; }

# Log file for debugging
LOG_DIR="$HOME/.local/log"
mkdir -p "$LOG_DIR"
LOG_SLUG="${WORKER//[^a-zA-Z0-9_-]/_}"
LOG_FILE="$LOG_DIR/gsd-limit-watcher-${LOG_SLUG}.log"

# Rotate on startup: keep only the last 1000 lines (ticks accumulate fast — 30s interval)
if [[ -f "$LOG_FILE" ]] && (( $(wc -l < "$LOG_FILE") > 1000 )); then
    tail -1000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi

# Tombstone: persists pending reset epoch across watcher crashes/restarts.
# File survives process death; the next watcher instance picks it up on startup.
TOMBSTONE_DIR="$HOME/.local/cc-resume-pending"
mkdir -p "$TOMBSTONE_DIR"
TOMBSTONE_FILE="$TOMBSTONE_DIR/${LOG_SLUG}.json"

# Echo-state: single-file, overwritten on each continue — no accumulation.
# Format: "reset_time_str|fired_at_epoch"
# Suppresses re-detection of the same reset-time string for ECHO_SUPPRESS_SECS after firing.
ECHO_DIR="$HOME/.local/cc-resume-echo"
mkdir -p "$ECHO_DIR"
ECHO_FILE="$ECHO_DIR/${LOG_SLUG}"
ECHO_SUPPRESS_SECS=120  # 2 min

write_tombstone() {
    local reset_epoch="$1"
    printf '{"session":"%s","reset_epoch":%s,"detected_at":%s}\n' \
        "$WORKER" "$reset_epoch" "$(date +%s)" > "$TOMBSTONE_FILE" 2>/dev/null || true
}

clear_tombstone() {
    rm -f "$TOMBSTONE_FILE" 2>/dev/null || true
}

read_tombstone_epoch() {
    [[ -f "$TOMBSTONE_FILE" ]] || { echo "0"; return; }
    local epoch
    epoch=$(grep -oE '"reset_epoch":[0-9]+' "$TOMBSTONE_FILE" 2>/dev/null \
        | grep -oE '[0-9]+$' || echo "")
    echo "${epoch:-0}"
}

# --- Echo helpers ---

write_echo() {
    echo "${1}|$(date +%s)" > "$ECHO_FILE" 2>/dev/null || true
}

echo_suppressed() {
    local time_str="$1"
    [[ -f "$ECHO_FILE" ]] || return 1
    local stored_time stored_at
    IFS='|' read -r stored_time stored_at < "$ECHO_FILE" 2>/dev/null || return 1
    [[ "$stored_time" == "$time_str" ]] || return 1
    local age=$(( $(date +%s) - stored_at ))
    (( age < ECHO_SUPPRESS_SECS ))
}

# --- Behavioral helpers ---

# Returns 0 (true) if pane had output within the last N seconds.
pane_active_recently() {
    local target="${1:-$WORKER}" threshold="${2:-60}"
    local last_activity
    last_activity=$(tmux display-message -p -t "=$target" '#{pane_activity}' 2>/dev/null || echo 0)
    (( $(date +%s) - last_activity < threshold ))
}

# Returns 0 (true) if pane content is unchanged over a 10s window — i.e. truly frozen.
pane_frozen() {
    local target="${1:-$WORKER}"
    local snap_a snap_b
    snap_a=$(tmux capture-pane -t "=$target" -p -S -15 2>/dev/null || echo "")
    sleep 10
    snap_b=$(tmux capture-pane -t "=$target" -p -S -15 2>/dev/null || echo "")
    [[ "$snap_a" == "$snap_b" ]]
}

# --- Helpers ---

log() {
    local msg
    msg="[LW $(date '+%H:%M:%S')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE" || true
}

log_file_only() {
    local msg
    msg="[LW $(date '+%H:%M:%S')] $*"
    echo "$msg" >> "$LOG_FILE" || true
}

# Scan a tmux pane for rate limit signals.
# Returns: "TIME|TZ" if found, empty string if not.
scan_for_rate_limit() {
    local target="${1:-$WORKER}"
    local output
    # Visible pane only (no -S into scrollback): after a resume, new output pushes
    # the stale "resets ..." text into scrollback — scanning it caused false positives.
    output=$(tmux capture-pane -t "=$target" -p 2>/dev/null || echo "")

    if [[ -z "$output" ]]; then
        echo ""
        return 0
    fi

    # Pattern 1: "resets 12am (Europe/Berlin)" — with timezone (case-insensitive am/pm)
    local reset_line
    reset_line=$(echo "$output" | grep -ioE 'resets [0-9]{1,2}(:[0-9]{2})?(am|pm) \([^)]+\)' | tail -1 || echo "")
    if [[ -n "$reset_line" ]]; then
        local time_part tz_part
        time_part=$(echo "$reset_line" | sed -E 's/resets ([0-9]{1,2}(:[0-9]{2})?(am|pm)) .*/\1/' | tr '[:upper:]' '[:lower:]')
        tz_part=$(echo "$reset_line" | sed -E 's/.*\(([^)]+)\)/\1/')
        echo "${time_part}|${tz_part}"
        return 0
    fi

    # Pattern 2: "resets 12am" — without timezone (case-insensitive)
    reset_line=$(echo "$output" | grep -ioE 'resets [0-9]{1,2}(:[0-9]{2})?(am|pm)' | tail -1 || echo "")
    if [[ -n "$reset_line" ]]; then
        local time_part
        time_part=$(echo "$reset_line" | sed -E 's/resets ([0-9]{1,2}(:[0-9]{2})?(am|pm))/\1/' | tr '[:upper:]' '[:lower:]')
        echo "${time_part}|Europe/Berlin"
        return 0
    fi

    # Pattern 3: generic rate limit indicators
    if echo "$output" | grep -qE '(out of extra usage|/rate-limit-options)'; then
        echo "UNKNOWN|"
        return 0
    fi

    echo ""
    return 0
}

# Parse a "12am"-style time + timezone into epoch seconds (next occurrence).
parse_reset_epoch() {
    local time_str="$1"
    local tz="${2:-Europe/Berlin}"

    local hour minute ampm
    if [[ "$time_str" =~ ^([0-9]{1,2}):([0-9]{2})(am|pm)$ ]]; then
        hour="${BASH_REMATCH[1]}"; minute="${BASH_REMATCH[2]}"; ampm="${BASH_REMATCH[3]}"
    elif [[ "$time_str" =~ ^([0-9]{1,2})(am|pm)$ ]]; then
        hour="${BASH_REMATCH[1]}"; minute="00"; ampm="${BASH_REMATCH[2]}"
    else
        echo "0"; return 0
    fi

    hour=$((10#$hour))
    if [[ "$ampm" == "am" ]]; then
        [[ $hour -eq 12 ]] && hour=0
    else
        [[ $hour -ne 12 ]] && hour=$((hour + 12))
    fi

    local today_date target_time_str target_epoch now_epoch
    now_epoch=$(date +%s)
    today_date=$(TZ="$tz" date +"%Y-%m-%d")
    target_time_str=$(printf "%s %02d:%s:00" "$today_date" "$hour" "$minute")

    # macOS
    target_epoch=$(TZ="$tz" date -j -f "%Y-%m-%d %H:%M:%S" "$target_time_str" +%s 2>/dev/null || echo "")
    # Linux fallback
    if [[ -z "$target_epoch" ]]; then
        target_epoch=$(TZ="$tz" date -d "$target_time_str" +%s 2>/dev/null || echo "")
    fi
    if [[ -z "$target_epoch" || "$target_epoch" == "0" ]]; then
        echo "0"; return 0
    fi

    # A live rate-limit message means the reset is still pending → the displayed
    # time refers to the NEXT future occurrence. If today's occurrence is already
    # in the past (e.g. "2:40am" seen at 23:25 = tomorrow morning), roll forward a
    # day — otherwise wait_secs goes negative and the caller fires "continue"
    # immediately, repeatedly, until midnight flips the date. A small grace
    # preserves the legit "watcher came online seconds after the reset" resume-now
    # case (handled by the tombstone path with a stored epoch, not by re-parsing).
    local PAST_GRACE=120
    if (( target_epoch < now_epoch - PAST_GRACE )); then
        target_epoch=$((target_epoch + 86400))
    fi
    echo "$target_epoch"
}

# Notify via tmux display-message (safe overlay — does NOT touch Claude's input field)
notify_user() {
    local msg="${1:-}"
    local target="${2:-$WORKER}"
    # tmux display-message shows a status-bar overlay — no Claude input interaction
    tmux display-message -t "=$target" -d 8000 "$msg" 2>/dev/null || true
    log "$msg"
}

# Send the "continue" sequence to the worker session.
# Sequence: Escape (close any dialog) → Ctrl-U (clear input line) → type "continue" → Enter
_send_continue_keys() {
    local target="$1"
    # Step 1: Escape — close rate-limit dialog or any overlay
    tmux send-keys -t "=$target" Escape 2>/dev/null || true
    sleep 0.5
    # Step 2: Ctrl-U — clear any existing content in the input field
    tmux send-keys -t "=$target" C-u 2>/dev/null || true
    sleep 0.3
    # Step 3: Type "continue"
    tmux send-keys -t "=$target" "continue" 2>/dev/null || true
    sleep 0.5
    # Step 4: Enter — submit
    tmux send-keys -t "=$target" C-m 2>/dev/null || true
    sleep 0.3
}

send_continue() {
    local target="${1:-$WORKER}"
    log "Sending continue to: $target"
    _send_continue_keys "$target"
    log "Continue sent."
    # Verify: if the pane shows no activity within 30s AND is truly frozen
    # (pane_frozen: content unchanged over a 10s window), the keys likely missed
    # (e.g. Escape didn't hit the dialog). Retry exactly ONCE — never loop.
    # The frozen-check avoids retyping "continue" into a session that simply
    # finished fast and went idle.
    sleep 30
    if ! pane_active_recently "$target" 35 && pane_frozen "$target"; then
        log "⚠  Pane frozen 40s after continue — retrying once..."
        _send_continue_keys "$target"
        log "Retry sent."
    fi
}

# --- Main loop ---

POLL_INTERVAL=30   # seconds between scans
MAX_WAIT_SECS=21600  # 6h — no rate-limit window is longer; longer = stale-echo day-rollover
# After send_continue, ignore rate-limit signals for this many seconds.
# Prevents stale scrollback from triggering a re-detection immediately after resume.
CONTINUE_COOLDOWN=180
LAST_CONTINUE_EPOCH=0

# SIGCONT trap: macOS delivers SIGCONT to frozen processes the instant they
# thaw after system wake. We run sleeps as background jobs and store the PID
# so the trap can kill them immediately — making every wake event an instant
# wall-clock check rather than waiting out the remainder of the sleep interval.
_SLEEP_PID=""
_wake_interrupt() { [[ -n "${_SLEEP_PID:-}" ]] && kill "$_SLEEP_PID" 2>/dev/null || true; }
trap '_wake_interrupt' SIGCONT

# Tombstone startup check: resume a pending deadline that survived a crash/restart.
_tombstone_epoch=$(read_tombstone_epoch)
if (( _tombstone_epoch > 0 )); then
    _now=$(date +%s)
    if (( _tombstone_epoch <= _now )); then
        log "📋 Tombstone found — reset time already passed, sending continue now..."
        send_continue "$WORKER"
        clear_tombstone
        LAST_CONTINUE_EPOCH=$(date +%s)
    else
        _mins=$(( (_tombstone_epoch - _now + 59) / 60 ))
        log "📋 Tombstone found — re-entering wait for ${_mins} more min until reset+buffer..."
        LAST_CONTINUE_EPOCH=$(date +%s)
        while (( $(date +%s) < _tombstone_epoch )); do
            remaining=$(( _tombstone_epoch - $(date +%s) ))
            log_file_only "  tombstone wait — ${remaining}s remaining"
            sleep 60 & _SLEEP_PID=$!; wait "$_SLEEP_PID" 2>/dev/null || true; _SLEEP_PID=""
        done
        log "Tombstone reset time reached. Sending continue..."
        send_continue "$WORKER"
        clear_tombstone
        LAST_CONTINUE_EPOCH=$(date +%s)
        log "✓ Continue sent. Cooldown for ${CONTINUE_COOLDOWN}s before next scan."
    fi
fi

log "watching: $WORKER_SESSION  (log: tail -f $LOG_FILE)"
log_file_only "  Session target:    $WORKER"
log_file_only "  Session name:      $WORKER_SESSION"
log_file_only "  Poll interval:     ${POLL_INTERVAL}s"
log_file_only "  Continue cooldown: ${CONTINUE_COOLDOWN}s"

while true; do
    # Check worker session still alive
    if ! tmux has-session -t "=$WORKER_SESSION" 2>/dev/null; then
        log "Session '$WORKER_SESSION' no longer exists. Limit-Watcher exiting."
        exit 0
    fi

    # Cooldown: skip scanning for a bit after send_continue to avoid stale-scrollback re-detection
    now_epoch=$(date +%s)
    if (( LAST_CONTINUE_EPOCH > 0 )); then
        cooldown_remaining=$(( CONTINUE_COOLDOWN - (now_epoch - LAST_CONTINUE_EPOCH) ))
        if (( cooldown_remaining > 0 )); then
            echo "[LW $(date '+%H:%M:%S')] cooldown — skipping scan for ${cooldown_remaining}s more" >> "$LOG_FILE" || true
            sleep "$POLL_INTERVAL"
            continue
        fi
    fi

    # Gate: if Claude was writing output within the last 60s, it is not rate-limited.
    # pane_activity is a tmux-native timestamp — no scrollback parsing needed.
    if pane_active_recently "$WORKER" 60; then
        log_file_only "pane active within 60s — no rate limit possible, skipping scan"
        sleep "$POLL_INTERVAL"
        continue
    fi

    limit_info=$(scan_for_rate_limit "$WORKER")
    LIMIT_SESSION="$WORKER"

    if [[ -z "$limit_info" ]]; then
        echo "[LW $(date '+%H:%M:%S')] tick — no limit detected" >> "$LOG_FILE" || true
        sleep "$POLL_INTERVAL"
        continue
    fi

    time_part=$(echo "$limit_info" | cut -d'|' -f1)
    tz_part=$(echo "$limit_info"   | cut -d'|' -f2)

    if [[ "$time_part" == "UNKNOWN" ]]; then
        log "⚠  Rate limit detected in ${LIMIT_SESSION} (reset time unknown). Will retry in 60 min."
        notify_user "[LW] Rate limit detected — auto-resume in ~60 min" "$LIMIT_SESSION"
        LAST_CONTINUE_EPOCH=$(date +%s)
        unknown_target=$(($(date +%s) + 3600))
        while (( $(date +%s) < unknown_target )); do
            sleep 60 & _SLEEP_PID=$!; wait "$_SLEEP_PID" 2>/dev/null || true; _SLEEP_PID=""
        done
        log "Attempting continue after 60 min wait (unknown reset time)..."
        send_continue "$LIMIT_SESSION"
        LAST_CONTINUE_EPOCH=$(date +%s)
        log "✓ Continue sent. Cooldown for ${CONTINUE_COOLDOWN}s before next scan."
    else
        reset_epoch=$(parse_reset_epoch "$time_part" "$tz_part")
        now_epoch=$(date +%s)

        # Guard: if parse failed (returns 0) or reset is impossibly far, fall back to 60 min
        if [[ -z "$reset_epoch" || "$reset_epoch" -eq 0 ]]; then
            log "⚠  Could not parse reset time '${time_part}'. Falling back to 60 min wait."
            notify_user "[LW] Rate limit detected (parse failed) — auto-resume in ~60 min" "$LIMIT_SESSION"
            LAST_CONTINUE_EPOCH=$(date +%s)
            sleep 3600 & _SLEEP_PID=$!; wait "$_SLEEP_PID" 2>/dev/null || true; _SLEEP_PID=""
            send_continue "$LIMIT_SESSION"
            LAST_CONTINUE_EPOCH=$(date +%s)
            sleep "$POLL_INTERVAL"
            continue
        fi

        wait_secs=$((reset_epoch - now_epoch))

        # Add 30s buffer after reset to ensure API is available
        BUFFER=30
        target_wake_epoch=$((reset_epoch + BUFFER))

        if (( wait_secs <= 0 )); then
            # Echo suppression: same reset-time string fired within suppression window → own echo, skip.
            if echo_suppressed "$time_part"; then
                log_file_only "echo suppressed — '${time_part}' fired recently, skipping"
                sleep "$POLL_INTERVAL"
                continue
            fi
            # Quorum: wait 10s, re-capture — if pane changed Claude is running, not rate-limited.
            log "⏸  Rate limit in ${LIMIT_SESSION} — reset time ${time_part} already passed, verifying (10s)..."
            if ! pane_frozen "$LIMIT_SESSION"; then
                log_file_only "quorum: pane changed — Claude active, suppressing false positive"
                sleep "$POLL_INTERVAL"
                continue
            fi
            log "Quorum confirmed — pane frozen, sending continue..."
            notify_user "[LW] Rate limit — reset already passed, resuming now" "$LIMIT_SESSION"
        elif (( wait_secs > MAX_WAIT_SECS )); then
            # Implausibly long wait — parse_reset_epoch rolled the time to next day because
            # PAST_GRACE (120s) was exceeded. Check if today's occurrence was actually recent
            # (e.g. watcher first saw "resets 1am" at 01:17 → rolled to tomorrow = 1423 min).
            # If the unrolled today-epoch is within MISSED_GRACE, treat as "just-missed" reset.
            MISSED_GRACE=10800  # 3 hours — no valid rate-limit text persists longer than this
            today_epoch=$((reset_epoch - 86400))
            missed_secs=$(( now_epoch - today_epoch ))
            if (( missed_secs >= 0 && missed_secs < MISSED_GRACE )); then
                # Same echo suppression as the wait_secs<=0 path to avoid repeat fires.
                if echo_suppressed "$time_part"; then
                    log_file_only "echo suppressed — '${time_part}' missed-reset fired recently, skipping"
                    sleep "$POLL_INTERVAL"
                    continue
                fi
                missed_mins=$(( (missed_secs + 59) / 60 ))
                log "⏸  Rate limit in ${LIMIT_SESSION} — reset ${time_part} missed by ~${missed_mins} min, verifying (10s)..."
                if ! pane_frozen "$LIMIT_SESSION"; then
                    log_file_only "quorum: pane changed — Claude active, suppressing false positive"
                    sleep "$POLL_INTERVAL"
                    continue
                fi
                log "Quorum confirmed — pane frozen, sending continue (missed reset ~${missed_mins} min ago)..."
                notify_user "[LW] Rate limit — reset ${time_part} missed by ~${missed_mins} min, resuming now" "$LIMIT_SESSION"
                # fall through to send_continue below
            else
                wait_mins=$(( (wait_secs + 59) / 60 ))
                log "⚠  Implausible wait of ${wait_mins} min for '${time_part}' — likely stale echo, skipping"
                sleep "$POLL_INTERVAL"
                continue
            fi
        else
            wait_mins=$(( (wait_secs + 59) / 60 ))
            log "⏸  Rate limit detected in ${LIMIT_SESSION} — resets ${time_part} (${tz_part:-local})"
            log "   Waiting ${wait_mins} min until reset, then auto-resuming..."
            notify_user "[LW] Rate limit — auto-resume at ${time_part} ${tz_part:-local} (~${wait_mins} min)" "$LIMIT_SESSION"
            write_tombstone "$target_wake_epoch"

            LAST_CONTINUE_EPOCH=$(date +%s)
            while (( $(date +%s) < target_wake_epoch )); do
                remaining=$(( target_wake_epoch - $(date +%s) ))
                log_file_only "  waiting — ${remaining}s until reset+buffer"
                sleep 60 & _SLEEP_PID=$!; wait "$_SLEEP_PID" 2>/dev/null || true; _SLEEP_PID=""
            done
        fi
        log "Reset time reached. Sending continue..."
        send_continue "$LIMIT_SESSION"
        write_echo "$time_part"
        clear_tombstone
        LAST_CONTINUE_EPOCH=$(date +%s)
        log "✓ Continue sent. Cooldown for ${CONTINUE_COOLDOWN}s before next scan."
    fi

    sleep "$POLL_INTERVAL"
done
