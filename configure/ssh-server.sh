#!/usr/bin/env bash
# configure/ssh-server.sh — Enable the OpenSSH server for remote shell access
#
# What this does:
#   Makes this machine reachable over SSH (LAN and tailnet) instead of relying
#   on Tailscale SSH alone. On Fedora it:
#     1. Installs openssh-server if missing (preinstalled on Fedora Workstation).
#     2. Enables + starts sshd.service.
#     3. Ensures the `ssh` service in firewalld's default zone (runtime +
#        permanent) — already present in the stock FedoraWorkstation zone.
#     4. Verifies something is listening on port 22 and prints connect hints.
#
#   sshd_config is left at Fedora defaults (key + password auth,
#   PermitRootLogin prohibit-password). Harden separately if this machine is
#   ever exposed beyond LAN/tailnet.
#
# Usage:
#   ./configure/ssh-server.sh              # interactive
#   ./configure/ssh-server.sh --no-prompt  # unattended
#   ./configure/ssh-server.sh --dry-run    # show, change nothing
#
# Auto-sudo: managing sshd + firewalld needs root; this re-execs under sudo.
# State checks run unprivileged in --dry-run.

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
if ! grep -q "^ID=fedora" /etc/os-release 2>/dev/null; then
  die "This script targets Fedora. /etc/os-release does not look like Fedora."
fi

require_root "$@"

dryrun && warn "Running in --dry-run mode; no changes will be made."

# ── Step 1: openssh-server package ───────────────────────────────────────────
if rpm -q openssh-server &>/dev/null; then
  info "openssh-server already installed ($(rpm -q --qf '%{VERSION}-%{RELEASE}' openssh-server)) — skipping."
elif dryrun; then
  info "[DRY-RUN] would run: dnf install -y openssh-server"
else
  info "Installing openssh-server..."
  dnf install -y openssh-server || die "dnf install openssh-server failed."
fi

# ── Step 2: enable + start sshd ──────────────────────────────────────────────
if systemctl is-enabled --quiet sshd 2>/dev/null && systemctl is-active --quiet sshd 2>/dev/null; then
  info "sshd already enabled and running — skipping."
elif dryrun; then
  info "[DRY-RUN] would run: systemctl enable --now sshd"
else
  info "Enabling and starting sshd..."
  systemctl enable --now sshd || die "Failed to enable sshd."
fi

# ── Step 3: firewalld ssh service ────────────────────────────────────────────
# Stock FedoraWorkstation zone already allows ssh; this only repairs setups
# where it was removed. Warn (don't die) when firewalld itself is off — sshd
# is then reachable anyway.
if ! systemctl is-active --quiet firewalld 2>/dev/null; then
  warn "firewalld is not active — skipping firewall step (port 22 is open by absence of a firewall)."
elif firewall-cmd --query-service=ssh &>/dev/null; then
  info "firewalld already allows the ssh service — skipping."
elif dryrun; then
  info "[DRY-RUN] would run: firewall-cmd --add-service=ssh && firewall-cmd --permanent --add-service=ssh"
else
  info "Allowing the ssh service in firewalld (runtime + permanent)..."
  firewall-cmd --add-service=ssh           || die "firewall-cmd --add-service=ssh failed."
  firewall-cmd --permanent --add-service=ssh || die "firewall-cmd --permanent --add-service=ssh failed."
fi

# ── Step 4: verify + connect hints ───────────────────────────────────────────
echo ""
if dryrun; then
  info "Dry run complete. No changes were made."
else
  if ss -tln 2>/dev/null | grep -q ':22 '; then
    info "sshd is listening on port 22."
  else
    die "sshd was enabled but nothing is listening on port 22 — check 'systemctl status sshd'."
  fi
  _user="${SUDO_USER:-$(id -un)}"
  info "Connect with:  ssh ${_user}@$(hostname -s)   (LAN mDNS: ssh ${_user}@$(hostname -s).local)"
  if command -v tailscale >/dev/null 2>&1; then
    _ts_ip="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
    [ -n "$_ts_ip" ] && info "Over the tailnet: ssh ${_user}@$(hostname -s)  or  ssh ${_user}@${_ts_ip}"
  fi
  info "SSH server setup complete."
fi
