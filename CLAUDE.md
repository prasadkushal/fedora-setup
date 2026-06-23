# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

One-off Fedora workstation setup scripts. Each script is independent, idempotent, and follows the folder + RUNTOOLS_AS_NONINTERACTIVE conventions documented in `~/.claude/CLAUDE.md`: scripts are grouped into `install/`, `configure/`, and `dotfiles/` folders (the path conveys the role, so no filename prefix), while the cross-category orchestrators (`setup-all.sh`, `bootstrap-fedora.sh`) live at the repo root. This repo is uniformly user-run, so it has no `user-manual/` direction folder.

Reusable scripts live in the repository root (and its category folders).
Workstation-specific scripts, templates, and notes live under
`workstations/<hostname>/` so host-only setup does not leak into the shared
parent script set.

Current scripts:

- `setup-all.sh` — **top-level orchestrator / single entry point.** Always runs the two core orchestrators (`bootstrap-fedora` then `install-apps`); gates the optionals (vscode, tailscale, KDE quick-access) with per-item prompts defaulting to No; runs the NVIDIA driver only with explicit `--with-nvidia` (never automatic — hardware-specific). `--no-prompt` → core only, optionals skipped. Runs as the user (children self-elevate; refuses root). --dry-run / --no-prompt / --with-nvidia / --dotfiles-dir=<path>. Idempotent (delegates to idempotent children).
- `bootstrap-fedora.sh` — orchestrator. Runs the five user-level setup scripts in order (`modern-cli-tools` → `starship` → `zsh-plugins` → `deploy-dotfiles` → `configure-shell-to-zsh`); NVIDIA driver intentionally excluded (workstation-specific). Gates each step, aborts on child failure, passes through --dry-run / --no-prompt / --dotfiles-dir. Runs as the user (each child self-elevates); refuses to run as root. The one-shot fresh-machine path — see USAGI.md.
- `install/nvidia-driver.sh` — proprietary NVIDIA driver via RPM Fusion + akmod-nvidia; fixes DisplayPort retrain-after-suspend on Blackwell GPUs (RTX 5070 Ti / GB203). Auto-sudo, --dry-run / --no-prompt.
- `install/vscode.sh` — Visual Studio Code via Microsoft's RPM repo. Auto-sudo, --dry-run / --no-prompt.
- `install/modern-cli-tools.sh` — modern CLI replacements (eza/bat/fd-find/zoxide/git-delta/direnv/fzf/ripgrep/nvtop) + zsh + the kitty terminal via dnf. kitty is included because the shell setup is kitty-centric (configure-shell pins its `shell`; quick-access needs `kitten`; dotfiles ship kitty config). Idempotent per-package via `rpm -q`. Auto-sudo, --dry-run / --no-prompt.
- `install/starship.sh` — starship cross-shell prompt to `~/.local/bin/` via the official installer. No sudo. --dry-run / --no-prompt.
- `install/zsh-plugins.sh` — clone zsh-autosuggestions / zsh-syntax-highlighting / zsh-completions / fzf-tab (the last from Aloxaf, not zsh-users) into `~/.config/zsh/plugins/`. No sudo. --dry-run / --no-prompt.
- `install/quick-access-terminal-shortcut.sh` — bind `Meta+Return` to `kitten quick-access-terminal` via a `NoDisplay` `.desktop` file plus a `[services][...desktop] _launch=Meta+Return` entry in `kglobalshortcutsrc`. Best-effort `kded6` reload at the end; logout fallback if the chord does not activate. No sudo. `--dry-run` / `--no-prompt`.
- `configure/default-terminal.sh` — make kitty the default terminal under KDE Plasma. Three writes: (1) `[services][kitty.desktop] _launch=Ctrl+Alt+T` in `kglobalshortcutsrc` (claim the chord); (2) `[services][org.kde.konsole.desktop] _launch=none` (release Konsole's package-default `X-KDE-Shortcuts=Ctrl+Alt+T`, else the two collide — only touched when Konsole is at default or explicitly on Ctrl+Alt+T); (3) `[General] TerminalApplication=kitty` + `TerminalService=kitty.desktop` in `kdeglobals` (the two keys KF6's `KTerminalLauncherJob` reads, used by Dolphin "Open Terminal", file-manager service menus, etc.). Each write is state-checked + idempotent; collisions prompt interactively, `--no-prompt` overwrites. Best-effort `plasma-kded6.service`/`kded6` reload (only the shortcut needs it; the `kdeglobals` keys are read live); logout fallback. No sudo. `--dry-run` / `--no-prompt`. Sibling to the quick-access script but a distinct concern (default terminal vs the drop-down quake terminal).
- `configure/shell-to-zsh.sh` — symlink `~/.zshenv` + `~/.zshrc` → dotfiles repo (`.zshenv` holds PATH/env so it applies to all shells, not just interactive), add `shell /bin/zsh` to kitty `system.conf` (works around the `$SHELL`-frozen-after-chsh gotcha), and `chsh -s /bin/zsh`. No auto-sudo. --dry-run / --no-prompt (chsh step skipped in --no-prompt because PAM needs an interactive password). Takes `--dotfiles-dir <path>` to override the default (`~/projects/dotfiles`).
- `dotfiles/deploy.sh` — walk the dotfiles repo and symlink every regular file (excluding `.git/`, `.gitignore`, `README.md`, `CLAUDE.md`, and `settings.local.json` — the last is machine-specific, carrying the per-machine `env`/`CLAUDE_SETUP_DIR`) into the matching path under `~/`. No sudo. --dry-run / --no-prompt / --dotfiles-dir. Idempotent (per-file skip-if-correct / prompt-and-backup / warn-and-skip).
- `dotfiles/reload.sh` — the `reload` half of the deploy pair: `git fetch`es the dotfiles repo, reports divergence (incoming/local-only commits, dirty tree), then reconciles. Interactive offers the 3-way (replace-local / keep-local / commit-and-push-first per `~/.claude/CLAUDE.md`); `--no-prompt` does "pull only if clean" — fast-forwards when clean+not-ahead, else aborts untouched (exit 2) so unattended runs never lose local work. Re-runs `deploy-dotfiles` afterward to link any newly-added files (`--skip-deploy` opts out). No sudo. --dry-run / --no-prompt / --dotfiles-dir. This is the "keep two peer machines in sync" tool.
- `configure/ssh-server.sh` — enable + start `sshd` and ensure the firewalld `ssh` service (`docs/specs/2026-06-07-fedora-remote-access-layout.md`). sshd_config stays at Fedora defaults. Auto-sudo, --dry-run / --no-prompt.
- `configure/rdp-server.sh` — enable KDE's built-in RDP server (krdp, preinstalled with Plasma ≥6.1; shares the live Wayland session). Generates a self-signed TLS cert pair, writes `krdpserverrc` (`Autostart` + `SystemUserEnabled` — RDP login uses the Linux username/password, no stored secret), ensures the firewalld `rdp` service (inline sudo only if missing), enables the `app-org.kde.krdpserver.service` user unit. Runs as the user; refuses root. Only works while a desktop session is logged in. --dry-run / --no-prompt.
- `configure/xrdp-fallback.sh` — XRDP on `:3390` serving a *separate* XFCE session (vs krdp's live-session share on `:3389`), for remote GUI after a Wake-on-LAN/cold boot when no Plasma session exists yet (krdp would drop with `ERRINFO_LOGOFF_BY_USER`). Installs xrdp/xorgxrdp + minimal XFCE, creates a non-admin fallback user (default `<hostname>-rdp`) with a `~/.xsession`, moves xrdp to 3390 (backs up `xrdp.ini`), labels tcp/3390 `rdp_port_t` under SELinux. Auto-sudo; password set interactively. Firewall handled by the firewall script below. --dry-run / --no-prompt / --user= / --port=.
- `configure/remote-access-firewall.sh` — replace the broad firewalld `ssh`/`rdp` services with source-restricted rich rules (and open tcp/3390) limited to the oaknet `allowed_sources` (default Users VLAN `10.69.11.0/24` + Tailscale CGNAT `100.64.0.0/10`; override `--source=` / `REMOTE_ACCESS_SOURCES`). Adds restricted rules *before* removing the broad ones (no open window); one confirmation gate before narrowing. Auto-sudo. --dry-run / --no-prompt.
- `install/tailscale.sh` — install Tailscale via its official Fedora RPM repo, enable `tailscaled`, and enroll on the tailnet. Backend-state-aware: `Running` → skip, `Stopped` → `tailscale up` (no key), `NeedsLogin` → browser login (interactive) or `TS_AUTHKEY` env var (`--no-prompt`, fails clearly if unset; key never logged). `--ssh` also enables Tailscale SSH. Auto-sudo (`sudo -E` preserves `TS_AUTHKEY`). --dry-run / --no-prompt. This is the "remote access between machines" tool.
- `install/apps.sh` — orchestrator for the curated application set (`docs/specs/2026-06-03-reproduce-manual-apps-design.md`). Runs the eight app installers below in order (docker → chrome → mullvad → flatpaks → node/npm-globals → uv → claude → rmapi), gating each, passing through --dry-run / --no-prompt. Runs as the user; children self-elevate. NVIDIA excluded. Mirrors `bootstrap-fedora.sh`.
- `install/docker.sh` — Docker CE via Docker's official repo (engine/cli/buildx/compose/containerd), enables the service, adds the invoking user (`$SUDO_USER`) to the `docker` group (root-equivalent; re-login needed). Auto-sudo, --dry-run / --no-prompt.
- `install/chrome.sh` — Google Chrome (`google-chrome-stable`) via Google's signed repo (embedded `.repo` + key, vscode-style). Auto-sudo, --dry-run / --no-prompt.
- `install/mullvad.sh` — Mullvad VPN + browser via Mullvad's signed repo (curl-`.repo`, tailscale-style). Auto-sudo, --dry-run / --no-prompt.
- `install/flatpaks.sh` — ensure flatpak + Flathub remote, then install every app ID in `install/flatpak-apps.list` (Obsidian/GIMP/Zen/Firefox), skipping installed. System-wide default (auto-sudo); `--user` flips to per-user (no sudo). --dry-run / --no-prompt.
- `install/node-and-npm-globals.sh` — `dnf install nodejs npm` (guarded on the binaries, since Fedora ships npm via `nodejs-npm`), then `npm install -g` each entry in `install/npm-globals.list` (`@openai/codex`, `firebase-tools`). Auto-sudo (global prefix `/usr/local`). --dry-run / --no-prompt.
- `install/uv.sh` — Astral `uv` (+`uvx`) to `~/.local/bin` via the official installer (starship-style; refuses root). --dry-run / --no-prompt.
- `install/claude.sh` — Claude Code CLI via its official native installer to `~/.local/bin` (starship-style; refuses root; idempotent on `command -v claude`). --dry-run / --no-prompt.
- `install/rmapi.sh` — `rmapi` reMarkable CLI: downloads the latest `ddvk/rmapi` release (maintained fork; original `juruen/rmapi` stalled at v0.0.25) for the host arch to `~/.local/bin`. No sudo; refuses root; idempotent (re-download prompt). --dry-run / --no-prompt.
- `workstations/usagi/user-manual-finish-prime-ssh-workflow.sh` — usagi-only client workflow. Installs client SSH/RDP helpers, VS Code Remote SSH, Tailscale, and SSH aliases so usagi connects into the primary `prime` workspace. Does not enable an SSH server on usagi.

## Memory Location

Project memory is stored in the claude-setup repo, not in Claude Code's auto-generated project folder. At the start of each session, read memory from:

  `$CLAUDE_SETUP_DIR/memory/fedora-setup/MEMORY.md`

(and the files it references in that directory)

## Docs

Design specs live in `docs/specs/`, named `YYYY-MM-DD-<topic>-design.md` (date
prefix sorts chronologically and says what each doc is without opening it —
same philosophy as the folder-based script layout). Write a spec there before
implementing any multi-script feature; keep it updated as the source of truth
for that decision. Current specs:

- `docs/specs/2026-06-03-reproduce-manual-apps-design.md` — reproduce the
  workstation's manually-installed apps (Docker/Chrome/Mullvad, flatpaks, CLI
  tools) on peer machines.
