#!/usr/bin/env bash
# user-manual-deploy-dotfiles.sh — Symlink every file in the dotfiles repo into ~/
#
# What this does:
#   Walks the dotfiles repo (default: ~/projects/repos/dotfiles) and creates a
#   symlink in $HOME for every regular file in it, preserving the file's
#   path relative to the repo root. So:
#     <dotfiles>/.zshrc           → ~/.zshrc
#     <dotfiles>/.bashrc          → ~/.bashrc
#     <dotfiles>/.config/kitty/x  → ~/.config/kitty/x
#   ...and so on. New files added to the dotfiles repo are automatically
#   deployed on the next run.
#
# Per-file behavior (idempotent):
#   - Symlink correctly points at dotfiles                   → skip silently
#   - File missing                                           → create symlink
#   - Regular file exists                                    → back up to .bak
#                                                              and replace
#                                                              with symlink
#   - Symlink points somewhere else                          → warn + prompt
#                                                              (default: skip)
#   - Empty dir along the target path                        → create as needed
#
# Excluded paths (never symlinked into ~/):
#   .git/* .gitignore README.md CLAUDE.md
#
# Usage:
#   ./user-manual-deploy-dotfiles.sh                       # interactive
#   ./user-manual-deploy-dotfiles.sh --no-prompt           # non-interactive
#   ./user-manual-deploy-dotfiles.sh --dry-run             # show, change nothing
#   ./user-manual-deploy-dotfiles.sh --dotfiles-dir <path> # override default repo location
#
# Note: This script does NOT auto-sudo. All operations are in the user's $HOME.

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
DOTFILES_DIR="$HOME/projects/repos/dotfiles"

# ── Flag parsing ─────────────────────────────────────────────────────────────
_DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-prompt)       export RUNTOOLS_AS_NONINTERACTIVE=1 ;;
    --dry-run)         _DRY_RUN=1 ;;
    --dotfiles-dir)    DOTFILES_DIR="$2"; shift ;;
    --dotfiles-dir=*)  DOTFILES_DIR="${1#--dotfiles-dir=}" ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Run '$0 --help' for usage." >&2
      exit 64
      ;;
  esac
  shift
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
[ "$EUID" -eq 0 ] && die "Don't run this as root — everything goes into your \$HOME."
[ -d "$DOTFILES_DIR" ] || die "Dotfiles dir '$DOTFILES_DIR' not found. Pass --dotfiles-dir=<path> to override."
[ -d "$DOTFILES_DIR/.git" ] || warn "$DOTFILES_DIR is not a git repo. Continuing anyway."

dryrun && warn "Running in --dry-run mode; no changes will be made."

info "Deploying from: $DOTFILES_DIR"
info "Target root:    $HOME"

# ── Per-file deploy ──────────────────────────────────────────────────────────
# Walk all regular files, excluding git internals and repo meta files.
# Using find -print0 + read -d '' to handle filenames safely.
count_skip=0
count_create=0
count_replace=0
count_warn=0

while IFS= read -r -d '' source_abs; do
  rel="${source_abs#$DOTFILES_DIR/}"
  target="$HOME/$rel"
  target_dir="$(dirname "$target")"

  # Ensure parent dir exists.
  if [ ! -d "$target_dir" ]; then
    if dryrun; then
      info "[DRY-RUN] would mkdir -p $target_dir"
    else
      mkdir -p "$target_dir"
    fi
  fi

  if [ -L "$target" ]; then
    current="$(readlink -f "$target" 2>/dev/null || true)"
    expected="$(readlink -f "$source_abs")"
    if [ "$current" = "$expected" ]; then
      count_skip=$((count_skip+1))
      continue
    fi
    warn "$target symlinks to '$current' (expected '$expected')."
    case "$(ask 'Replace symlink? [y/N/q]' 'n')" in
      [Yy]*)
        if dryrun; then
          info "[DRY-RUN] would replace symlink: ln -sfn $source_abs $target"
        else
          ln -sfn "$source_abs" "$target"
          info "Replaced symlink: $target → $source_abs"
        fi
        count_replace=$((count_replace+1))
        ;;
      [Qq]*) die "Aborted by user." ;;
      *)
        info "Leaving $target alone."
        count_warn=$((count_warn+1))
        ;;
    esac
  elif [ -e "$target" ]; then
    info "$target is a regular file."
    case "$(ask 'Back it up and replace with symlink? [Y/n/q]' 'y')" in
      [Yy]*)
        ts=$(date +%Y-%m-%dT%H%M)
        bak="${target}.${ts}.bak"
        if dryrun; then
          info "[DRY-RUN] would back up $target → $bak, then ln -s $source_abs $target"
        else
          mv "$target" "$bak"
          ln -s "$source_abs" "$target"
          info "Backed up to $bak; symlinked $target → $source_abs"
        fi
        count_replace=$((count_replace+1))
        ;;
      [Qq]*) die "Aborted by user." ;;
      *)
        info "Leaving $target alone."
        count_warn=$((count_warn+1))
        ;;
    esac
  else
    if dryrun; then
      info "[DRY-RUN] would symlink: ln -s $source_abs $target"
    else
      ln -s "$source_abs" "$target"
      info "Symlinked $target → $source_abs"
    fi
    count_create=$((count_create+1))
  fi
done < <(find "$DOTFILES_DIR" -type f \
  ! -path '*/.git/*' \
  ! -name '.gitignore' \
  ! -name 'README.md' \
  ! -name 'CLAUDE.md' \
  -print0)

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
if dryrun; then
  info "Dry run complete. Would have: $count_create created, $count_replace replaced (with backup), $count_skip already correct, $count_warn skipped on user choice."
else
  info "Deploy complete. $count_create created, $count_replace replaced (with backup), $count_skip already correct, $count_warn skipped on user choice."
fi
