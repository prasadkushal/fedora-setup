#!/usr/bin/env bash
# configure/rdp-server.sh — Enable KDE's built-in RDP server (krdp)
#
# What this does:
#   Makes this machine's desktop reachable over RDP without clicking through
#   System Settings. krdp (KDE's first-party RDP server, preinstalled with
#   Plasma >= 6.1) shares the LIVE Wayland session via the remote-desktop
#   portal — what you see locally is what the remote client drives. Steps:
#     1. Pre-flight: krdpserver + kwriteconfig6 present (Fedora KDE ships both).
#     2. Generate a self-signed TLS cert pair under ~/.local/share/krdpserver/
#        if missing (same location the System Settings module uses).
#     3. Write ~/.config/krdpserverrc: Autostart=true, SystemUserEnabled=true
#        (RDP clients log in with this machine's Linux username + password —
#        no separate secret to provision), cert paths, Quality=100.
#     4. Ensure the `rdp` service in firewalld's default zone (inline sudo,
#        only if missing).
#     5. Enable + start the per-user unit app-org.kde.krdpserver.service
#        (WantedBy=plasma-workspace.target → starts with every Plasma login).
#     6. Verify port 3389 is listening and print connect hints.
#
# Caveats:
#   - RDP works only while a graphical session is logged in — krdpserver
#     shares the live session; there is no headless login screen.
#   - The cert is self-signed: clients show a one-time trust warning.
#
# Usage:
#   ./configure/rdp-server.sh              # interactive
#   ./configure/rdp-server.sh --no-prompt  # unattended
#   ./configure/rdp-server.sh --dry-run    # show, change nothing
#
# This script runs as your normal user and REFUSES root: the config, certs,
# and systemd unit are all per-user. Only the firewall step (if needed) uses
# inline sudo.

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

# Read a krdpserverrc key ('' if unset); set it only when it differs.
CONFIG_FILE="$HOME/.config/krdpserverrc"
cfg_get() { kreadconfig6 --file "$CONFIG_FILE" --group General --key "$1" 2>/dev/null || echo ''; }
cfg_ensure() {
  local key="$1" value="$2" current
  current="$(cfg_get "$key")"
  if [ "$current" = "$value" ]; then
    info "krdpserverrc: $key=$value already set — skipping."
    return 1
  elif dryrun; then
    info "[DRY-RUN] would set krdpserverrc: $key=$value (currently '${current:-unset}')"
    return 1
  else
    kwriteconfig6 --file "$CONFIG_FILE" --group General --key "$key" "$value"
    info "krdpserverrc: set $key=$value (was '${current:-unset}')."
    return 0
  fi
}

# ── Pre-flight ───────────────────────────────────────────────────────────────
[ "$EUID" -eq 0 ] && die "Don't run this as root — config, certs, and the systemd unit are per-user."

command -v krdpserver    >/dev/null || die "krdpserver not found. Install it first: sudo dnf install -y krdp (ships with Fedora KDE / Plasma >= 6.1)."
command -v kwriteconfig6 >/dev/null || die "kwriteconfig6 not found. Install kf6-kconfig (Fedora package)."
command -v kreadconfig6  >/dev/null || die "kreadconfig6 not found. Install kf6-kconfig (Fedora package)."
command -v openssl       >/dev/null || die "openssl not found. Install it: sudo dnf install -y openssl"

case "${XDG_CURRENT_DESKTOP:-}" in
  *KDE*) : ;;
  *) warn "XDG_CURRENT_DESKTOP='${XDG_CURRENT_DESKTOP:-}' — not a KDE session? krdp targets Plasma; continuing anyway." ;;
esac

dryrun && warn "Running in --dry-run mode; no changes will be made."

# ── Step 1: TLS certificate pair ─────────────────────────────────────────────
# Same location and shape the System Settings module generates. Self-signed:
# RDP clients show a one-time trust warning — accepted for LAN/tailnet use.
CERT_DIR="$HOME/.local/share/krdpserver"
CERT="$CERT_DIR/krdp.crt"
KEY="$CERT_DIR/krdp.key"
if [ -s "$CERT" ] && [ -s "$KEY" ]; then
  info "TLS certificate pair already present in $CERT_DIR — skipping."
elif dryrun; then
  info "[DRY-RUN] would generate a self-signed TLS cert pair in $CERT_DIR (openssl, 10 years, key chmod 600)"
