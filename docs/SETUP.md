# Setup Guide

Complete installation guide for the Claude Code Control Center (cccc) v4.0.1.

## Prerequisites

### Required Software

```bash
# macOS
brew install tmux jq

# Verify installations
tmux -V           # tmux 3.x+
jq --version      # jq (required — trust logic + JSON handling)
claude --version  # Claude Code CLI must be installed
```

### Claude Code CLI

Install Claude Code if not already present:
```bash
npm install -g @anthropic-ai/claude-code
# or
curl -fsSL https://claude.ai/install.sh | sh
```

### Summary of Requirements

| Tool | Minimum Version | Purpose |
|------|----------------|---------|
| bash | 3.2+ | cccc script runtime (macOS stock bash 3.2 is supported) |
| tmux | 3.x+ | Session persistence |
| jq | any recent | Required — folder-trust logic and JSON handling |
| git | 2.25+ | Repository operations |
| claude | latest | Claude Code CLI (direct session runner) |
| python3 | 3.x | Optional — only for the `cccc settings` / `cccc webui` web editor |

No additional runtimes or middleware are needed. The cccc script calls `claude`
directly. `jq` is a hard requirement (`install.sh` refuses to proceed without it);
`python3` is optional and only enables the Settings Web UI.

## Installation

### Step 1: Clone the Repository

```bash
git clone https://github.com/trytofly94/cccc.git
cd cccc
```

### Step 2: Install cccc (recommended: `./install.sh`)

The supported install is the bundled installer. It checks dependencies (`tmux`
and `jq` are hard-required; `python3` is soft-warned), copies `cccc`,
`cc-webui.py`, `limit-watcher.sh`, and `claude-cleanup` into `~/.local/bin/`,
creates `~/.config/claude-control/` with a commented example `projects.conf` and
`settings.conf` (never overwriting existing ones), and — on macOS — optionally
offers to install the twice-daily `claude-cleanup` launchd schedule:

```bash
./install.sh
```

`install.sh` is idempotent, so re-run it any time (e.g. after `git pull`) to pick
up updates. The installed command is `cccc`. The short `cc` alias is **opt-in**:
run `./install.sh --with-cc-symlink` to also create a `~/.local/bin/cc → cccc`
symlink. It is off by default because `cc` is the system C compiler and the alias
would shadow it on your `PATH`.

Make sure `~/.local/bin` is on your `PATH` (add to `~/.zshrc` or `~/.bashrc`):

```bash
export PATH="$HOME/.local/bin:$PATH"
```

#### Manual install (alternative)

If you prefer not to run the installer, copy the two required scripts by hand:

```bash
# Create local bin directory if needed
mkdir -p ~/.local/bin

# Copy cccc to PATH
cp cccc/cccc ~/.local/bin/cccc
chmod +x ~/.local/bin/cccc

# Install the Settings Web UI alongside cccc (REQUIRED for `cccc settings` / `cccc webui`)
# cccc is installed as a single file, so cc-webui.py must sit next to it.
cp cccc/cc-webui.py ~/.local/bin/cc-webui.py
```

> **`cccc settings` install note:** `cccc` is installed to `~/.local/bin/cccc` as a
> single file. The Settings Web UI lives in a separate script (`cc-webui.py`) and
> **must be copied next to the installed binary** (`~/.local/bin/cc-webui.py`) for
> `cccc settings` (primary command, local-first + auto-open) or its `cccc webui`
> alias (LAN + no-auto-open) to work. If that sibling file is missing, both fall
> back to the repo checkout path, but copying it is the supported install.

### Step 3: Create the Project Registry

```bash
mkdir -p ~/.config/claude-control
touch ~/.config/claude-control/projects.conf
```

The registry file format is one project per line:

```
# Format: project-name|/absolute/path/to/project
frontend|/Users/you/projects/frontend
backend|/Users/you/projects/backend-api
scripts|/Users/you/scripts
```

### Step 4: Add a Project

```bash
echo "myproject|/path/to/project" >> ~/.config/claude-control/projects.conf
```

### Step 5: Test the Installation

```bash
cccc
```

You should see the interactive dashboard with your project listed. Press `q` to quit.

## Verification

### Create a Session

1. Run `cccc`
2. Press the letter shown next to your project (e.g., `a` for the first project)
3. A tmux session named `cc-<project>-<name>` starts and launches Claude Code directly
4. In the Claude session, run `/status` or type `pwd` to confirm the working directory is correct

```bash
# Verify tmux session was created
tmux list-sessions | grep cc-
```

### Confirm cccc is Working

```bash
# List registered projects
cccc list

# Check cccc finds your projects
cccc
# Dashboard should list your project(s) by letter
```

## Troubleshooting

### "cccc not found"

Ensure `~/.local/bin` is in your PATH:

```bash
echo $PATH | grep -o "$HOME/.local/bin"
# If empty, add to ~/.zshrc or ~/.bashrc:
export PATH="$HOME/.local/bin:$PATH"
source ~/.zshrc
```

### Session Starts in Wrong Directory

The tmux session is created with `tmux new-session -c "<path>"`, so the directory should be correct automatically. If it is wrong:

```bash
# Check what path cccc is using
grep "myproject" ~/.config/claude-control/projects.conf

# Verify the path exists
ls -la /path/to/project

# Check the cccc script's tmux call
grep "new-session" ~/.local/bin/cccc
```

### Claude Not Found in Session

Ensure `claude` is in your PATH and accessible from a non-interactive shell:

```bash
which claude
# Ensure this returns a valid path
# Add to ~/.zshrc if needed: export PATH="$PATH:/path/to/claude"
```

### Session Already Exists Error

If a session with the same name already exists:

```bash
# List existing sessions
tmux list-sessions

# Kill a stale session (or use `cccc kill <session-name>`)
tmux kill-session -t cc-myproject-mysession
```

## Quick Reference

| Component | Location | Notes |
|-----------|----------|-------|
| cccc script | `~/.local/bin/cccc` | Run with `cccc` |
| Projects config | `~/.config/claude-control/projects.conf` | One project per line |
| tmux sessions | named `cc-<project>-<name>` | `tmux list-sessions` |

## Next Steps

- Read [CC_REFERENCE.md](CC_REFERENCE.md) for full cccc command documentation
- Read [UPDATE_GUIDE.md](UPDATE_GUIDE.md) for update and migration procedures
