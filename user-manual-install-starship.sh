#!/usr/bin/env bash
# user-manual-install-starship.sh — Install the starship cross-shell prompt
#
# What this does:
#   Downloads and runs the official starship installer
#   (https://starship.rs/install.sh) targeting ~/.local/bin/. The installer
#   handles platform detection and binary placement; we pass --bin-dir so it
#   installs into the user's bin (no sudo) and --yes so it doesn't prompt.
#
# Idempotency:
#   - If `starship` already exists at ~/.local/bin/starship, the script reports
#     the version and prompts to run the installer again (default: skip).
#   - Otherwise it runs the installer.
#
# Usage:
#   ./user-manual-install-starship.sh             # interactive
#   ./user-manual-install-starship.sh --no-prompt # non-interactive, idempotent
#   ./user-manual-install-starship.sh --dry-run   # show, change nothing
#
# Note: This script does NOT require sudo. starship installs to ~/.local/bin/
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
[ "$EUID" -eq 0 ] && die "Don't run this as root — starship installs to ~/.local/bin/."

command -v curl &>/dev/null || die "curl not found. Install it with: sudo dnf install curl"

mkdir -p "$HOME/.local/bin"

dryrun && warn "Running in --dry-run mode; no changes will be made."

# ── Install / upgrade ────────────────────────────────────────────────────────
STARSHIP_BIN="$HOME/.local/bin/starship"

if [ -x "$STARSHIP_BIN" ]; then
  installed=$("$STARSHIP_BIN" --version 2>/dev/null | head -1)
  info "starship already installed: $installed"
  case "$(ask 'Re-run installer to check for upgrade? [y/N/q]' 'n')" in
    [Yy]*) ;;
    [Qq]*) die "Aborted by user." ;;
    *)     info "Leaving installed version unchanged."; exit 0 ;;
  esac
else
  info "starship not found — will install to $STARSHIP_BIN"
fi

if dryrun; then
  info "[DRY-RUN] would run: curl -sS https://starship.rs/install.sh | sh -s -- --bin-dir $HOME/.local/bin --yes"
else
  curl -sS https://starship.rs/install.sh | sh -s -- --bin-dir "$HOME/.local/bin" --yes
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
if dryrun; then
  info "Dry run complete. No changes were made."
else
  info "starship installed at $STARSHIP_BIN ($("$STARSHIP_BIN" --version | head -1))"
  info "Activate in zsh: add 'eval \"\$(starship init zsh)\"' to your ~/.zshrc"
  info "Activate in bash: add 'eval \"\$(starship init bash)\"' to your ~/.bashrc"
fi