else
  info "Generating self-signed TLS certificate pair in $CERT_DIR..."
  mkdir -p "$CERT_DIR"
  openssl req -x509 -newkey rsa:4096 -nodes -days 3650 \
    -subj "/CN=$(hostname -s)" \
    -keyout "$KEY" -out "$CERT" >/dev/null 2>&1 || die "openssl certificate generation failed."
  chmod 600 "$KEY"
  info "Generated $CERT (+ key, mode 600)."
fi

# ── Step 2: krdpserverrc ─────────────────────────────────────────────────────
_config_changed=0
cfg_ensure Autostart         true    && _config_changed=1 || true
cfg_ensure SystemUserEnabled true    && _config_changed=1 || true
cfg_ensure Certificate       "$CERT" && _config_changed=1 || true
cfg_ensure CertificateKey    "$KEY"  && _config_changed=1 || true
cfg_ensure Quality           100     && _config_changed=1 || true

# ── Step 3: firewalld rdp service ────────────────────────────────────────────
# Querying is unprivileged; only adding needs root, via inline sudo (the rest
# of this script must NOT run as root — see header).
if ! systemctl is-active --quiet firewalld 2>/dev/null; then
  warn "firewalld is not active — skipping firewall step (port 3389 is open by absence of a firewall)."
elif firewall-cmd --query-service=rdp &>/dev/null; then
  info "firewalld already allows the rdp service — skipping."
elif dryrun; then
  info "[DRY-RUN] would run: sudo firewall-cmd --add-service=rdp && sudo firewall-cmd --permanent --add-service=rdp"
elif [ "${RUNTOOLS_AS_NONINTERACTIVE:-0}" = "1" ]; then
  # Unattended: only proceed if sudo works without a password prompt.
  sudo -n firewall-cmd --add-service=rdp >/dev/null 2>&1 \
    && sudo -n firewall-cmd --permanent --add-service=rdp >/dev/null 2>&1 \
    || die "Port 3389 is not open and unattended sudo is unavailable. Run:
       sudo firewall-cmd --add-service=rdp && sudo firewall-cmd --permanent --add-service=rdp"
  info "Allowed the rdp service in firewalld (runtime + permanent)."
else
  info "Allowing the rdp service in firewalld (runtime + permanent; sudo may prompt)..."
  sudo firewall-cmd --add-service=rdp           || die "sudo firewall-cmd --add-service=rdp failed."
  sudo firewall-cmd --permanent --add-service=rdp || die "sudo firewall-cmd --permanent --add-service=rdp failed."
fi

# ── Step 4: enable + start the per-user service ──────────────────────────────
UNIT="app-org.kde.krdpserver.service"
_enabled=0; systemctl --user is-enabled --quiet "$UNIT" 2>/dev/null && _enabled=1
_active=0;  systemctl --user is-active  --quiet "$UNIT" 2>/dev/null && _active=1

if [ "$_enabled" -eq 1 ] && [ "$_active" -eq 1 ] && [ "$_config_changed" -eq 0 ]; then
  info "$UNIT already enabled and running — skipping."
elif dryrun; then
  info "[DRY-RUN] would run: systemctl --user enable --now $UNIT"
else
  if [ "$_active" -eq 1 ] && [ "$_config_changed" -eq 1 ]; then
    info "Config changed — restarting $UNIT..."
    systemctl --user restart "$UNIT" || die "Failed to restart $UNIT."
  fi
  info "Enabling and starting $UNIT..."
  systemctl --user enable --now "$UNIT" || die "Failed to enable $UNIT — is a graphical session running? (krdpserver needs the desktop portal)."
fi

# ── Step 5: verify + connect hints ───────────────────────────────────────────
echo ""
if dryrun; then
  info "Dry run complete. No changes were made."
else
  sleep 1   # give krdpserver a moment to bind
  if ss -tln 2>/dev/null | grep -q ':3389 '; then
    info "krdpserver is listening on port 3389."
  else
    die "Service started but nothing is listening on 3389 — check: systemctl --user status $UNIT"
  fi
  info "Connect from any RDP client (Remmina, Windows mstsc, ...):"
  info "  host:  $(hostname -s):3389  (LAN mDNS: $(hostname -s).local)"
  if command -v tailscale >/dev/null 2>&1; then
    _ts_ip="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
    [ -n "$_ts_ip" ] && info "  tailnet: $(hostname -s)  or  ${_ts_ip}"
  fi
  info "  login: your Linux username + password (SystemUserEnabled)."
  info "Note: works only while you are logged in to the desktop session;"
  info "  the self-signed cert triggers a one-time trust warning."
fi
