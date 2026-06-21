#!/usr/bin/env bash
# configure/xrdp-fallback.sh — XRDP fallback desktop on :3390 (separate session)
#
# What this solves:
#   KDE's krdp (:3389) shares the *live* Plasma session — useless when the
#   machine booted (e.g. via Wake-on-LAN) and is sitting at SDDM with no
#   session: krdp authenticates then drops with ERRINFO_LOGOFF_BY_USER. XRDP
#   spawns its OWN Xorg/XFCE session on demand, so you get a desktop after a
#   cold boot WITHOUT enabling SDDM autologin (which would leave the physical
#   console logged in).
#
#   Layout (see docs/specs/2026-06-07-fedora-remote-access-layout.md):
#     :3389  KDE krdp  — live Plasma session   (configure/rdp-server.sh)
#     :3390  XRDP      — separate XFCE session  (this script)
#   Both can't share 3389, so XRDP is moved to 3390.
#
# What it does:
#   1. dnf-install xrdp + xorgxrdp + a minimal XFCE + dbus-x11.
#   2. Create a non-admin fallback user (default: <hostname>-rdp) and set its
#      ~/.xsession to launch XFCE under its own dbus session.
#   3. Move XRDP's listener to 3390 (backs up xrdp.ini first; idempotent).
#   4. SELinux: label tcp/3390 as an rdp port if enforcing (else xrdp can't bind).
#   5. enable --now xrdp + xrdp-sesman; verify 3390 is listening.
#
#   Firewall for 3390 is handled by configure/remote-access-firewall.sh
#   (which opens it to the allowed source networks) — run that too.
#
# Usage:
#   ./configure/xrdp-fallback.sh                 # interactive (prompts to set the user's password)
#   ./configure/xrdp-fallback.sh --user=usagi-rdp
#   ./configure/xrdp-fallback.sh --port=3390
#   ./configure/xrdp-fallback.sh --no-prompt     # skips the interactive passwd (warns)
#   ./configure/xrdp-fallback.sh --dry-run
#
# Auto-sudo: package install + system services + user creation need root; this
# re-execs under sudo. State checks (--dry-run) run unprivileged.

set -euo pipefail

# ── Flag parsing ─────────────────────────────────────────────────────────────
_DRY_RUN=0
_USER=""
_PORT=3390
for _arg in "$@"; do
  case "$_arg" in
    --no-prompt) export RUNTOOLS_AS_NONINTERACTIVE=1 ;;
    --dry-run)   _DRY_RUN=1 ;;
    --user=*)    _USER="${_arg#*=}" ;;
    --port=*)    _PORT="${_arg#*=}" ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *)
      echo "Unknown argument: $_arg" >&2
      echo "Run '$0 --help' for usage." >&2
      exit 64 ;;
  esac
done

[ -t 1 ] || export RUNTOOLS_AS_NONINTERACTIVE=1
[ -n "$_USER" ] || _USER="$(hostname -s)-rdp"

# ── Helpers ──────────────────────────────────────────────────────────────────
info()   { echo "[INFO]  $*"; }
warn()   { echo "[WARN]  $*"; }
die()    { echo "[ERROR] $*" >&2; exit 1; }
dryrun() { [ "$_DRY_RUN" -eq 1 ]; }

require_root() {
  if [ "$EUID" -ne 0 ]; then
    if dryrun; then
      info "[DRY-RUN] would re-exec under sudo. Continuing as $(id -un) for state checks."
      return
    fi
    info "Re-executing under sudo to gain root privileges..."
    exec sudo "$0" "$@"
  fi
}

# ── Pre-flight ───────────────────────────────────────────────────────────────
grep -q "^ID=fedora" /etc/os-release 2>/dev/null || die "This script targets Fedora."
case "$_PORT" in (*[!0-9]*|'') die "Invalid --port: $_PORT" ;; esac

require_root "$@"
info "Fallback user: $_USER    XRDP port: $_PORT"
dryrun && warn "Running in --dry-run mode; no changes will be made."

# ── Step 1: packages ─────────────────────────────────────────────────────────
PKGS=(xrdp xorgxrdp xfce4-session xfce4-panel xfdesktop xfwm4 xfce4-settings xfce4-terminal Thunar dbus-x11)
_missing=()
for p in "${PKGS[@]}"; do rpm -q "$p" &>/dev/null || _missing+=("$p"); done
if [ "${#_missing[@]}" -eq 0 ]; then
  info "All XRDP/XFCE packages already installed — skipping."
elif dryrun; then
  info "[DRY-RUN] would run: dnf install -y ${_missing[*]}"
else
  info "Installing: ${_missing[*]}"
  dnf install -y "${_missing[@]}" || die "package install failed."
fi

# ── Step 2: fallback user + ~/.xsession ──────────────────────────────────────
if id "$_USER" &>/dev/null; then
  info "User '$_USER' already exists — skipping creation."
elif dryrun; then
  info "[DRY-RUN] would run: useradd -m -s /bin/bash $_USER"
else
  info "Creating non-admin user '$_USER'..."
  useradd -m -s /bin/bash "$_USER" || die "useradd failed."
fi

_HOME="$(getent passwd "$_USER" 2>/dev/null | cut -d: -f6 || true)"; _HOME="${_HOME:-/home/$_USER}"
XSESSION="$_HOME/.xsession"
XSESSION_CONTENT='#!/bin/sh
# Launch XFCE under its own D-Bus session for the XRDP fallback login.
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
exec dbus-run-session startxfce4'

