# fedora-setup

One-off scripts and notes for setting up a Fedora workstation.

## Runbooks

- [`USAGI.md`](USAGI.md) — provision the Beelink SER6 mini-PC
  (`usagi`) with the same shell/CLI/Claude environment as the main
  workstation. Config reproduction (clone repos + run the bootstrap scripts),
  not a disk clone; the NVIDIA driver script is intentionally skipped because
  the SER6 has no NVIDIA GPU.
- [`workstations/`](workstations/) — host-specific scripts and notes. Keep
  reusable Fedora setup scripts in the repository root; put setup that only
  applies to one device under `workstations/<hostname>/`.

## Planned Oaknet Backup Enrollment

- [`docs/specs/2026-06-06-bitwarden-backup-secrets-design.md`](docs/specs/2026-06-06-bitwarden-backup-secrets-design.md)
  — future Fedora backup client runtime for fetching restic, rest-server, and
  Uptime Kuma secrets from Bitwarden Secrets Manager under systemd. This is
  blocked until the Oaknet lab backup substrate exists and should not store live
  passwords, Push URLs, or Bitwarden tokens in git.

## Remote Access Layout

- [`docs/specs/2026-06-07-fedora-remote-access-layout.md`](docs/specs/2026-06-07-fedora-remote-access-layout.md)
  — incoming SSH plus two RDP paths for Fedora workstations: KDE RDP on `3389`
  for the active Plasma Wayland session, and XRDP on `3390` with a separate
  fallback user/session for pre-login or post-reboot GUI access.

## Scripts

**Start here — the single entry point:**

- [`setup-all.sh`](setup-all.sh) — one-shot, idempotent
  setup of a fresh machine. Always runs the two core orchestrators
  (`bootstrap-fedora` → shell environment, then `install-apps` → applications);
  **prompts** for each optional (VS Code, Tailscale, the SSH server, and — on
  KDE — the RDP server and quick-access shortcut), defaulting to No; and
  installs the NVIDIA driver
  **only** with an explicit `--with-nvidia` (never automatic — it's
  hardware-specific). Under `--no-prompt` it runs core only and skips optionals.
  Runs as your user (children self-elevate). Supports `--dry-run`,
  `--no-prompt`, `--with-nvidia`, `--dotfiles-dir=<path>`. Everything below can
  also be run individually.

- [`install/nvidia-driver.sh`](install/nvidia-driver.sh) — install the proprietary NVIDIA
  driver via RPM Fusion. Solves a DisplayPort-retrain-after-suspend bug
  affecting newer NVIDIA GPUs (e.g. RTX 5070 Ti / GB203 Blackwell) under
  the open-source nouveau driver. Re-execs under `sudo` automatically.
  One reboot if the akmod build finishes during install; otherwise a
  second reboot once the freshly-built module loads. Supports
  `--dry-run` and `--no-prompt`.

- [`install/vscode.sh`](install/vscode.sh) — install
  Visual Studio Code via Microsoft's official RPM repo. Imports the GPG key,
  writes `/etc/yum.repos.d/vscode.repo`, and runs `dnf install code`. Each
  step is idempotent (skips when state already matches). Re-execs under
  `sudo` automatically. Supports `--dry-run` and `--no-prompt`.

- [`install/tailscale.sh`](install/tailscale.sh) —
  install Tailscale (official Fedora RPM repo), enable `tailscaled`, and enroll
  this machine on your tailnet so it's reachable by Magic DNS name from any of
  your other machines — the "remote access" half of a peers-and-remote setup.
  Backend-state-aware enrollment: already-up → skip; authenticated-but-down →
  `tailscale up`; logged-out → browser login (interactive) or a `TS_AUTHKEY`
  env var (`--no-prompt`). `--ssh` also turns on Tailscale SSH. Re-execs under
  `sudo -E` (preserving `TS_AUTHKEY`). Supports `--dry-run` and `--no-prompt`.

