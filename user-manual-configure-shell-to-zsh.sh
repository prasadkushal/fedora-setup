#!/usr/bin/env bash
# user-manual-configure-shell-to-zsh.sh — Flip the user's interactive shell to zsh
#
# What this does (three idempotent steps):
#   1. Symlink ~/.zshrc → <dotfiles-repo>/.zshrc. If a regular file already
#      exists, it's backed up with a timestamped .bak suffix first.
#   2. Append `shell /bin/zsh` to ~/.config/kitty/system.conf if it isn't
#      already present. This makes kitty launch zsh in new tabs regardless of
#      the $SHELL env var (which is frozen at desktop-session start and
#      doesn't refresh after `chsh`).
#   3. Run `chsh -s /bin/zsh` so the persistent login shell flips. PAM prompts
#      for the user's password; this step is skipped in --no-prompt mode.
#
# Each step checks current state before acting. Re-running the script when
# everything is already configured is a no-op.
#
# Usage:
#   ./user-manual-configure-shell-to-zsh.sh                       # interactive
#   ./user-manual-configure-shell-to-zsh.sh --no-prompt           # non-interactive
#   ./user-manual-configure-shell-to-zsh.sh --dry-run             # show, change nothing
#   ./user-manual-configure-shell-to-zsh.sh --dotfiles-dir <path> # override dotfiles repo
#
# Prerequisites (run these first):
#   - user-manual-install-modern-cli-tools.sh   (installs zsh + tools)
#   - user-manual-install-starship.sh           (prompt)
#   - user-manual-install-zsh-plugins.sh        (autosuggestions / highlighting / completions)
#   - A dotfiles repo clone at ~/projects/repos/dotfiles (default) with a
#     .zshrc at its root. Override the location with --dotfiles-dir if needed.
#
# Note: This script does NOT auto-sudo. chsh runs as the invoking user (PAM
# prompts for their password); kitty.conf and ~/.zshrc are in the user's home.

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
[ "$EUID" -eq 0 ] && die "Don't run this as root."

command -v zsh &>/dev/null || die "zsh not found. Run user-manual-install-modern-cli-tools.sh first."
[ -x /bin/zsh ] || die "/bin/zsh not found (zsh is installed but not at the expected path)."

grep -q "^/bin/zsh$" /etc/shells || die "/bin/zsh missing from /etc/shells — chsh would refuse the change. Reinstall zsh or add /bin/zsh to /etc/shells."

[ -f "$DOTFILES_DIR/.zshrc" ] || die "Dotfiles dir '$DOTFILES_DIR' missing .zshrc. Pass --dotfiles-dir=<path> to override."

dryrun && warn "Running in --dry-run mode; no changes will be made."

# ── Step 1: symlink ~/.zshrc → $DOTFILES_DIR/.zshrc ──────────────────────────
TARGET="$HOME/.zshrc"
SOURCE="$DOTFILES_DIR/.zshrc"

if [ -L "$TARGET" ]; then
  current=$(readlink -f "$TARGET" 2>/dev/null || true)
  expected=$(readlink -f "$SOURCE")
  if [ "$current" = "$expected" ]; then
    info "$TARGET already symlinks to $SOURCE — skipping."
  else
    warn "$TARGET symlinks to '$current' (expected '$expected')."
    case "$(ask 'Replace symlink? [y/N/q]' 'n')" in
      [Yy]*)
        if dryrun; then
          info "[DRY-RUN] would run: ln -sfn $SOURCE $TARGET"
        else
          ln -sfn "$SOURCE" "$TARGET"
          info "Replaced symlink → $SOURCE"
        fi
        ;;
      [Qq]*) die "Aborted by user." ;;
      *)     info "Leaving symlink as-is." ;;
    esac
  fi
elif [ -e "$TARGET" ]; then
  info "$TARGET is a regular file."
  case "$(ask 'Back it up and replace with symlink? [Y/n/q]' 'y')" in
    [Yy]*)
      ts=$(date +%Y-%m-%dT%H%M)
      bak="${TARGET}.${ts}.bak"
      if dryrun; then
        info "[DRY-RUN] would back up $TARGET → $bak, then ln -s $SOURCE $TARGET"
      else
        mv "$TARGET" "$bak"
        ln -s "$SOURCE" "$TARGET"
        info "Backed up to $bak; symlinked $TARGET → $SOURCE."
      fi
      ;;
    [Qq]*) die "Aborted by user." ;;
    *)     info "Leaving $TARGET as a regular file." ;;
  esac
else
  info "$TARGET missing — creating symlink."
  if dryrun; then
    info "[DRY-RUN] would run: ln -s $SOURCE $TARGET"
  else
    ln -s "$SOURCE" "$TARGET"
    info "Symlinked $TARGET → $SOURCE."
  fi
fi

# ── Step 2: kitty system.conf — `shell /bin/zsh` override ────────────────────
KITTY_CONF="$HOME/.config/kitty/system.conf"

if [ ! -f "$KITTY_CONF" ]; then
  warn "$KITTY_CONF not found — skipping kitty step. If you use kitty, add 'shell /bin/zsh' to its config manually."
elif grep -qE "^shell[[:space:]]+/bin/zsh\b" "$KITTY_CONF"; then
  info "$KITTY_CONF already pins 'shell /bin/zsh' — skipping."
else
  info "$KITTY_CONF needs 'shell /bin/zsh' for new tabs to launch zsh."
  case "$(ask 'Append the directive to system.conf? [Y/n/q]' 'y')" in
    [Yy]*)
      if dryrun; then
        info "[DRY-RUN] would append a 'shell /bin/zsh' block to $KITTY_CONF"
      else
        {
          echo ""
          echo "# shell /bin/zsh"
          echo "#"
          echo "# Pin kitty to launch zsh regardless of \$SHELL env (which is frozen at"
          echo "# desktop-session start and doesn't refresh after chsh). Added by"
          echo "# user-manual-configure-shell-to-zsh.sh."
          echo "shell /bin/zsh"
        } >> "$KITTY_CONF"
        info "Appended shell directive to $KITTY_CONF. Reload kitty with ctrl+shift+f5."
      fi
      ;;
    [Qq]*) die "Aborted by user." ;;
    *)     info "Leaving $KITTY_CONF alone." ;;
  esac
fi

# ── Step 3: chsh -s /bin/zsh ─────────────────────────────────────────────────
current_shell=$(getent passwd "$USER" | cut -d: -f7)

if [ "$current_shell" = "/bin/zsh" ]; then
  info "Login shell already /bin/zsh — skipping chsh."
elif [ "${RUNTOOLS_AS_NONINTERACTIVE:-0}" = "1" ]; then
  warn "Login shell is '$current_shell'; chsh needs interactive password input via PAM."
  warn "Skipping in non-interactive mode. Run 'chsh -s /bin/zsh' manually when ready."
else
  info "Login shell is '$current_shell'. Will run: chsh -s /bin/zsh (you'll be prompted for your password)."
  case "$(ask 'Proceed with chsh? [Y/n/q]' 'y')" in
    [Yy]*)
      if dryrun; then
        info "[DRY-RUN] would run: chsh -s /bin/zsh"
      else
        chsh -s /bin/zsh
        info "Login shell changed. New kitty tabs will land in zsh after reloading the config (ctrl+shift+f5)."
      fi
      ;;
    [Qq]*) die "Aborted by user." ;;
    *)     info "Leaving login shell as-is." ;;
  esac
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
if dryrun; then
  info "Dry run complete. No changes were made."
else
  info "Configuration complete. Open a fresh kitty tab to verify."
fi