- `docs/specs/2026-06-07-fedora-remote-access-layout.md` — canonical
  remote-access spec: incoming SSH + KDE RDP (:3389, live session) + XRDP
  fallback (:3390, separate session for post-WoL/pre-login); source-restricted
  firewall posture (Users VLAN + Tailscale CGNAT); system-user auth and
  per-user privilege model. Implemented on `prime`; SSH+krdp on `usagi`.

## Conventions for new scripts

Mirror the existing scripts:

- Location + name: install scripts go in `install/<package>.sh`, configuration tweaks in `configure/<thing>.sh`, dotfiles helpers in `dotfiles/<thing>.sh` — the folder conveys the role, so no filename prefix.
- Top-of-file comment: problem this solves → what the script does → usage examples.
- Flag parsing: support `--dry-run`, `--no-prompt`, `--help` at minimum.
- Auto-sudo: re-exec under `sudo` if not already root, unless `--dry-run` (state checks work unprivileged).
- Non-TTY auto-detection: `[ -t 1 ] || export RUNTOOLS_AS_NONINTERACTIVE=1`.
- Each step idempotent: check current state before changing it; skip if state already matches.
- One-time confirmation gate before destructive changes (boot/initramfs/etc.), gated on `RUNTOOLS_AS_NONINTERACTIVE`.

## When to add a new script vs. extend an existing one

- New hardware/software install → new script (`install/<thing>.sh`).
- Bug-fix or refinement to an existing install → modify the existing script.
- Cross-cutting configuration (shell, dotfiles, etc.) → consider whether it belongs in `claude-setup/` or in a future `dotfiles/` repo instead.
- Setup that only applies to one physical host/device → add it under `workstations/<hostname>/`, not in the root script list.
