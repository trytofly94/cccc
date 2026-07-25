#!/bin/bash
#
# install.sh — Idempotent installer for the Claude Code Control Center (cccc)
#
# Performs docs/SETUP.md Steps 1-5 idempotently:
#   1. Checks dependencies (tmux, jq hard-required; python3 soft-warned)
#   2. Verifies prerequisites (cccc/cccc, cccc/cc-webui.py, scripts/claude-cleanup
#      exist in this checkout)
#   3. Copies cccc/cccc + cccc/cc-webui.py to ~/.local/bin, then ensures the
#      transitional ~/.local/bin/cc -> ~/.local/bin/cccc compatibility symlink
#      via scripts/link-cc-compat.sh, so every existing `cc <subcommand>`
#      invocation keeps working unchanged
#   4. Vendors scripts/claude-cleanup to ~/.local/bin/claude-cleanup
#   5. Creates ~/.config/claude-control/ (the shared project registry dir) and
#      writes example projects.conf / settings.conf if not already present
#
# PLUS (macOS-only, opt-in): offers to install a twice-daily launchd schedule
# for claude-cleanup (04:00 + 12:00), mirroring the existing
# com.user.claude-orphan-cleanup convention. On Linux this offer is skipped
# silently — no prompt, no error.
#
# Usage:
#   ./install.sh                       # interactive
#   ./install.sh --yes                 # non-interactive, accept defaults
#   ./install.sh --skip-launchd        # never offer the launchd install
#   ./install.sh --yes --skip-launchd  # fully non-interactive, no daemon offer
#

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration — install.sh sits at the repo root, so SCRIPT_DIR IS the root
# (unlike scripts/install-conductor.sh, no PROJECT_ROOT indirection needed).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CC_SOURCE="$SCRIPT_DIR/cccc/cccc"
CC_WEBUI_SOURCE="$SCRIPT_DIR/cccc/cc-webui.py"
LIMIT_WATCHER_SOURCE="$SCRIPT_DIR/cccc/limit-watcher.sh"
CLEANUP_SOURCE="$SCRIPT_DIR/scripts/claude-cleanup"
CLEANUP_PLIST_TEMPLATE="$SCRIPT_DIR/scripts/com.user.claude-cleanup.plist"
LINK_COMPAT_HELPER="$SCRIPT_DIR/scripts/link-cc-compat.sh"
IDLE_WATCHDOG_SOURCE="$SCRIPT_DIR/system/bin/claude-idle-watchdog"
IDLE_WATCHDOG_PLIST_TEMPLATE="$SCRIPT_DIR/system/launchd/com.user.claude-idle-watchdog.plist.template"

BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/claude-control"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
CLEANUP_LOG_DIR="$HOME/.local/log/claude-cleanup"

# --- Parse early flags ---
ASSUME_YES=false
SKIP_LAUNCHD=false
WITH_CC_SYMLINK=false

for arg in "$@"; do
    case "$arg" in
        --yes|-y)          ASSUME_YES=true ;;
        --skip-launchd)    SKIP_LAUNCHD=true ;;
        --with-cc-symlink) WITH_CC_SYMLINK=true ;;
        --help|-h)
            echo "Usage: install.sh [--yes] [--skip-launchd] [--with-cc-symlink]"
            echo ""
            echo "  --yes, -y           Non-interactive: accept defaults, no prompts"
            echo "  --skip-launchd      Never offer the optional claude-cleanup launchd schedule"
            echo "  --with-cc-symlink   Also create a ~/.local/bin/cc -> cccc symlink."
            echo "                      OFF by default because 'cc' is the system C compiler;"
            echo "                      only enable it if you want the short 'cc' alias and"
            echo "                      accept that it shadows the compiler on your PATH."
            echo ""
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown argument: $arg${NC}" >&2
            exit 1
            ;;
    esac
done