- [`configure/ssh-server.sh`](configure/ssh-server.sh) —
  enable + start `sshd` and ensure the firewalld `ssh` service, for remote
  shell access over LAN and tailnet (independent of Tailscale SSH).
  sshd_config stays at Fedora defaults. Auto-sudo. Supports `--dry-run` and
  `--no-prompt`. Design: [remote-access spec](docs/specs/2026-06-07-fedora-remote-access-layout.md).

- [`configure/rdp-server.sh`](configure/rdp-server.sh) —
  KDE only. Enables krdp, KDE's built-in RDP server (preinstalled with Plasma
  ≥ 6.1), which shares the **live Wayland session**: generates a self-signed
  TLS cert, writes `krdpserverrc` with `SystemUserEnabled` (RDP clients log in
  with the Linux username/password — no stored secret), ensures the firewalld
  `rdp` service, and enables the `app-org.kde.krdpserver.service` user unit so
  it starts with every Plasma login. Runs as the user (refuses root); inline
  sudo only for the firewall step if needed. Works only while a desktop
  session is logged in. Supports `--dry-run` and `--no-prompt`.
  Design: [remote-access spec](docs/specs/2026-06-07-fedora-remote-access-layout.md).

- [`configure/xrdp-fallback.sh`](configure/xrdp-fallback.sh) —
  XRDP on `:3390` serving a **separate** XFCE session (krdp on `:3389` only shares
  the *live* Plasma session, which doesn't exist after a Wake-on-LAN/cold boot —
  it drops with `ERRINFO_LOGOFF_BY_USER`). Installs xrdp/xorgxrdp + minimal XFCE,
  creates a non-admin fallback user (default `<hostname>-rdp`) with a `~/.xsession`,
  moves xrdp to 3390, and labels the port under SELinux. Auto-sudo; the user's
  password is set interactively. Supports `--dry-run`, `--no-prompt`, `--user=`,
  `--port=`. Design: [remote-access layout](docs/specs/2026-06-07-fedora-remote-access-layout.md).

- [`configure/remote-access-firewall.sh`](configure/remote-access-firewall.sh) —
  swap the broad firewalld `ssh`/`rdp` services for **source-restricted** rich
  rules (plus tcp/3390), limited to the Users VLAN (`10.69.11.0/24`) and
  Tailscale CGNAT (`100.64.0.0/10`) by default (`--source=` to override). Adds
  the restricted rules before removing the broad ones, with one confirmation
  gate. Auto-sudo. Supports `--dry-run` and `--no-prompt`.
  Design: [remote-access layout](docs/specs/2026-06-07-fedora-remote-access-layout.md).

- [`install/quick-access-terminal-shortcut.sh`](install/quick-access-terminal-shortcut.sh)
  — KDE only. Binds `Meta+Return` to `kitten quick-access-terminal` (a Quake-style
  drop-down terminal) via a `NoDisplay` `.desktop` file plus a
  `[services][…] _launch=Meta+Return` entry in `kglobalshortcutsrc`. Best-effort
  `kded6` reload at the end; log out / back in if the chord doesn't fire. No sudo.
  Supports `--dry-run` and `--no-prompt`.

### Workstation-specific workflows

- [`workstations/usagi/finish-prime-ssh-workflow.sh`](workstations/usagi/finish-prime-ssh-workflow.sh)
  — finish `usagi` as a client for the primary `prime` workstation. It installs
  client-side SSH/RDP helpers, VS Code Remote SSH, Tailscale, and SSH aliases for
  `prime`, while leaving `prime` as the authoritative code workspace.

### zsh bootstrap

