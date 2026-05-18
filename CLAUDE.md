# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

One-off Fedora workstation setup scripts. Each script is independent, idempotent, and follows the user-manual-install-* / RUNTOOLS_AS_NONINTERACTIVE conventions documented in `~/.claude/CLAUDE.md`.

Current scripts:

- `user-manual-install-nvidia-driver.sh` — proprietary NVIDIA driver via RPM Fusion + akmod-nvidia; fixes DisplayPort retrain-after-suspend on Blackwell GPUs (RTX 5070 Ti / GB203). Auto-sudo, --dry-run / --no-prompt.
- `user-manual-install-vscode.sh` — Visual Studio Code via Microsoft's RPM repo. Auto-sudo, --dry-run / --no-prompt.

## Memory Location

Project memory is stored in the claude-setup repo, not in Claude Code's auto-generated project folder. At the start of each session, read memory from:

  `$CLAUDE_SETUP_DIR/memory/fedora-setup/MEMORY.md`

(and the files it references in that directory)

## Conventions for new scripts

Mirror the existing scripts:

- Filename: `user-manual-install-<package>.sh` (manually-run install scripts) or `user-manual-configure-<thing>.sh` (configuration tweaks).
- Top-of-file comment: problem this solves → what the script does → usage examples.
- Flag parsing: support `--dry-run`, `--no-prompt`, `--help` at minimum.
- Auto-sudo: re-exec under `sudo` if not already root, unless `--dry-run` (state checks work unprivileged).
- Non-TTY auto-detection: `[ -t 1 ] || export RUNTOOLS_AS_NONINTERACTIVE=1`.
- Each step idempotent: check current state before changing it; skip if state already matches.
- One-time confirmation gate before destructive changes (boot/initramfs/etc.), gated on `RUNTOOLS_AS_NONINTERACTIVE`.

## When to add a new script vs. extend an existing one

- New hardware/software install → new script (`user-manual-install-<thing>.sh`).
- Bug-fix or refinement to an existing install → modify the existing script.
- Cross-cutting configuration (shell, dotfiles, etc.) → consider whether it belongs in `claude-setup/` or in a future `dotfiles/` repo instead.
