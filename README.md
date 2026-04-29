# fedora-setup

One-off scripts and notes for setting up a Fedora workstation.

## Scripts

- [`nvidia-driver.sh`](nvidia-driver.sh) — install the proprietary NVIDIA
  driver via RPM Fusion. Solves a DisplayPort-retrain-after-suspend bug
  affecting newer NVIDIA GPUs (e.g. RTX 5070 Ti / GB203 Blackwell) under
  the open-source nouveau driver. Run as root; requires two reboots to
  complete the akmod build.