# --- Atomic install helper (finding: never cp onto a live inode) ---
# Copies SRC to a temp file in DEST's directory, marks it executable, then
# atomically renames it into place. A running cccc or an in-flight cleanup
# reading the old file therefore never sees a half-written binary.
atomic_install() {
    local src="$1" dest="$2"
    local tmp
    tmp="$(mktemp "${dest}.XXXXXX")"
    cp "$src" "$tmp"
    chmod +x "$tmp"
    mv -f "$tmp" "$dest"
}

echo -e "${CYAN}Claude Code Control Center (cccc) Installer${NC}"
echo ""

# --- Step 1: Check dependencies ---
# tmux and jq are hard requirements — cccc cannot function without them.
# python3 is optional — only needed for 'cccc webui'; warn, don't block.
if ! command -v tmux >/dev/null 2>&1; then
    echo -e "${RED}Error: tmux is required. Install it first, e.g. brew install tmux jq${NC}"
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo -e "${RED}Error: jq is required. Install it first, e.g. brew install tmux jq${NC}"
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠ python3 not found — 'cccc webui' will not work without it${NC}"
fi

# --- Step 2: Verify prerequisites ---
for f in "$CC_SOURCE" "$CC_WEBUI_SOURCE" "$LIMIT_WATCHER_SOURCE" "$CLEANUP_SOURCE"; do
    if [[ ! -f "$f" ]]; then
        echo -e "${RED}Error: Source file not found: $f${NC}"
        echo "Make sure you're running this from the Claude-Ecosystem project root."
        exit 1
    fi
done

# --- Step 3: Copy cccc + cc-webui.py + limit-watcher.sh to ~/.local/bin ---
echo -e "${CYAN}Installing cccc to ${BIN_DIR}...${NC}"
mkdir -p "$BIN_DIR"
atomic_install "$CC_SOURCE" "$BIN_DIR/cccc"
atomic_install "$CC_WEBUI_SOURCE" "$BIN_DIR/cc-webui.py"
# limit-watcher.sh MUST live beside cccc: the installed cccc spawns rate-limit
# auto-resume watchers as `bash "$CC_SCRIPT_DIR/limit-watcher.sh"` from
# ~/.local/bin, and LIMIT_WATCHER=auto (the default) fires on every session
# creation. Without this copy the watcher dies "file not found" and the
# advertised auto-resume is silently broken for every installer user.
atomic_install "$LIMIT_WATCHER_SOURCE" "$BIN_DIR/limit-watcher.sh"

# --- Step 3b: Optionally ensure the cc -> cccc compatibility symlink ---
# OPT-IN ONLY. `cc` is the system C compiler (make's default CC=cc, autoconf
# `configure` scripts). With ~/.local/bin at the front of PATH, a cc -> cccc
# symlink hijacks the compiler and breaks native builds. So we create it only
# when the user explicitly asks (--with-cc-symlink), or when a PRIOR
# cccc-managed cc symlink already exists (an upgrade — keep it working, and let
# link-cc-compat.sh re-point it safely). Otherwise we skip it and print a
# one-line notice. The command name is `cccc`.
cc_link="$BIN_DIR/cc"
prior_cccc_cc=false
if [[ -L "$cc_link" && "$(readlink "$cc_link" 2>/dev/null)" == "$BIN_DIR/cccc" ]]; then
    prior_cccc_cc=true
fi

if [[ "$WITH_CC_SYMLINK" == true || "$prior_cccc_cc" == true ]]; then
    # Guarded explicitly (rather than relying on set -e) because the helper's
    # normal exit-0 states must never abort the rest of this installer, while a
    # genuine helper failure should still be surfaced to the operator.
    echo -e "${CYAN}Ensuring ${BIN_DIR}/cc -> ${BIN_DIR}/cccc compatibility symlink...${NC}"
    if [[ -x "$LINK_COMPAT_HELPER" ]]; then
        if ! "$LINK_COMPAT_HELPER" "$BIN_DIR"; then
            echo -e "${YELLOW}⚠ link-cc-compat.sh reported a failure — the 'cc' symlink may not be in place.${NC}"
            echo "  You can re-run it manually with: $LINK_COMPAT_HELPER \"$BIN_DIR\""
        fi
    else
        echo -e "${YELLOW}⚠ ${LINK_COMPAT_HELPER} not found or not executable — skipping 'cc' symlink.${NC}"
    fi
