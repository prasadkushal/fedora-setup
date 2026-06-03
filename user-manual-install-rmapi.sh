#!/usr/bin/env bash
# user-manual-install-rmapi.sh — Install the rmapi reMarkable CLI
#
# What this does:
#   Downloads the latest `rmapi` release (the maintained ddvk/rmapi fork — note
#   the original juruen/rmapi stopped at v0.0.25, while the binary you run is
#   the ddvk fork's newer build) from GitHub and installs it to ~/.local/bin/.
#   rmapi is a command-line client for the reMarkable cloud.
#
# Idempotency:
#   - If `rmapi` already exists at ~/.local/bin/rmapi, report the version and
#     prompt to re-download the latest (default: skip).
#   - Otherwise download + install.
#
# Usage:
#   ./user-manual-install-rmapi.sh             # interactive
#   ./user-manual-install-rmapi.sh --no-prompt # non-interactive, idempotent
#   ./user-manual-install-rmapi.sh --dry-run   # show, change nothing
#
# Note: This script does NOT require sudo. rmapi installs to ~/.local/bin/ and
# runs as the invoking user. (Running with `sudo` would install into /root.)

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

# ── Pre-flight ───────────────────────────────────────────────────────────────
[ "$EUID" -eq 0 ] && die "Don't run this as root — rmapi installs to ~/.local/bin/."

command -v curl &>/dev/null || die "curl not found. Install it with: sudo dnf install curl"
command -v tar  &>/dev/null || die "tar not found."

mkdir -p "$HOME/.local/bin"

# ── Resolve the release asset for this architecture ──────────────────────────
REPO="ddvk/rmapi"
case "$(uname -m)" in
  x86_64)        ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) die "Unsupported architecture: $(uname -m). rmapi ships linux amd64/arm64 only." ;;
esac
ASSET="rmapi-linux-${ARCH}.tar.gz"
# The /releases/latest/download/ path always redirects to the newest release.
URL="https://github.com/$REPO/releases/latest/download/$ASSET"
RMAPI_BIN="$HOME/.local/bin/rmapi"

dryrun && warn "Running in --dry-run mode; no changes will be made."

# ── Install / upgrade ────────────────────────────────────────────────────────
if [ -x "$RMAPI_BIN" ]; then
  info "rmapi already installed: $("$RMAPI_BIN" version 2>/dev/null | head -1)"
  case "$(ask 'Re-download the latest release? [y/N/q]' 'n')" in
    [Yy]*) ;;
    [Qq]*) die "Aborted by user." ;;
    *)     info "Leaving installed version unchanged."; exit 0 ;;
  esac
else
  info "rmapi not found — will install to $RMAPI_BIN"
fi

if dryrun; then
  info "[DRY-RUN] would download $URL, extract 'rmapi' → $RMAPI_BIN"
  echo ""
  info "Dry run complete. No changes were made."
  exit 0
fi

_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT
info "Downloading $ASSET (latest) from $REPO..."
curl -fsSL "$URL" -o "$_tmp/rmapi.tar.gz" || die "Download failed: $URL"
tar -xzf "$_tmp/rmapi.tar.gz" -C "$_tmp" rmapi || die "Failed to extract 'rmapi' from the tarball."
install -m 0755 "$_tmp/rmapi" "$RMAPI_BIN" || die "Failed to install to $RMAPI_BIN."

echo ""
info "Installed rmapi → $RMAPI_BIN ($("$RMAPI_BIN" version 2>/dev/null | head -1))"
info "First run will prompt to pair with your reMarkable account."
