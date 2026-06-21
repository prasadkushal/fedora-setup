#!/usr/bin/env bash
# install/uv.sh — Install Astral's uv Python package/project manager
#
# What this does:
#   Downloads and runs the official uv installer
#   (https://astral.sh/uv/install.sh) targeting ~/.local/bin/. uv also
#   provides `uvx` for running tools in ephemeral environments. No sudo
#   required; uv installs into the user's ~/.local/bin/ (already on PATH
#   via the dotfiles).
#
# Idempotency:
#   - If `uv` already exists at ~/.local/bin/uv, the script reports
#     the version and prompts to run the installer again (default: skip).
#   - Otherwise it runs the installer.
#
# Usage:
#   ./install/uv.sh             # interactive
#   ./install/uv.sh --no-prompt # non-interactive, idempotent
#   ./install/uv.sh --dry-run   # show, change nothing
#
# Note: This script does NOT require sudo. uv installs to ~/.local/bin/
# and runs as the invoking user. (Re-running with `sudo` would install into
# /root and is not what you want.)

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
[ "$EUID" -eq 0 ] && die "Don't run this as root — uv installs to ~/.local/bin/."

command -v curl &>/dev/null || die "curl not found. Install it with: sudo dnf install curl"

mkdir -p "$HOME/.local/bin"

dryrun && warn "Running in --dry-run mode; no changes will be made."

# ── Install / upgrade ────────────────────────────────────────────────────────
UV_BIN="$HOME/.local/bin/uv"

if [ -x "$UV_BIN" ]; then
  installed=$("$UV_BIN" --version 2>/dev/null | head -1)
  info "uv already installed: $installed"
  case "$(ask 'Re-run installer to check for upgrade? [y/N/q]' 'n')" in
    [Yy]*) ;;
    [Qq]*) die "Aborted by user." ;;
    *)     info "Leaving installed version unchanged."; exit 0 ;;
  esac
else
  info "uv not found — will install to $UV_BIN"
fi

if dryrun; then
  info "[DRY-RUN] would run: curl -LsSf https://astral.sh/uv/install.sh | sh"
else
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
if dryrun; then
  info "Dry run complete. No changes were made."
else
  uv_version=$("$UV_BIN" --version | head -1)
  info "uv installed at $UV_BIN ($uv_version)"
  info "uv also provides 'uvx' for running tools in ephemeral environments."
  info "Both uv and uvx are in ~/.local/bin/ (already on PATH via the dotfiles)."
fi