else
    echo -e "${CYAN}Skipping the optional 'cc' symlink — the command name is 'cccc'.${NC}"
    echo "  ('cc' is the system C compiler; pass --with-cc-symlink to create a cc -> cccc alias anyway.)"
fi

# --- Step 4: Vendor claude-cleanup to ~/.local/bin ---
echo -e "${CYAN}Installing claude-cleanup to ${BIN_DIR}...${NC}"
atomic_install "$CLEANUP_SOURCE" "$BIN_DIR/claude-cleanup"

# --- Step 5: Create the shared project registry dir + example config ---
echo -e "${CYAN}Creating ${CONFIG_DIR}...${NC}"
mkdir -p "$CONFIG_DIR"

# Write an example projects.conf only if one does not already exist — never
# clobber a real config (idempotent, per T-12-06).
if [[ -f "$CONFIG_DIR/projects.conf" ]]; then
    echo -e "${CYAN}projects.conf already exists — leaving it untouched.${NC}"
else
    cat > "$CONFIG_DIR/projects.conf" <<'EOF'
# cccc shared project registry.
# Format: project-name|/absolute/path/to/project
# One project per line. Lines starting with # are comments.
#
# Example (uncomment and edit, or add your own with `cccc add <name> <path>`):
#myproject|/Users/you/Development/myproject
EOF
    echo -e "${GREEN}✓ Wrote example projects.conf to ${CONFIG_DIR}/projects.conf${NC}"
fi

# Write an example settings.conf only if one does not already exist — never
# clobber a real config (idempotent, per T-12-06). Every key below is one of
# the exact 10 keys cccc's load_settings() parser reads (PERMISSION_MODE,
# PERMISSION_MODE_FALLBACK, MODEL, MEMORY_LIMIT_MB, CLAUDE_BIN, EXTRA_FLAGS,
# LIMIT_WATCHER, AUTO_TRUST, SHOW_LOGO, IDLE_WATCHDOG); do not add others.
if [[ -f "$CONFIG_DIR/settings.conf" ]]; then
    echo -e "${CYAN}settings.conf already exists — leaving it untouched.${NC}"
else
    cat > "$CONFIG_DIR/settings.conf" <<'EOF'
# cccc settings — all keys optional, defaults shown below (commented out).
# Uncomment and edit a line to override the default.

# PERMISSION_MODE: default|acceptEdits|plan|auto|bypassPermissions
#PERMISSION_MODE=auto

# PERMISSION_MODE_FALLBACK: default|acceptEdits|plan|bypassPermissions
# The mode PERMISSION_MODE=auto degrades to when auto isn't actually
# available (unsupported model, or a backend session). NOT auto itself.
# Safest public default is 'default' (still prompts). Set to
# bypassPermissions only if you want unattended fallback (e.g. for your
# own backend sessions).
#PERMISSION_MODE_FALLBACK=default

# MODEL: Claude model name, e.g. sonnet. Empty = Claude's own default.
#MODEL=

# MEMORY_LIMIT_MB: NODE_OPTIONS --max-old-space-size cap. 0 disables the cap.
#MEMORY_LIMIT_MB=6144

# CLAUDE_BIN: path or name of the claude binary to invoke.
#CLAUDE_BIN=claude

# EXTRA_FLAGS: extra flags appended to every claude invocation.
#EXTRA_FLAGS=

# LIMIT_WATCHER: auto|manual|off
#LIMIT_WATCHER=auto

# AUTO_TRUST: on-add|always|off
#AUTO_TRUST=on-add

# SHOW_LOGO: true|false — show the cccc banner/logo on the dashboard.
#SHOW_LOGO=true

