#!/usr/bin/env bash
# install/claude.sh — Install the Claude Code CLI
#
# What this does:
#   Downloads and runs the official Claude Code native installer
#   (https://claude.ai/install.sh) which places the `claude` binary in
#   ~/.local/bin/. No sudo required; the installer runs as the invoking user.
#
# Idempotency:
#   - If `claude` is already on PATH, the script reports the version and
#     prompts to re-run the installer (default: skip). Useful for upgrades,
#     but note that `claude update` is the preferred self-update path once
#     the CLI is installed.
#   - Otherwise it runs the installer.
#
# Usage:
#   ./install/claude.sh             # interactive
#   ./install/claude.sh --no-prompt # non-interactive, idempotent
#   ./install/claude.sh --dry-run   # show, change nothing
#
# Note: This script does NOT require sudo. The Claude Code installer places
# `claude` in ~/.local/bin/ and runs as the invoking user. (Re-running with
# `sudo` would install into /root and is not what you want.)

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
[ "$EUID" -eq 0 ] && die "Don't run this as root — Claude Code installs to ~/.local/bin/."

command -v curl &>/dev/null || die "curl not found. Install it with: sudo dnf install curl"

mkdir -p "$HOME/.local/bin"

dryrun && warn "Running in --dry-run mode; no changes will be made."

# ── Install / upgrade ────────────────────────────────────────────────────────
if command -v claude >/dev/null 2>&1; then
  installed=$(claude --version 2>/dev/null | head -1)
  info "claude already installed: $installed"
  case "$(ask 'Re-run installer to check for upgrade? [y/N/q]' 'n')" in
    [Yy]*) ;;
    [Qq]*) die "Aborted by user." ;;
    *)     info "Leaving installed version unchanged."; exit 0 ;;
  esac
else
  info "claude not found — will install via the official installer."
fi

if dryrun; then
  info "[DRY-RUN] would run: curl -fsSL https://claude.ai/install.sh | bash"
else
  curl -fsSL https://claude.ai/install.sh | bash
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
if dryrun; then
  info "Dry run complete. No changes were made."
else
  info "claude installed. It lands in ~/.local/bin (already on PATH via the dotfiles)."
  info "If 'claude' isn't found, restart your shell."
fi