if [ -f "$XSESSION" ] && [ "$(cat "$XSESSION" 2>/dev/null)" = "$XSESSION_CONTENT" ]; then
  info "$XSESSION already correct — skipping."
elif dryrun; then
  info "[DRY-RUN] would write $XSESSION (exec dbus-run-session startxfce4) and chown to $_USER"
else
  printf '%s\n' "$XSESSION_CONTENT" > "$XSESSION"
  chown "$_USER:$_USER" "$XSESSION"
  chmod 755 "$XSESSION"
  info "Wrote $XSESSION (XFCE session)."
fi

# Password: XRDP login needs a known password for this user. Can't be set
# unattended; prompt interactively, warn under --no-prompt.
if dryrun; then
  info "[DRY-RUN] would prompt to set a password for '$_USER' (interactive only)."
elif [ "${RUNTOOLS_AS_NONINTERACTIVE:-0}" = "1" ]; then
  if passwd -S "$_USER" 2>/dev/null | grep -qE ' (P|PS) '; then
    info "User '$_USER' already has a password set — skipping."
  else
    warn "User '$_USER' has no password and this is non-interactive."
    warn "Set one before you can RDP in:  sudo passwd $_USER"
  fi
else
  if passwd -S "$_USER" 2>/dev/null | grep -qE ' (P|PS) '; then
    info "User '$_USER' already has a password — leaving it."
  else
    info "Set a password for '$_USER' (used to log in over RDP on :$_PORT):"
    passwd "$_USER" || warn "passwd did not complete; set it later with: sudo passwd $_USER"
  fi
fi

# ── Step 3: move XRDP listener to $_PORT ─────────────────────────────────────
XRDP_INI="/etc/xrdp/xrdp.ini"
if [ ! -f "$XRDP_INI" ]; then
  if dryrun; then
    info "[DRY-RUN] $XRDP_INI not present yet (xrdp not installed); would set port=$_PORT after install."
    _cur_port=""
  else
    die "$XRDP_INI not found (xrdp install incomplete?)."
  fi
else
  _cur_port="$(awk -F= '/^port=/{print $2; exit}' "$XRDP_INI" 2>/dev/null | tr -d '[:space:]' || true)"
fi
if [ "$_cur_port" = "$_PORT" ]; then
  info "XRDP already listening on port $_PORT in xrdp.ini — skipping."
elif dryrun; then
  info "[DRY-RUN] would back up $XRDP_INI and set port=$_PORT (currently port=$_cur_port)"
else
  cp "$XRDP_INI" "${XRDP_INI}.bak.$(stat -c %Y "$XRDP_INI")" 2>/dev/null || cp "$XRDP_INI" "${XRDP_INI}.bak"
  sed -i "0,/^port=/{s/^port=.*/port=$_PORT/}" "$XRDP_INI"
  info "Set XRDP port to $_PORT (backup alongside $XRDP_INI)."
fi

# ── Step 4: SELinux — allow xrdp to bind the non-standard port ───────────────
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" = "Enforcing" ] && [ "$_PORT" != "3389" ]; then
  if command -v semanage >/dev/null 2>&1; then
    if semanage port -l 2>/dev/null | grep -qE "^rdp_port_t .*\b${_PORT}\b"; then
      info "SELinux: tcp/$_PORT already labeled rdp_port_t — skipping."
    elif dryrun; then
      info "[DRY-RUN] would run: semanage port -a -t rdp_port_t -p tcp $_PORT"
    else
      info "SELinux: labeling tcp/$_PORT as rdp_port_t..."
      semanage port -a -t rdp_port_t -p tcp "$_PORT" 2>/dev/null \
        || semanage port -m -t rdp_port_t -p tcp "$_PORT" 2>/dev/null \
        || warn "Could not label tcp/$_PORT; if xrdp fails to bind, fix SELinux manually."
    fi
  else
    warn "SELinux enforcing but 'semanage' missing (install policycoreutils-python-utils)."
    warn "xrdp may fail to bind tcp/$_PORT until tcp/$_PORT is labeled rdp_port_t."
  fi
fi

# ── Step 5: enable + start services ──────────────────────────────────────────
if dryrun; then
  info "[DRY-RUN] would run: systemctl enable --now xrdp xrdp-sesman; then restart to pick up port change."
else
  systemctl enable --now xrdp-sesman xrdp || die "Failed to enable xrdp services."
  systemctl restart xrdp                   || die "Failed to (re)start xrdp."
  info "xrdp + xrdp-sesman enabled and started."
fi

# ── Verify ───────────────────────────────────────────────────────────────────
echo ""
if dryrun; then
  info "Dry run complete. No changes were made."
else
  sleep 1
  if ss -tln 2>/dev/null | grep -q ":$_PORT "; then
    info "XRDP is listening on port $_PORT."
  else
    die "xrdp started but nothing is listening on $_PORT — check: systemctl status xrdp; journalctl -u xrdp"
  fi
  info "Fallback desktop ready. Connect from an RDP client:"
  info "  host:  $(hostname -s):$_PORT     login: $_USER + its password"
  info "  e.g.   xfreerdp /v:$(hostname -s) /port:$_PORT /u:$_USER /cert:ignore"
  info "Open the port to your trusted networks with:"
  info "  ./configure/remote-access-firewall.sh"
fi
