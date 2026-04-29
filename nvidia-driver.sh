#!/usr/bin/env bash
# nvidia-driver.sh — Install proprietary NVIDIA driver on Fedora
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
#   3. Instructs on the two-reboot process required to complete the switch

set -euo pipefail

# --- helpers -----------------------------------------------------------------

info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*"; }
die()   { echo "[ERROR] $*" >&2; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root (use sudo)."
}

# --- checks ------------------------------------------------------------------

require_root

# Confirm this is Fedora
if ! grep -q "^ID=fedora" /etc/os-release 2>/dev/null; then
    die "This script is intended for Fedora only."
fi

FEDORA_VERSION=$(rpm -E %fedora)
info "Detected Fedora $FEDORA_VERSION"

# --- RPM Fusion nonfree repo -------------------------------------------------

if ! rpm -q rpmfusion-nonfree-release &>/dev/null; then
    info "Adding RPM Fusion nonfree repository..."
    dnf install -y \
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VERSION}.noarch.rpm"
else
    info "RPM Fusion nonfree repo already installed — skipping."
fi

# --- Install akmod-nvidia ----------------------------------------------------

if modinfo -F version nvidia &>/dev/null; then
    CURRENT=$(modinfo -F version nvidia)
    info "Proprietary NVIDIA driver already installed (version $CURRENT) — skipping install."
else
    info "Installing akmod-nvidia..."
    dnf install -y akmod-nvidia

    info "Waiting for kernel module to build (this can take a few minutes)..."
    # akmods builds the module in the background; wait for it to finish
    akmods --force
    modinfo -F version nvidia \
        && info "NVIDIA module built successfully." \
        || warn "Module may not have finished building yet — verify after first reboot."
fi

# --- Disable nouveau ---------------------------------------------------------

MODPROBE_CONF=/etc/modprobe.d/nvidia.conf

if ! grep -q "blacklist nouveau" "$MODPROBE_CONF" 2>/dev/null; then
    info "Blacklisting nouveau driver..."
    cat > "$MODPROBE_CONF" <<'EOF'
# Disable the nouveau open-source NVIDIA driver so the proprietary
# akmod-nvidia driver is used exclusively.
blacklist nouveau
options nouveau modeset=0
EOF
else
    info "nouveau already blacklisted in $MODPROBE_CONF — skipping."
fi

# Rebuild initramfs so the blacklist takes effect on next boot
info "Rebuilding initramfs..."
dracut --force

# --- Done --------------------------------------------------------------------

echo ""
echo "========================================================"
echo " NVIDIA driver setup complete."
echo "========================================================"
echo ""
echo " Next steps:"
echo "   1. Reboot now.  (First boot: akmods may rebuild the module)"
echo "   2. After login, confirm the driver loaded:"
echo "        modinfo -F version nvidia"
echo "        lsmod | grep nvidia"
echo "   3. If the above shows the driver, suspend/resume should"
echo "      now work correctly for all monitors."
echo ""
echo " If you still have issues after rebooting, check:"
echo "   journalctl -b 0 -k | grep -i nvidia"
echo "========================================================"
