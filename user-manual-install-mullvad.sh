#!/usr/bin/env bash
# user-manual-install-mullvad.sh — Install Mullvad VPN app and browser on Fedora
#
# What this does:
#   Gives you a fully-working Mullvad install via Mullvad's official signed repo:
#     1. Adds Mullvad's stable RPM repo (idempotent).
#     2. dnf-installs mullvad-vpn (VPN app + `mullvad` CLI) and mullvad-browser
#        (skipped if already present).
#
# Usage:
#   ./user-manual-install-mullvad.sh                  # interactive
#   ./user-manual-install-mullvad.sh --no-prompt      # unattended (auto-confirms)
#   ./user-manual-install-mullvad.sh --dry-run        # show what would happen, change nothing
#
# Auto-sudo: installing packages needs root; this re-execs under `sudo -E`.
# State checks run unprivileged (--dry-run stays as the invoking user).

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

ask() {
  local prompt="$1" default="$2" answer
  if [ "${RUNTOOLS_AS_NONINTERACTIVE:-0}" = "1" ]; then
    echo "$default"
    return
  fi
  read -r -t 30 -p "  $prompt (auto-$default in 30s): " answer || answer=""
  echo "${answer:-$default}"
}

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

info "Detected Fedora $(rpm -E %fedora)."
dryrun && warn "Running in --dry-run mode; no changes will be made."

# ── Step 1: Mullvad stable repo ──────────────────────────────────────────────
REPO_FILE="/etc/yum.repos.d/mullvad.repo"
REPO_URL="https://repository.mullvad.net/rpm/stable/mullvad.repo"
if [ -f "$REPO_FILE" ]; then
  info "Mullvad repo already present ($REPO_FILE) — skipping."
elif dryrun; then
  info "[DRY-RUN] would run: curl -fsSL $REPO_URL -o $REPO_FILE"
else
  command -v curl >/dev/null 2>&1 || die "curl is required. Install it: dnf install -y curl"
  curl -fsSL "$REPO_URL" -o "$REPO_FILE" || die "Failed to download $REPO_URL"
  info "Added Mullvad stable repo."
fi

# ── Step 2: install packages ─────────────────────────────────────────────────
MULLVAD_PKGS=(mullvad-vpn mullvad-browser)
to_install=()
for p in "${MULLVAD_PKGS[@]}"; do rpm -q "$p" &>/dev/null || to_install+=("$p"); done
if [ "${#to_install[@]}" -eq 0 ]; then
  info "All Mullvad packages already installed — skipping."
elif dryrun; then
  info "[DRY-RUN] would run: dnf install -y ${to_install[*]}"
else
  dnf install -y "${to_install[@]}" || die "dnf install failed."
fi

echo ""
dryrun && info "Dry run complete. No changes were made." || info "Mullvad install complete. Launch the VPN app, or use the 'mullvad' CLI."
