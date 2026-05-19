# fedora-setup

One-off scripts and notes for setting up a Fedora workstation.

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
