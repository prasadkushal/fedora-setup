#!/usr/bin/env bash
# install/node-and-npm-globals.sh — Install Node.js + npm, then install npm globals
#
# What this does:
#   1. Ensures Node.js and npm are installed via dnf (skips each if already present).
#   2. Reads npm-globals.list (same directory as this script) and runs
#      `npm install -g` for each package listed, skipping already-installed ones.
#
#   The npm global prefix is /usr/local, so root access is required for step 2.
#   The script auto-re-execs under sudo if not already root (dry-run stays
#   unprivileged for state checks only).
#
# Usage:
#   ./install/node-and-npm-globals.sh             # interactive
#   ./install/node-and-npm-globals.sh --no-prompt # non-interactive, idempotent
#   ./install/node-and-npm-globals.sh --dry-run   # show, change nothing

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# ── ensure node + npm ─────────────────────────────────────────────────────────
# Guard on the binaries, NOT `rpm -q npm`: Fedora ships npm via the `nodejs-npm`
# package, so `rpm -q npm` always reports missing even when npm is present. On a
# fresh machine `dnf install nodejs npm` resolves npm → nodejs-npm correctly.
if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
  info "Node.js + npm already present (node $(node --version), npm $(npm --version)) — skipping."
elif dryrun; then
  info "[DRY-RUN] would run: dnf install -y nodejs npm"
else
  dnf install -y nodejs npm || die "Failed to install node/npm."
fi

# ── install globals from manifest ─────────────────────────────────────────────
MANIFEST="$_SCRIPT_DIR/npm-globals.list"
[ -f "$MANIFEST" ] || die "Manifest not found: $MANIFEST"
while IFS= read -r pkg; do
  pkg="${pkg%%#*}"
  pkg="$(echo "$pkg" | xargs)"   # strip leading/trailing whitespace
  [ -z "$pkg" ] && continue
  if npm ls -g "$pkg" &>/dev/null; then
    info "$pkg already installed globally — skipping."
  elif dryrun; then
    info "[DRY-RUN] would run: npm install -g $pkg"
  else
    npm install -g "$pkg" || warn "Failed to install $pkg (continuing)."
  fi
done < "$MANIFEST"

echo ""
dryrun && info "Dry run complete. No changes were made." || info "Node + npm globals install complete."
