# fedora-setup

One-off scripts and notes for setting up a Fedora workstation.

## Runbooks

- [`NIBBLER.md`](NIBBLER.md) — provision the Beelink SER6 mini-PC
  (`oaknet-nibbler`) with the same shell/CLI/Claude environment as the main
  workstation. Config reproduction (clone repos + run the bootstrap scripts),
  not a disk clone; the NVIDIA driver script is intentionally skipped because
  the SER6 has no NVIDIA GPU.

## Scripts

**Start here — the single entry point:**

- [`user-manual-setup-all.sh`](user-manual-setup-all.sh) — one-shot, idempotent
  setup of a fresh machine. Always runs the two core orchestrators
  (`bootstrap-fedora` → shell environment, then `install-apps` → applications);
  **prompts** for each optional (VS Code, Tailscale, and — on KDE — the
  quick-access shortcut), defaulting to No; and installs the NVIDIA driver
  **only** with an explicit `--with-nvidia` (never automatic — it's
  hardware-specific). Under `--no-prompt` it runs core only and skips optionals.
  Runs as your user (children self-elevate). Supports `--dry-run`,
  `--no-prompt`, `--with-nvidia`, `--dotfiles-dir=<path>`. Everything below can
  also be run individually.

- [`user-manual-install-nvidia-driver.sh`](user-manual-install-nvidia-driver.sh) — install the proprietary NVIDIA
  driver via RPM Fusion. Solves a DisplayPort-retrain-after-suspend bug
  affecting newer NVIDIA GPUs (e.g. RTX 5070 Ti / GB203 Blackwell) under
  the open-source nouveau driver. Re-execs under `sudo` automatically.
  One reboot if the akmod build finishes during install; otherwise a
  second reboot once the freshly-built module loads. Supports
  `--dry-run` and `--no-prompt`.

- [`user-manual-install-vscode.sh`](user-manual-install-vscode.sh) — install
  Visual Studio Code via Microsoft's official RPM repo. Imports the GPG key,
  writes `/etc/yum.repos.d/vscode.repo`, and runs `dnf install code`. Each
  step is idempotent (skips when state already matches). Re-execs under
  `sudo` automatically. Supports `--dry-run` and `--no-prompt`.

- [`user-manual-install-tailscale.sh`](user-manual-install-tailscale.sh) —
  install Tailscale (official Fedora RPM repo), enable `tailscaled`, and enroll
  this machine on your tailnet so it's reachable by Magic DNS name from any of
  your other machines — the "remote access" half of a peers-and-remote setup.
  Backend-state-aware enrollment: already-up → skip; authenticated-but-down →
  `tailscale up`; logged-out → browser login (interactive) or a `TS_AUTHKEY`
  env var (`--no-prompt`). `--ssh` also turns on Tailscale SSH. Re-execs under
  `sudo -E` (preserving `TS_AUTHKEY`). Supports `--dry-run` and `--no-prompt`.

- [`user-manual-install-quick-access-terminal-shortcut.sh`](user-manual-install-quick-access-terminal-shortcut.sh)
  — KDE only. Binds `Meta+Return` to `kitten quick-access-terminal` (a Quake-style
  drop-down terminal) via a `NoDisplay` `.desktop` file plus a
  `[services][…] _launch=Meta+Return` entry in `kglobalshortcutsrc`. Best-effort
  `kded6` reload at the end; log out / back in if the chord doesn't fire. No sudo.
  Supports `--dry-run` and `--no-prompt`.

### zsh bootstrap

