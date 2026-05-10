# fedora-setup

One-off scripts and notes for setting up a Fedora workstation.

## Scripts

- [`user-manual-install-nvidia-driver.sh`](user-manual-install-nvidia-driver.sh) — install the proprietary NVIDIA
  driver via RPM Fusion. Solves a DisplayPort-retrain-after-suspend bug
  affecting newer NVIDIA GPUs (e.g. RTX 5070 Ti / GB203 Blackwell) under
  the open-source nouveau driver. Run as root; requires two reboots to
  complete the akmod build.

- [`user-manual-install-vscode.sh`](user-manual-install-vscode.sh) — install
  Visual Studio Code via Microsoft's official RPM repo. Imports the GPG key,
  writes `/etc/yum.repos.d/vscode.repo`, and runs `dnf install code`. Each
  step is idempotent (skips when state already matches). Re-execs under
  `sudo` automatically. Supports `--dry-run` and `--no-prompt`.
