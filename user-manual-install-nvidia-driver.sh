#!/usr/bin/env bash
# user-manual-install-nvidia-driver.sh — Install proprietary NVIDIA driver on Fedora
#
# Problem this solves:
#   The nouveau (open-source) driver fails to re-train DisplayPort links after
#   suspend/resume on newer NVIDIA GPUs (e.g. RTX 5070 Ti / GB203 Blackwell).
#   Symptom: one monitor doesn't turn back on after waking from sleep.
#   Kernel evidence: repeated "DP_TRAIN retrain ... (ret:-5)" errors from nouveau.
#
# What this script does:
#   1. Ensures RPM Fusion nonfree repo is enabled
#   2. Installs akmod-nvidia (proprietary NVIDIA kernel module)
#   3. Blacklists nouveau and rebuilds initramfs
#   4. Instructs on the two-reboot process required to complete the switch
#
# Usage:
#   ./user-manual-install-nvidia-driver.sh                # interactive
#   ./user-manual-install-nvidia-driver.sh --no-prompt    # non-interactive, idempotent
#   ./user-manual-install-nvidia-driver.sh --dry-run      # show what would happen, change nothing

set -euo pipefail

# ── Flag parsing ─────────────────────────────────────────────────────────────
_DRY_RUN=0
for _arg in "$@"; do
  case "$_arg" in
    --no-prompt) export RUNTOOLS_AS_NONINTERACTIVE=1 ;;
    --dry-run)   _DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $_arg" >&2
      echo "Run '$0 --help' for usage." >&2
      exit 64
      ;;
  esac
done

# Auto-detect non-TTY (piped, scheduled) execution → behave non-interactively.
[ -t 1 ] || export RUNTOOLS_AS_NONINTERACTIVE=1

# ── Helpers ──────────────────────────────────────────────────────────────────
info()   { echo "[INFO]  $*"; }
warn()   { echo "[WARN]  $*"; }
die()    { echo "[ERROR] $*" >&2; exit 1; }
dryrun() { [ "$_DRY_RUN" -eq 1 ]; }

# Read a one-character answer with a 30s timeout. Echoes the chosen char.
# In non-interactive mode, echoes the default without prompting.
ask() {
  local prompt="$1" default="$2" answer
  if [ "${RUNTOOLS_AS_NONINTERACTIVE:-0}" = "1" ]; then
    echo "$default"
    return
  fi
  read -r -t 30 -p "  $prompt (auto-$default in 30s): " answer || answer=""
  echo "${answer:-$default}"
}

# Re-exec under sudo if not already root. In dry-run, stay unprivileged
# (state-checking commands all work without root; only writes need it).
require_root() {
  if [ "$EUID" -ne 0 ]; then
    if dryrun; then
      info "[DRY-RUN] would re-exec under sudo. Continuing as $(id -un) for state checks."
      return
    fi
    info "Re-executing under sudo to gain root privileges..."
    exec sudo -E "$0" "$@"
  fi
}

# ── Pre-flight ───────────────────────────────────────────────────────────────
if ! grep -q "^ID=fedora" /etc/os-release 2>/dev/null; then
  die "This script targets Fedora. /etc/os-release does not look like Fedora."
fi

require_root "$@"

FEDORA_VERSION=$(rpm -E %fedora)
info "Detected Fedora $FEDORA_VERSION."
dryrun && warn "Running in --dry-run mode; no changes will be made."

# ── Confirmation gate (only on first-time install) ───────────────────────────
if ! rpm -q akmod-nvidia &>/dev/null && ! modinfo -F version nvidia &>/dev/null; then
  warn "About to install proprietary NVIDIA driver, blacklist nouveau, and rebuild initramfs."
  warn "Two reboots may be required (see done-message)."
  case "$(ask 'Continue? [Y/n/q]' 'y')" in
    [Nn]*|[Qq]*) die "Aborted by user." ;;
    *) ;;
  esac
fi

# ── Step 1: RPM Fusion nonfree repo ──────────────────────────────────────────
if rpm -q rpmfusion-nonfree-release &>/dev/null; then
  info "RPM Fusion nonfree repo already installed — skipping."
else
  info "Adding RPM Fusion nonfree repository..."
  if dryrun; then
    info "[DRY-RUN] would run: dnf install -y https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VERSION}.noarch.rpm"
  else
    dnf install -y \
      "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VERSION}.noarch.rpm"
  fi
fi

# ── Step 2: Install akmod-nvidia ─────────────────────────────────────────────
if modinfo -F version nvidia &>/dev/null; then
  CURRENT=$(modinfo -F version nvidia)
  info "Proprietary NVIDIA driver already installed (version $CURRENT) — skipping install."
else
  info "Installing akmod-nvidia..."
  if dryrun; then
    info "[DRY-RUN] would run: dnf install -y akmod-nvidia && akmods --force"
  else
    dnf install -y akmod-nvidia
    info "Building kernel module (this can take a few minutes)..."
    akmods --force || true
    if modinfo -F version nvidia &>/dev/null; then
      info "NVIDIA module built successfully."
    else
      warn "Module did not finish building yet — akmod will retry on first reboot."
    fi
  fi
fi

# ── Step 3: Blacklist nouveau ────────────────────────────────────────────────
MODPROBE_CONF=/etc/modprobe.d/nvidia.conf

if grep -q "blacklist nouveau" "$MODPROBE_CONF" 2>/dev/null; then
  info "nouveau already blacklisted in $MODPROBE_CONF — skipping."
else
  info "Blacklisting nouveau driver in $MODPROBE_CONF..."
  if dryrun; then
    info "[DRY-RUN] would write blacklist file."
  else
    cat > "$MODPROBE_CONF" <<'EOF'
# Disable the nouveau open-source NVIDIA driver so the proprietary
# akmod-nvidia driver is used exclusively.
blacklist nouveau
options nouveau modeset=0
EOF
  fi
fi

# ── Step 4: Rebuild initramfs ────────────────────────────────────────────────
info "Rebuilding initramfs..."
if dryrun; then
  info "[DRY-RUN] would run: dracut --force"
else
  dracut --force
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
if dryrun; then
  info "Dry run complete. No changes were made."
else
  echo "========================================================"
  echo " NVIDIA driver setup complete."
  echo "========================================================"
  echo ""
  echo " Next steps:"
  echo "   1. Reboot now. On first boot akmod-nvidia may still be"
  echo "      compiling the module — if 'modinfo -F version nvidia'"
  echo "      reports no module, wait a few minutes and reboot a"
  echo "      second time so the freshly-built module is loaded."
  echo "   2. After login, confirm the driver loaded:"
  echo "        modinfo -F version nvidia"
  echo "        lsmod | grep nvidia"
  echo "   3. If the above shows the driver, suspend/resume should"
  echo "      now work correctly for all monitors."
  echo ""
  echo " Troubleshooting:"
  echo "   journalctl -b 0 -k | grep -i nvidia"
  echo "========================================================"
fi
