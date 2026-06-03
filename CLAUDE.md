# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

One-off Fedora workstation setup scripts. Each script is independent, idempotent, and follows the user-manual-install-* / RUNTOOLS_AS_NONINTERACTIVE conventions documented in `~/.claude/CLAUDE.md`.

Current scripts:

- `user-manual-install-nvidia-driver.sh` — proprietary NVIDIA driver via RPM Fusion + akmod-nvidia; fixes DisplayPort retrain-after-suspend on Blackwell GPUs (RTX 5070 Ti / GB203). Auto-sudo, --dry-run / --no-prompt.
- `user-manual-install-vscode.sh` — Visual Studio Code via Microsoft's RPM repo. Auto-sudo, --dry-run / --no-prompt.
- `user-manual-install-modern-cli-tools.sh` — modern CLI replacements (eza/bat/fd-find/zoxide/git-delta/direnv/fzf/ripgrep/nvtop) + zsh via dnf. Idempotent per-package via `rpm -q`. Auto-sudo, --dry-run / --no-prompt.
- `user-manual-install-starship.sh` — starship cross-shell prompt to `~/.local/bin/` via the official installer. No sudo. --dry-run / --no-prompt.
- `user-manual-install-zsh-plugins.sh` — clone zsh-autosuggestions / zsh-syntax-highlighting / zsh-completions into `~/.config/zsh/plugins/`. No sudo. --dry-run / --no-prompt.
- `user-manual-install-quick-access-terminal-shortcut.sh` — bind `Meta+Return` to `kitten quick-access-terminal` via a `NoDisplay` `.desktop` file plus a `[services][...desktop] _launch=Meta+Return` entry in `kglobalshortcutsrc`. Best-effort `kded6` reload at the end; logout fallback if the chord does not activate. No sudo. `--dry-run` / `--no-prompt`.
- `user-manual-configure-shell-to-zsh.sh` — symlink `~/.zshrc` → dotfiles repo, add `shell /bin/zsh` to kitty `system.conf` (works around the `$SHELL`-frozen-after-chsh gotcha), and `chsh -s /bin/zsh`. No auto-sudo. --dry-run / --no-prompt (chsh step skipped in --no-prompt because PAM needs an interactive password). Takes `--dotfiles-dir <path>` to override the default (`~/projects/repos/dotfiles`).
- `user-manual-deploy-dotfiles.sh` — walk the dotfiles repo and symlink every regular file (excluding `.git/`, `.gitignore`, `README.md`, `CLAUDE.md`, and `settings.local.json` — the last is machine-specific, carrying the per-machine `env`/`CLAUDE_SETUP_DIR`) into the matching path under `~/`. No sudo. --dry-run / --no-prompt / --dotfiles-dir. Idempotent (per-file skip-if-correct / prompt-and-backup / warn-and-skip).
- `user-manual-reload-dotfiles.sh` — the `reload` half of the deploy pair: `git fetch`es the dotfiles repo, reports divergence (incoming/local-only commits, dirty tree), then reconciles. Interactive offers the 3-way (replace-local / keep-local / commit-and-push-first per `~/.claude/CLAUDE.md`); `--no-prompt` does "pull only if clean" — fast-forwards when clean+not-ahead, else aborts untouched (exit 2) so unattended runs never lose local work. Re-runs `deploy-dotfiles` afterward to link any newly-added files (`--skip-deploy` opts out). No sudo. --dry-run / --no-prompt / --dotfiles-dir. This is the "keep two peer machines in sync" tool.
- `user-manual-install-tailscale.sh` — install Tailscale via its official Fedora RPM repo, enable `tailscaled`, and enroll on the tailnet. Backend-state-aware: `Running` → skip, `Stopped` → `tailscale up` (no key), `NeedsLogin` → browser login (interactive) or `TS_AUTHKEY` env var (`--no-prompt`, fails clearly if unset; key never logged). `--ssh` also enables Tailscale SSH. Auto-sudo (`sudo -E` preserves `TS_AUTHKEY`). --dry-run / --no-prompt. This is the "remote access between machines" tool.

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