# IDLE_WATCHDOG: on|off — reclaim RAM from idle sessions via the opt-in
# claude-idle-watchdog daemon (must be vendored + loaded separately).
#IDLE_WATCHDOG=off
EOF
    echo -e "${GREEN}✓ Wrote example settings.conf to ${CONFIG_DIR}/settings.conf${NC}"
fi

echo ""
echo -e "${GREEN}✓ Core installation complete!${NC}"
echo -e "  cccc:            ${CYAN}${BIN_DIR}/cccc${NC}"
echo -e "  cc-webui.py:     ${CYAN}${BIN_DIR}/cc-webui.py${NC}"
echo -e "  limit-watcher.sh: ${CYAN}${BIN_DIR}/limit-watcher.sh${NC}"
echo -e "  claude-cleanup:  ${CYAN}${BIN_DIR}/claude-cleanup${NC}"
echo -e "  config dir:     ${CYAN}${CONFIG_DIR}${NC}"
echo ""

# --- Optional: macOS-only launchd schedule offer for claude-cleanup ---
if [[ "$(uname)" == "Darwin" ]]; then
    if [[ "$SKIP_LAUNCHD" == true ]]; then
        : # explicitly skipped — no prompt, no migration note
    elif [[ "$ASSUME_YES" == true ]]; then
        : # non-interactive without an explicit opt-in — do not install a daemon
          # unattended; the maintainer can re-run interactively to opt in.
    elif [[ ! -t 0 ]]; then
        : # stdin is not a TTY (piped: ./install.sh </dev/null, curl | bash).
          # Treat as the safe default — skip the optional daemon rather than
          # running `read` on a non-interactive stdin (which under set -e would
          # hit EOF and abort the whole installer). Re-run interactively, or
          # pass --yes, to opt in.
    else
        # Migration note — printed BEFORE the prompt, at the moment of the
        # decision, not buried later in a summary doc (per CLEANUP-02).
        echo -e "${YELLOW}Note on claude-cleanup and the existing com.user.claude-orphan-cleanup daemon:${NC}"
        echo "  Copying scripts/claude-cleanup to ${BIN_DIR}/claude-cleanup ALSO fixes any"
        echo "  pre-existing 'com.user.claude-orphan-cleanup' launchd daemon in place — it"
        echo "  invokes this exact binary path, now with the empty-array bug fixed. That"
        echo "  means the binary overwrite above already un-breaks an existing daemon on"
        echo "  its own, with no new plist required."
        echo ""
        echo "  You have two options:"
        echo "    (a) DECLINE this offer below — the binary overwrite alone already"
        echo "        un-breaks the existing daemon, so no new plist is needed."
        echo "    (b) If you specifically want the new, distinctly-labeled"
        echo "        'com.user.claude-cleanup' daemon instead, FIRST retire the old one:"
        echo "          launchctl bootout gui/\$(id -u)/com.user.claude-orphan-cleanup"
        echo "        Installing this offer's daemon WITHOUT retiring the old one first"
        echo "        would leave two separately-labeled daemons on the same 04:00/12:00"
        echo "        schedule pointed at the same binary — the exact double-daemon"
        echo "        condition this cleanup phase aims to eliminate."
        echo ""

        read -e -r -p "Install optional launchd schedule for claude-cleanup (twice daily)? [y/N] " _cleanup_launchd
        if [[ "$_cleanup_launchd" =~ ^[Yy]$ ]]; then
            mkdir -p "$LAUNCH_AGENTS_DIR"
            mkdir -p "$CLEANUP_LOG_DIR"
            DEST_PLIST="$LAUNCH_AGENTS_DIR/com.user.claude-cleanup.plist"
            sed -e "s|__CLAUDE_CLEANUP_BIN__|${BIN_DIR}/claude-cleanup|g" \
                -e "s|__CLAUDE_CLEANUP_LOG__|${CLEANUP_LOG_DIR}/latest.log|g" \
                "$CLEANUP_PLIST_TEMPLATE" > "$DEST_PLIST"

            if launchctl bootstrap "gui/$(id -u)" "$DEST_PLIST" 2>/dev/null; then
                echo -e "${GREEN}✓ launchd schedule installed and loaded (com.user.claude-cleanup)${NC}"
            elif launchctl load "$DEST_PLIST" 2>/dev/null; then
                echo -e "${GREEN}✓ launchd schedule installed and loaded via 'launchctl load' fallback${NC}"
            else
                echo -e "${YELLOW}⚠ Wrote ${DEST_PLIST} but could not load it automatically.${NC}"
                echo "  Load it manually with: launchctl bootstrap gui/\$(id -u) \"$DEST_PLIST\""
            fi
        else
            echo -e "${CYAN}Skipping launchd schedule install.${NC}"
        fi
    fi

    # --- Optional: vendor the opt-in claude-idle-watchdog daemon ---
    # Reclaims RAM from idle/detached sessions; default OFF via cccc's
    # IDLE_WATCHDOG setting even once installed — see docs/IDLE_WATCHDOG.md.
    # Deliberately never auto-loaded here: vendoring the script/plist to disk
    # is not the same as bootstrapping it, so this offer only writes the
    # files and prints the manual launchctl step, leaving the human in
    # control of when the daemon actually starts running.
    if [[ "$SKIP_LAUNCHD" == true ]]; then
        : # explicitly skipped — no prompt
    elif [[ "$ASSUME_YES" == true ]]; then
        : # non-interactive without an explicit opt-in — do not vendor unattended
    elif [[ ! -f "$IDLE_WATCHDOG_SOURCE" || ! -f "$IDLE_WATCHDOG_PLIST_TEMPLATE" ]]; then
        : # source files not present in this checkout — nothing to offer
    elif [[ ! -t 0 ]]; then
        : # stdin is not a TTY — skip rather than `read` on non-interactive
          # stdin (EOF under set -e would abort the installer).
    else
        echo ""
        echo -e "${YELLOW}Optional: claude-idle-watchdog (RAM-reclaim daemon, opt-in, default OFF):${NC}"
        echo "  Reclaims RAM from idle/detached cccc sessions via SIGTERM (never"
        echo "  kill-session — the tmux pane survives, resume with"
        echo "  'claude --resume <session-id>'). Full details: docs/IDLE_WATCHDOG.md"
        echo ""
        echo "  This step only vendors the script + launchd job to disk — it does NOT"
        echo "  load or start the daemon, and the daemon itself stays a no-op until you"
        echo "  set IDLE_WATCHDOG=on via 'cccc config' or 'cccc settings' (default: off)."
        echo ""

        read -e -r -p "Vendor claude-idle-watchdog to disk (not started)? [y/N] " _idle_watchdog_vendor
        if [[ "$_idle_watchdog_vendor" =~ ^[Yy]$ ]]; then
            cp "$IDLE_WATCHDOG_SOURCE" "$BIN_DIR/claude-idle-watchdog"
            chmod +x "$BIN_DIR/claude-idle-watchdog"

            mkdir -p "$LAUNCH_AGENTS_DIR"
            mkdir -p "$HOME/.local/log"
            DEST_PLIST="$LAUNCH_AGENTS_DIR/com.user.claude-idle-watchdog.plist"
            sed "s|__HOME__|${HOME}|g" "$IDLE_WATCHDOG_PLIST_TEMPLATE" > "$DEST_PLIST"

            echo -e "${GREEN}✓ Vendored ${BIN_DIR}/claude-idle-watchdog${NC}"
            echo -e "${GREEN}✓ Wrote ${DEST_PLIST}${NC}"
            echo ""
            echo "  To actually start the daemon:"
            echo "    launchctl bootstrap gui/\$(id -u) \"$DEST_PLIST\""
            echo "  Then opt in via cccc: set IDLE_WATCHDOG=on (default is off)."
        else
            echo -e "${CYAN}Skipping claude-idle-watchdog.${NC}"
        fi
    fi
else
    echo "Daemon setup (launchd) is macOS-only — skipping on $(uname)."
fi

echo ""
echo -e "${GREEN}Done.${NC}"
