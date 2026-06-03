# fedora-setup

One-off scripts and notes for setting up a Fedora workstation.

## Runbooks

- [`NIBBLER.md`](NIBBLER.md) — provision the Beelink SER6 mini-PC
  (`oaknet-nibbler`) with the same shell/CLI/Claude environment as the main
  workstation. Config reproduction (clone repos + run the bootstrap scripts),
  not a disk clone; the NVIDIA driver script is intentionally skipped because
  the SER6 has no NVIDIA GPU.

## Scripts

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

### zsh bootstrap (run in this order on a fresh machine)

- [`user-manual-install-modern-cli-tools.sh`](user-manual-install-modern-cli-tools.sh)
  — `dnf install` a curated set of modern CLI replacements + zsh:
  `eza`, `bat`, `fd-find`, `zoxide`, `git-delta`, `direnv`, `fzf`, `ripgrep`,
  `nvtop`, `zsh`. Each package is `rpm -q`'d and skipped if already installed.
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

  Recommended run order (fresh Fedora bootstrap):

  1. `user-manual-install-modern-cli-tools.sh`
  2. `user-manual-install-starship.sh`
  3. `user-manual-install-zsh-plugins.sh`
  4. Clone the dotfiles repo to `~/projects/repos/dotfiles/`
  5. `user-manual-deploy-dotfiles.sh`
  6. `user-manual-configure-shell-to-zsh.sh` (chsh; the kitty + .zshrc steps
     are no-ops at this point because step 5 already deployed them)
