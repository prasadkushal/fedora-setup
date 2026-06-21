#!/usr/bin/env bash
# install/flatpaks.sh — Install Flatpak apps from the manifest
#
# What this does:
#   Makes Flatpak app installs reproducible from a plain text manifest. It:
#     1. Ensures flatpak is installed (via dnf, if needed and running as root).
#     2. Adds the Flathub remote (idempotent).
#     3. Installs every app ID listed in flatpak-apps.list, skipping any that
#        are already installed.
#
#   By default apps are installed system-wide (needs root). Pass --user to flip
#   to a per-user install instead (no root required).
#
# Usage:
#   ./install/flatpaks.sh              # system-wide install (needs root)
#   ./install/flatpaks.sh --user        # per-user install, no sudo
#   ./install/flatpaks.sh --dry-run     # show what would change, do nothing
#   ./install/flatpaks.sh --user --dry-run
#
# Manifest: flatpak-apps.list (must live next to this script)

set -euo pipefail

# ── Flag parsing ─────────────────────────────────────────────────────────────
_DRY_RUN=0
_USER_SCOPE=0
for _arg in "$@"; do
  case "$_arg" in
    --no-prompt) export RUNTOOLS_AS_NONINTERACTIVE=1 ;;
    --dry-run)   _DRY_RUN=1 ;;
    --user)      _USER_SCOPE=1 ;;
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
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Root is only required for system-wide installs.
[ "$_USER_SCOPE" -eq 0 ] && require_root "$@"

dryrun && warn "Running in --dry-run mode; no changes will be made."

# ── Manifest ─────────────────────────────────────────────────────────────────
MANIFEST="$_SCRIPT_DIR/flatpak-apps.list"
[ -f "$MANIFEST" ] || die "Manifest not found: $MANIFEST"
SCOPE_FLAG=""; [ "$_USER_SCOPE" -eq 1 ] && SCOPE_FLAG="--user"

# ── ensure flatpak present ───────────────────────────────────────────────────
if rpm -q flatpak &>/dev/null; then
  info "flatpak already installed — skipping."
elif dryrun; then
  info "[DRY-RUN] would run: dnf install -y flatpak"
elif [ "$EUID" -ne 0 ]; then
  die "flatpak is not installed and we are not root (--user mode). Install it first: sudo dnf install -y flatpak"
else
  dnf install -y flatpak || die "Failed to install flatpak."
fi

# ── Flathub remote ───────────────────────────────────────────────────────────
# shellcheck disable=SC2086
if flatpak remote-list ${SCOPE_FLAG} 2>/dev/null | grep -qw flathub; then
  info "flathub remote already present — skipping."
elif dryrun; then
  # shellcheck disable=SC2086
  info "[DRY-RUN] would run: flatpak remote-add ${SCOPE_FLAG} --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo"
else
  # shellcheck disable=SC2086
  flatpak remote-add ${SCOPE_FLAG} --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
fi

# ── install each manifest entry ──────────────────────────────────────────────
while IFS= read -r app; do
  app="${app%%#*}"; app="$(echo "$app" | xargs)"   # strip comments + whitespace
  [ -z "$app" ] && continue
  # shellcheck disable=SC2086
  if flatpak info ${SCOPE_FLAG} "$app" &>/dev/null; then
    info "$app already installed — skipping."
  elif dryrun; then
    # shellcheck disable=SC2086
    info "[DRY-RUN] would run: flatpak install ${SCOPE_FLAG} -y --noninteractive flathub $app"
  else
    # shellcheck disable=SC2086
    flatpak install ${SCOPE_FLAG} -y --noninteractive flathub "$app" || warn "Failed to install $app (continuing)."
  fi
done < "$MANIFEST"

echo ""
dryrun && info "Dry run complete. No changes were made." || info "Flatpak install complete."
