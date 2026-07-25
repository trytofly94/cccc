#!/bin/bash
#
# link-cc-compat.sh — Idempotent, defensive transitional symlink helper.
#
# Ensures ~/.local/bin/cc is a symlink pointing at ~/.local/bin/cccc, so every
# existing `cc <subcommand>` invocation (most critically any remote client's
# SSH-driven `cc json` calls) keeps working unchanged after the cc -> cccc
# rename.
#
# Mirrors the check-before-mutate / backup-before-destroy / idempotent-no-op
# discipline of trust_path_defensively() (cccc/cccc, formerly cc/cc:369-407)
# but — unlike that always-return-0 hot-path helper — this one runs in an
# installer context and MAY exit non-zero on a genuine failure (a failed
# ln when creating a brand-new symlink); installers are allowed to fail
# loudly. It must NEVER displace a pre-existing `cc` (regular file OR a
# symlink pointing elsewhere) — `cc` is the system C compiler, so anything
# already sitting there is left untouched with a warning.
#
# Four-state contract (revised — `cc` is the system C compiler, so this helper
# must NEVER silently steal an existing `cc` it did not itself create):
#   1. cc does not exist at all (no file, no symlink)      -> create
#   2. cc is a symlink already pointing at BIN_DIR/cccc     -> no-op ("already correct")
#   3. cc is a symlink pointing somewhere else              -> REFUSE, warn (never retarget)
#   4. cc exists as a REGULAR FILE (e.g. the C compiler)    -> REFUSE, warn (never clobber)
#
# The symlink always chains through "$BIN_DIR/cccc" (the installed binary),
# never directly at this repo's absolute path — so it stays correct across
# future cccc-targeted updates without re-resolving the repo location.
#
# Usage:
#   scripts/link-cc-compat.sh [BIN_DIR]     # BIN_DIR defaults to ~/.local/bin
#
# Called by install.sh after the cccc binary is installed. Also directly
# runnable standalone for a one-off live retarget (see plan 11-05).

set -u

BIN_DIR="${1:-$HOME/.local/bin}"
cc_link="$BIN_DIR/cc"
cccc_target="$BIN_DIR/cccc"

if [[ ! -e "$cccc_target" && ! -L "$cccc_target" ]]; then
    echo "warning: $cccc_target does not exist yet — the transitional symlink will not be usable until cccc is installed" >&2
fi

# State 1: cc does not exist at all (neither a file nor a symlink).
if [[ ! -e "$cc_link" && ! -L "$cc_link" ]]; then
    ln -s "$cccc_target" "$cc_link" || { echo "error: failed to create symlink $cc_link -> $cccc_target" >&2; exit 1; }
    echo "created: $cc_link -> $cccc_target"
    exit 0
fi

# State 2: cc is already the cccc symlink — nothing to do.
# State 3: cc is a symlink pointing somewhere else — REFUSE. It may be a
# user-managed alias (e.g. cc -> clang, cc -> ccache); retargeting it would
# hijack whatever they pointed it at. Warn and leave it untouched.
if [[ -L "$cc_link" ]]; then
    current_target="$(readlink "$cc_link")"
    if [[ "$current_target" == "$cccc_target" ]]; then
        echo "already correct: $cc_link -> $cccc_target"
        exit 0
    fi
    echo "warning: $cc_link is a symlink to '$current_target', not to $cccc_target — refusing to retarget it." >&2
    echo "  If you really want the cccc alias here, remove '$cc_link' yourself and re-run." >&2
    exit 0
fi

# State 4: cc exists as a REGULAR FILE — most likely the system C compiler (or
# a user's own script). REFUSE to touch it. This helper only ever creates a
# brand-new cc symlink (State 1); it must never displace an existing cc binary.
echo "warning: $cc_link already exists as a regular file — refusing to replace it (it may be the C compiler)." >&2
echo "  cccc is invoked as 'cccc'. If you deliberately want a cc -> cccc alias, remove '$cc_link' yourself and re-run." >&2
exit 0
