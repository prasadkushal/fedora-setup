#!/usr/bin/env bash
# install/zsh-plugins.sh — Clone the quality-of-life zsh plugins
#
# What this does:
#   Clones four plugins (depth=1) into ~/.config/zsh/plugins/:
#     - zsh-autosuggestions       (fish-style inline suggestions from history)
#     - zsh-syntax-highlighting   (colorize commands as you type — invalid red,
#                                  strings yellow, valid green)
#     - zsh-completions           (extra completion definitions for many tools)
#     - fzf-tab                   (fzf-driven tab completion menu; from Aloxaf,
#                                  not zsh-users. ~/.zshrc sources it after
#                                  compinit and before autosuggestions +
#                                  syntax-highlighting, per its README.)
#
# Idempotency:
#   - If a plugin directory already exists AND is a git repo pointing at the
#     expected upstream, the script offers to `git pull --ff-only` (default:
#     skip).
#   - If a directory exists but is NOT a git repo (or has a different
#     remote), the script warns and skips that plugin — remove the dir
#     manually for a fresh clone.
#   - Otherwise it clones fresh.
#
# Usage:
#   ./install/zsh-plugins.sh             # interactive
#   ./install/zsh-plugins.sh --no-prompt # non-interactive, idempotent
#   ./install/zsh-plugins.sh --dry-run   # show, change nothing
#
# Note: This script does NOT require sudo. Plugins clone into ~/.config/zsh/.

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
[ "$EUID" -eq 0 ] && die "Don't run this as root — plugins go in ~/.config/."

command -v git &>/dev/null || die "git not found. Install it with: sudo dnf install git"

PLUGINS_DIR="$HOME/.config/zsh/plugins"
mkdir -p "$PLUGINS_DIR"

dryrun && warn "Running in --dry-run mode; no changes will be made."

# ── Plugin manifest (name → upstream URL) ────────────────────────────────────
# Iteration order matters for output predictability: keep this as a parallel
# pair of arrays rather than an associative array (which has unpredictable
# iteration order in bash).
PLUGIN_NAMES=(
  zsh-autosuggestions
  zsh-syntax-highlighting
  zsh-completions
  fzf-tab
)
PLUGIN_URLS=(
  "https://github.com/zsh-users/zsh-autosuggestions.git"
  "https://github.com/zsh-users/zsh-syntax-highlighting.git"
  "https://github.com/zsh-users/zsh-completions.git"
  "https://github.com/Aloxaf/fzf-tab.git"
)

# ── Clone / update loop ──────────────────────────────────────────────────────
for i in "${!PLUGIN_NAMES[@]}"; do
  name="${PLUGIN_NAMES[$i]}"
  url="${PLUGIN_URLS[$i]}"
  target="$PLUGINS_DIR/$name"

  if [ -d "$target/.git" ]; then
    existing_url=$(git -C "$target" config --get remote.origin.url 2>/dev/null || echo "")
    if [ "$existing_url" = "$url" ]; then
      info "$name already cloned (remote matches)."
      case "$(ask "Run 'git pull --ff-only' on $name? [y/N/q]" 'n')" in
        [Yy]*)
          if dryrun; then
            info "[DRY-RUN] would run: git -C $target pull --ff-only"
          else
            git -C "$target" pull --ff-only
          fi
          ;;
        [Qq]*) die "Aborted by user." ;;
        *)     info "Leaving $name unchanged." ;;
      esac
    else
      warn "$target is a git repo with unexpected remote '$existing_url' (expected '$url')."
      warn "Skipping. Remove the directory manually if you want a fresh clone."
    fi
  elif [ -e "$target" ]; then
    warn "$target exists but is not a git repo. Skipping."
    warn "Remove it manually if you want a fresh clone."
  else
    info "Cloning $name from $url"
    if dryrun; then
      info "[DRY-RUN] would run: git clone --depth 1 $url $target"
    else
      git clone --depth 1 "$url" "$target"
    fi
  fi
done

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
if dryrun; then
  info "Dry run complete. No changes were made."
else
  info "Done. Plugins live in $PLUGINS_DIR."
  info "Source them in ~/.zshrc — see the dotfiles repo for the expected source order"
  info "(syntax-highlighting MUST be sourced LAST per its README)."
fi