The quickest path is the orchestrator, which runs the five user-level scripts
below in order (NVIDIA driver excluded — it's workstation-specific):

- [`bootstrap-fedora.sh`](bootstrap-fedora.sh) —
  sequences `modern-cli-tools` → `starship` → `zsh-plugins` → `deploy-dotfiles`
  → `configure-shell-to-zsh`, gating each step (auto-proceed when
  non-interactive) and aborting on any child failure. Runs as your user — each
  child elevates itself if it needs root. Passes through `--dry-run` /
  `--no-prompt` / `--dotfiles-dir`. Clone the dotfiles repo first;
  `deploy-dotfiles` needs it.

Or run the five individually, in this order:

- [`install/modern-cli-tools.sh`](install/modern-cli-tools.sh)
  — `dnf install` a curated set of modern CLI replacements + zsh + the kitty
  terminal: `eza`, `bat`, `fd-find`, `zoxide`, `git-delta`, `direnv`, `fzf`,
  `ripgrep`, `nvtop`, `zsh`, `kitty`. (kitty is here because the shell setup is
  kitty-centric — `configure-shell-to-zsh` pins its `shell`, the quick-access
  shortcut needs `kitten`, and the dotfiles ship kitty config.) Each package is
  `rpm -q`'d and skipped if already installed.
  Re-execs under `sudo` automatically. Supports `--dry-run` and `--no-prompt`.

- [`install/starship.sh`](install/starship.sh) — install
  the [starship](https://starship.rs) cross-shell prompt to `~/.local/bin/` via
  the official installer. Runs as the invoking user (no sudo). If starship is
  already present, reports the version and prompts to re-run the installer
  (default: skip). Supports `--dry-run` and `--no-prompt`.

- [`install/zsh-plugins.sh`](install/zsh-plugins.sh) —
  shallow-clone the four QoL plugins into `~/.config/zsh/plugins/`:
  `zsh-autosuggestions`, `zsh-syntax-highlighting`, `zsh-completions` (all
  zsh-users), and `fzf-tab` (Aloxaf — fzf-driven completion menu). If a
  plugin is already present with the expected upstream, offers `git pull --ff-only`
  (default: skip). No sudo. Supports `--dry-run` and `--no-prompt`.

- [`configure/shell-to-zsh.sh`](configure/shell-to-zsh.sh)
  — symlink `~/.zshenv` + `~/.zshrc` → `~/projects/dotfiles/` (`.zshenv`
  holds PATH/env so `~/.local/bin` tools resolve in non-interactive shells too —
  ssh/cron/systemd; override the repo with `--dotfiles-dir`), append `shell
  /bin/zsh` to `~/.config/kitty/system.conf`
  if not already present (works around the kitty `$SHELL`-frozen-after-chsh
  gotcha), and run `chsh -s /bin/zsh`. The chsh step prompts for the user's
  password via PAM; it's skipped in `--no-prompt` mode with a warning.
  Supports `--dry-run` and `--no-prompt`.

- [`dotfiles/deploy.sh`](dotfiles/deploy.sh) — walk the
  dotfiles repo (default: `~/projects/dotfiles`) and symlink every
  regular file into the matching path under `~/`. So `<repo>/.zshrc` →
  `~/.zshrc`, `<repo>/.config/kitty/kitty.conf` → `~/.config/kitty/kitty.conf`,
  and so on. Skips `.git/`, `.gitignore`, `README.md`, `CLAUDE.md`, and
  `settings.local.json` (machine-specific — holds the per-machine `env` block
  incl. `CLAUDE_SETUP_DIR`, so it's never symlinked from a shared copy). Per file:
  silent skip if already a correct symlink, prompt+back-up-and-replace if a
  regular file exists, warn+skip on conflicting symlink. No sudo. Supports
  `--dry-run`, `--no-prompt`, `--dotfiles-dir <path>`.

- [`dotfiles/reload.sh`](dotfiles/reload.sh) — the
  ongoing-sync companion to `deploy-dotfiles` (the `reload` idiom: fetch remote
  first, then apply). `git fetch`es the dotfiles repo, reports exactly what
  diverged (incoming/local-only commits, uncommitted changes), then reconciles.
  Because the dotfiles are symlinks into the repo, a pull updates your live
  config in place. Interactive shows the 3-way (replace-local / keep-local /
  commit-and-push-first); `--no-prompt` does "pull only if clean" — fast-forwards
  when the tree is clean and not ahead, otherwise aborts untouched (exit 2) so an
  unattended run never destroys local work. Re-runs `deploy-dotfiles` afterward
  to link newly-added files (`--skip-deploy` opts out). No sudo. Supports
  `--dry-run`, `--no-prompt`, `--dotfiles-dir <path>`. Run this on each peer
  machine to pull the other's committed dotfiles changes.

**Recommended manual run order** for the shell environment (fresh machine) — or
just run `setup-all.sh` (whole machine) or
`bootstrap-fedora.sh` (shell only, which does steps 1–3, 5, 6):

1. `install/modern-cli-tools.sh`
2. `install/starship.sh`
3. `install/zsh-plugins.sh`
4. Clone the dotfiles repo to `~/projects/dotfiles/`
5. `dotfiles/deploy.sh`
6. `configure/shell-to-zsh.sh` (chsh; the kitty + .zshrc steps
   are no-ops at this point because step 5 already deployed them)

### Applications

The manually-curated app set the workstation carries, reproduced on a peer via
one orchestrator (or run the individual installers). NVIDIA is excluded
(separate, workstation-specific). Design:
[`docs/specs/2026-06-03-reproduce-manual-apps-design.md`](docs/specs/2026-06-03-reproduce-manual-apps-design.md).

- [`install/apps.sh`](install/apps.sh) — orchestrator.
  Runs the eight app installers below in order (docker → chrome → mullvad →
  flatpaks → node/npm-globals → uv → claude → rmapi), gating each step and passing
  through `--dry-run` / `--no-prompt`. Runs as your user; each child elevates
  itself if it needs root. Mirrors `bootstrap-fedora.sh`.

- [`install/docker.sh`](install/docker.sh) — Docker CE
  via Docker's official repo (engine + cli + buildx + compose + containerd),
  enables the `docker` service, and adds you to the `docker` group (effectively
  root — needs a re-login). Auto-sudo. `--dry-run` / `--no-prompt`.

- [`install/chrome.sh`](install/chrome.sh) — Google
  Chrome (`google-chrome-stable`) via Google's signed repo. Auto-sudo.
  `--dry-run` / `--no-prompt`.

- [`install/mullvad.sh`](install/mullvad.sh) — Mullvad
  VPN + browser via Mullvad's signed repo. Auto-sudo. `--dry-run` / `--no-prompt`.

- [`install/flatpaks.sh`](install/flatpaks.sh) — ensure
  flatpak + the Flathub remote, then install every app ID in
  [`install/flatpak-apps.list`](install/flatpak-apps.list) (Obsidian, GIMP, Zen, Firefox),
  skipping already-installed. System-wide by default (auto-sudo); `--user` flips
  to per-user (no sudo). `--dry-run` / `--no-prompt`.

- [`install/node-and-npm-globals.sh`](install/node-and-npm-globals.sh)
  — `dnf install nodejs npm`, then `npm install -g` each entry in
  [`install/npm-globals.list`](install/npm-globals.list) (`@openai/codex`, `firebase-tools`).
  Auto-sudo (global prefix is `/usr/local`). `--dry-run` / `--no-prompt`.

- [`install/uv.sh`](install/uv.sh) — Astral `uv` (Python
  package/project manager; also `uvx`) to `~/.local/bin` via the official
  installer. No sudo. `--dry-run` / `--no-prompt`.

- [`install/claude.sh`](install/claude.sh) — the Claude
  Code CLI via its official native installer, to `~/.local/bin`. No sudo.
  `--dry-run` / `--no-prompt`.

- [`install/rmapi.sh`](install/rmapi.sh) — the `rmapi`
  reMarkable CLI: downloads the latest `ddvk/rmapi` release (the maintained fork)
  for your arch and installs it to `~/.local/bin`. No sudo; refuses root;
  idempotent (re-download prompt if already present). `--dry-run` / `--no-prompt`.
