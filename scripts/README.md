# Scripts Directory

Utility scripts for the Claude Ecosystem project.

## Structure

```
scripts/
├── claude-cleanup                  # Vendored orphan-process reaper
├── com.user.claude-cleanup.plist   # launchd template for claude-cleanup
└── link-cc-compat.sh               # Transitional `cc` -> `cccc` compat symlink
```

## User Scripts

### claude-cleanup

**Purpose:** Enhanced orphan-process cleanup with process-tree detection. Finds
orphaned Claude processes (`PPID=1`, daemon TTY — `??` on macOS, `?` on Linux)
and their entire process trees (node, bun, python children), plus orphaned
children whose Claude parent already died. Orphaned children are only reaped
when their argv actually proves Claude provenance (references `~/.claude/`,
`@anthropic`, `anthropic-ai`, or a `claude` wrapper) — a bare unrelated
node/python/bun daemon is never killed just because no `claude` shares its
process group. Vendored into the repo.

**Usage:**
```bash
scripts/claude-cleanup              # Normal cleanup
scripts/claude-cleanup --dry-run    # Show what would be killed
scripts/claude-cleanup --force      # Skip 24h age check
scripts/claude-cleanup --verbose    # Detailed output
scripts/claude-cleanup --quiet      # No output (for cc integration)
```

### com.user.claude-cleanup.plist

**Purpose:** launchd template for scheduling `claude-cleanup` twice daily
(04:00 + 12:00). `install.sh` substitutes the `__CLAUDE_CLEANUP_BIN__` and
`__CLAUDE_CLEANUP_LOG__` placeholders with real absolute paths at generation
time — do not hardcode a personal path in this repo-shipped template. The
label (`com.user.claude-cleanup`) is deliberately distinct from any
pre-existing local production daemon to avoid silently colliding with it.

### link-cc-compat.sh

**Purpose:** Idempotent, defensive helper that creates a `~/.local/bin/cc`
symlink pointing at `~/.local/bin/cccc`, so a short `cc <subcommand>` alias
works. **OPT-IN only** — `cc` is the system C compiler (`make`'s default
`CC=cc`, autoconf `configure` scripts), so `install.sh` no longer creates this
symlink by default. It is created only when you pass `install.sh
--with-cc-symlink`, or when a prior cccc-managed `cc` symlink already exists
(upgrade path). The helper **refuses** to touch a `cc` that it did not create:
a `cc` regular file (the compiler) or a symlink pointing elsewhere is left
untouched with a warning — it is never backed up, retargeted, or clobbered.
Only the "no `cc` exists yet" case results in a new symlink. Also safe to
re-run directly.

**Usage:**
```bash
scripts/link-cc-compat.sh [BIN_DIR]   # BIN_DIR defaults to ~/.local/bin
```

## Development

When adding new scripts:

1. **User-facing scripts:** Place in `scripts/` root
2. **Test/debug scripts:** Place alongside the script they test, named `test-<script>.sh`
3. **Make executable:** `chmod +x script-name.sh`
4. **Document in this README**

## Related Documentation

- [cc Reference](../docs/CC_REFERENCE.md) - cc command reference
- [Changelog](../CHANGELOG.md) - Version history
- [Setup Guide](../docs/SETUP.md) - Installation instructions
