#!/usr/bin/env bash
# user-manual-install-modern-cli-tools.sh — Install modern CLI tool replacements via dnf
#
# What this does:
#   Installs a curated set of modern command-line tools (replacements/complements
#   for the POSIX classics) via Fedora's dnf:
#     eza         — modern `ls` replacement (icons, git status, tree mode)
#     bat         — modern `cat` replacement (syntax highlighting, paging)
#     fd-find     — modern `find` replacement (saner syntax, respects .gitignore)
#     zoxide      — smart `cd` replacement (frecency-based)
#     git-delta   — `git diff` prettifier (auto-wired via gitconfig)
#     direnv      — per-directory env-var loader
#     fzf         — fuzzy finder (Ctrl+R / Ctrl+T / Alt+C bindings in shells)
#     ripgrep     — faster, gitignore-aware `grep`
#     nvtop       — GPU monitor (NVIDIA, AMD, Intel)
#     zsh         — z shell (target shell for user-manual-configure-shell-to-zsh.sh)
#     kitty       — GPU terminal emulator. Not a POSIX replacement, but the rest
#                   of the setup is kitty-centric (configure-shell-to-zsh pins
#                   kitty's `shell`; quick-access-terminal-shortcut needs kitten;
#                   the dotfiles ship kitty config), so it's installed here to
#                   keep the bootstrap self-sufficient.
#     git-filter-repo — surgical git history rewriting (single-purpose CLI)
#
# Each package is checked individually via `rpm -q`; already-installed ones are
# skipped. The remaining set is installed with a single `dnf install -y`.
#
# Usage:
#   ./user-manual-install-modern-cli-tools.sh             # interactive
#   ./user-manual-install-modern-cli-tools.sh --no-prompt # non-interactive, idempotent
#   ./user-manual-install-modern-cli-tools.sh --dry-run   # show, change nothing

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

# ── Package list ─────────────────────────────────────────────────────────────
PACKAGES=(
  eza
  bat
  fd-find
  zoxide
  git-delta
  direnv
  fzf
  ripgrep
  nvtop
  zsh
  kitty
  git-filter-repo
)

# ── Skip-already-installed pass ──────────────────────────────────────────────
to_install=()
for pkg in "${PACKAGES[@]}"; do
  if rpm -q "$pkg" &>/dev/null; then
    installed=$(rpm -q --qf '%{VERSION}-%{RELEASE}' "$pkg")
    info "$pkg already installed ($installed) — skipping."
  else
    to_install+=("$pkg")
  fi
done

if [ "${#to_install[@]}" -eq 0 ]; then
  echo ""
  info "All packages already installed. Nothing to do."
  exit 0
fi

info "Will install: ${to_install[*]}"
case "$(ask 'Proceed with dnf install? [Y/n/q]' 'y')" in
  [Yy]*)
    if dryrun; then
      info "[DRY-RUN] would run: dnf install -y ${to_install[*]}"
    else
      dnf install -y "${to_install[@]}"
    fi
    ;;
  [Qq]*) die "Aborted by user." ;;
  *)     info "Skipping install."; exit 0 ;;
esac

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
if dryrun; then
  info "Dry run complete. No changes were made."
else
  info "Done. ${#to_install[@]} package(s) installed."
fi