The quickest path is the orchestrator, which runs the five user-level scripts
below in order (NVIDIA driver excluded — it's workstation-specific):

- [`user-manual-bootstrap-fedora.sh`](user-manual-bootstrap-fedora.sh) —
  sequences `modern-cli-tools` → `starship` → `zsh-plugins` → `deploy-dotfiles`
  → `configure-shell-to-zsh`, gating each step (auto-proceed when
  non-interactive) and aborting on any child failure. Runs as your user — each
  child elevates itself if it needs root. Passes through `--dry-run` /
  `--no-prompt` / `--dotfiles-dir`. Clone the dotfiles repo first;
  `deploy-dotfiles` needs it.

Or run the five individually, in this order:

- [`user-manual-install-modern-cli-tools.sh`](user-manual-install-modern-cli-tools.sh)
  — `dnf install` a curated set of modern CLI replacements + zsh + the kitty
  terminal: `eza`, `bat`, `fd-find`, `zoxide`, `git-delta`, `direnv`, `fzf`,
  `ripgrep`, `nvtop`, `zsh`, `kitty`. (kitty is here because the shell setup is
  kitty-centric — `configure-shell-to-zsh` pins its `shell`, the quick-access
  shortcut needs `kitten`, and the dotfiles ship kitty config.) Each package is
  `rpm -q`'d and skipped if already installed.
  Re-execs under `sudo` automatically. Supports `--dry-run` and `--no-prompt`.

- [`user-manual-install-starship.sh`](user-manual-install-starship.sh) — install
  the [starship](https://starship.rs) cross-shell prompt to `~/.local/bin/` via
  the official installer. Runs as the invoking user (no sudo). If starship is
  already present, reports the version and prompts to re-run the installer
  (default: skip). Supports `--dry-run` and `--no-prompt`.

- [`user-manual-install-zsh-plugins.sh`](user-manual-install-zsh-plugins.sh) —
  shallow-clone the three zsh-users QoL plugins into `~/.config/zsh/plugins/`:
  `zsh-autosuggestions`, `zsh-syntax-highlighting`, `zsh-completions`. If a
  plugin is already present with the expected upstream, offers `git pull --ff-only`
  (default: skip). No sudo. Supports `--dry-run` and `--no-prompt`.

- [`user-manual-configure-shell-to-zsh.sh`](user-manual-configure-shell-to-zsh.sh)
  — symlink `~/.zshrc` → `~/projects/repos/dotfiles/.zshrc` (override with
  `--dotfiles-dir`), append `shell /bin/zsh` to `~/.config/kitty/system.conf`
  if not already present (works around the kitty `$SHELL`-frozen-after-chsh
  gotcha), and run `chsh -s /bin/zsh`. The chsh step prompts for the user's
  password via PAM; it's skipped in `--no-prompt` mode with a warning.
  Supports `--dry-run` and `--no-prompt`.

- [`user-manual-deploy-dotfiles.sh`](user-manual-deploy-dotfiles.sh) — walk the
  dotfiles repo (default: `~/projects/repos/dotfiles`) and symlink every
  regular file into the matching path under `~/`. So `<repo>/.zshrc` →
  `~/.zshrc`, `<repo>/.config/kitty/kitty.conf` → `~/.config/kitty/kitty.conf`,
  and so on. Skips `.git/`, `.gitignore`, `README.md`, `CLAUDE.md`, and
  `settings.local.json` (machine-specific — holds the per-machine `env` block
  incl. `CLAUDE_SETUP_DIR`, so it's never symlinked from a shared copy). Per file:
  silent skip if already a correct symlink, prompt+back-up-and-replace if a
  regular file exists, warn+skip on conflicting symlink. No sudo. Supports
  `--dry-run`, `--no-prompt`, `--dotfiles-dir <path>`.

- [`user-manual-reload-dotfiles.sh`](user-manual-reload-dotfiles.sh) — the
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
just run `user-manual-setup-all.sh` (whole machine) or
`user-manual-bootstrap-fedora.sh` (shell only, which does steps 1–3, 5, 6):

1. `user-manual-install-modern-cli-tools.sh`
2. `user-manual-install-starship.sh`
3. `user-manual-install-zsh-plugins.sh`
4. Clone the dotfiles repo to `~/projects/repos/dotfiles/`
5. `user-manual-deploy-dotfiles.sh`
6. `user-manual-configure-shell-to-zsh.sh` (chsh; the kitty + .zshrc steps
   are no-ops at this point because step 5 already deployed them)

### Applications

The manually-curated app set the workstation carries, reproduced on a peer via
one orchestrator (or run the individual installers). NVIDIA is excluded
(separate, workstation-specific). Design:
[`docs/specs/2026-06-03-reproduce-manual-apps-design.md`](docs/specs/2026-06-03-reproduce-manual-apps-design.md).

- [`user-manual-install-apps.sh`](user-manual-install-apps.sh) — orchestrator.
  Runs the eight app installers below in order (docker → chrome → mullvad →
  flatpaks → node/npm-globals → uv → claude → rmapi), gating each step and passing
  through `--dry-run` / `--no-prompt`. Runs as your user; each child elevates
  itself if it needs root. Mirrors `user-manual-bootstrap-fedora.sh`.

- [`user-manual-install-docker.sh`](user-manual-install-docker.sh) — Docker CE
  via Docker's official repo (engine + cli + buildx + compose + containerd),
  enables the `docker` service, and adds you to the `docker` group (effectively
  root — needs a re-login). Auto-sudo. `--dry-run` / `--no-prompt`.

- [`user-manual-install-chrome.sh`](user-manual-install-chrome.sh) — Google
  Chrome (`google-chrome-stable`) via Google's signed repo. Auto-sudo.
  `--dry-run` / `--no-prompt`.

- [`user-manual-install-mullvad.sh`](user-manual-install-mullvad.sh) — Mullvad
  VPN + browser via Mullvad's signed repo. Auto-sudo. `--dry-run` / `--no-prompt`.

- [`user-manual-install-flatpaks.sh`](user-manual-install-flatpaks.sh) — ensure
  flatpak + the Flathub remote, then install every app ID in
  [`flatpak-apps.list`](flatpak-apps.list) (Obsidian, GIMP, Zen, Firefox),
  skipping already-installed. System-wide by default (auto-sudo); `--user` flips
  to per-user (no sudo). `--dry-run` / `--no-prompt`.

- [`user-manual-install-node-and-npm-globals.sh`](user-manual-install-node-and-npm-globals.sh)
  — `dnf install nodejs npm`, then `npm install -g` each entry in
  [`npm-globals.list`](npm-globals.list) (`@openai/codex`, `firebase-tools`).
  Auto-sudo (global prefix is `/usr/local`). `--dry-run` / `--no-prompt`.

- [`user-manual-install-uv.sh`](user-manual-install-uv.sh) — Astral `uv` (Python
  package/project manager; also `uvx`) to `~/.local/bin` via the official
  installer. No sudo. `--dry-run` / `--no-prompt`.

- [`user-manual-install-claude.sh`](user-manual-install-claude.sh) — the Claude
  Code CLI via its official native installer, to `~/.local/bin`. No sudo.
  `--dry-run` / `--no-prompt`.

- [`user-manual-install-rmapi.sh`](user-manual-install-rmapi.sh) — the `rmapi`
  reMarkable CLI: downloads the latest `ddvk/rmapi` release (the maintained fork)
  for your arch and installs it to `~/.local/bin`. No sudo; refuses root;
  idempotent (re-download prompt if already present). `--dry-run` / `--no-prompt`.
