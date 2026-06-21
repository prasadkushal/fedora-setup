#!/usr/bin/env bash
# configure/default-terminal.sh — Make kitty the default terminal under KDE Plasma
#
# Problem this solves:
#   On a fresh Fedora KDE install, Ctrl+Alt+T launches Konsole (Konsole's own
#   package default — `X-KDE-Shortcuts=Ctrl+Alt+T` in
#   /usr/share/kglobalaccel/org.kde.konsole.desktop), and KDE's "default terminal
#   application" (used by Dolphin's Open-Terminal, file-manager service menus,
#   KIO's KTerminalLauncherJob, etc.) is likewise Konsole. This workstation is
#   kitty-centric (the shell setup pins kitty; dotfiles ship kitty config), so we
#   want kitty everywhere a terminal is launched.
#
# What this script does (all under $HOME — no sudo):
#   1. Binds Ctrl+Alt+T to kitty by writing
#        [services][kitty.desktop] _launch=Ctrl+Alt+T
#      into ~/.config/kglobalshortcutsrc (same mechanism the sibling
#      quick-access script uses for kitten's Meta+Return — verified format).
#   2. Releases Konsole's claim on Ctrl+Alt+T by writing
#        [services][org.kde.konsole.desktop] _launch=none
#      Without this, both Konsole's package default and our kitty binding claim
#      Ctrl+Alt+T and Plasma resolves the collision unpredictably. We only touch
#      Konsole's binding when it is at its default (empty in the user file) or
#      explicitly on Ctrl+Alt+T; a Konsole shortcut the user deliberately moved
#      to some OTHER chord is left alone (it isn't in our way).
#   3. Sets kitty as KDE's default terminal application by writing
#        [General] TerminalApplication=kitty
#        [General] TerminalService=kitty.desktop
#      into ~/.config/kdeglobals. KTerminalLauncherJob (libKF6KIOGui) reads both
#      keys (TerminalService preferred, TerminalApplication legacy), falling back
#      to konsole then xterm — writing both covers every code path.
#   4. Best-effort reload of the global-shortcut daemon. In Plasma 6 the
#      kglobalaccel module is hosted inside kded6 (the standalone
#      plasma-kglobalaccel.service is dead), so we bounce plasma-kded6.service
#      (or kded6 directly). NOTE: this reload is best-effort; if Ctrl+Alt+T still
#      opens Konsole afterwards, log out and back in. The kdeglobals change in
#      step 3 takes effect immediately (read live on each terminal launch).
#
# Idempotency / collision handling:
#   - Each write checks current state first and skips silently if already correct.
#   - If a binding differs from what we want, interactive runs prompt before
#     changing it; --no-prompt / non-TTY runs overwrite.
#   - A spot-check warns if any OTHER service also binds Ctrl+Alt+T.
#
# Usage:
#   ./configure/default-terminal.sh             # interactive
#   ./configure/default-terminal.sh --no-prompt # idempotent, overwrites collisions
#   ./configure/default-terminal.sh --dry-run   # show, change nothing
#
# This script does NOT require sudo. Both target files live under $HOME.

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
[ "$EUID" -eq 0 ] && die "Don't run this as root — files go under \$HOME."

command -v kitty          >/dev/null || die "kitty not found. Install kitty first (install/modern-cli-tools.sh)."
command -v kwriteconfig6  >/dev/null || die "kwriteconfig6 not found. Install kf6-kconfig (Fedora package)."
command -v kreadconfig6   >/dev/null || die "kreadconfig6 not found. Install kf6-kconfig (Fedora package)."

# kitty.desktop must exist for the global-shortcut launch to resolve.
KITTY_DESKTOP_SYS="/usr/share/applications/kitty.desktop"
[ -e "$KITTY_DESKTOP_SYS" ] || [ -e "$HOME/.local/share/applications/kitty.desktop" ] \
  || warn "kitty.desktop not found in standard locations; the Ctrl+Alt+T launch may not resolve."

SHORTCUTS_FILE="$HOME/.config/kglobalshortcutsrc"
KDEGLOBALS_FILE="$HOME/.config/kdeglobals"
KITTY_ID="kitty.desktop"
KONSOLE_ID="org.kde.konsole.desktop"
CHORD="Ctrl+Alt+T"

dryrun && warn "Running in --dry-run mode; no changes will be made."

# ── Step 1: bind Ctrl+Alt+T → kitty ──────────────────────────────────────────
write_kitty_binding() {
  if dryrun; then
    info "[DRY-RUN] would run: kwriteconfig6 --file $SHORTCUTS_FILE --group services --group $KITTY_ID --key _launch $CHORD"
  else
    kwriteconfig6 --file "$SHORTCUTS_FILE" --group services --group "$KITTY_ID" --key _launch "$CHORD"
    info "Bound $CHORD to kitty ([services][$KITTY_ID] _launch=$CHORD)."
  fi
}

existing_kitty="$(kreadconfig6 --file "$SHORTCUTS_FILE" --group services --group "$KITTY_ID" --key _launch 2>/dev/null || echo '')"
if [ "$existing_kitty" = "$CHORD" ]; then
  info "kitty already bound to $CHORD — skipping."
elif [ -z "$existing_kitty" ]; then
  write_kitty_binding
else
  warn "kitty is currently bound to '$existing_kitty', not '$CHORD'."
  case "$(ask "Rebind kitty to $CHORD? [Y/n/q]" 'y')" in
    [Nn]*) warn "Leaving kitty binding at '$existing_kitty'." ;;
    [Qq]*) die "Aborted by user." ;;
    *)     write_kitty_binding ;;
  esac
fi

# ── Step 2: release Konsole's claim on Ctrl+Alt+T ────────────────────────────
# Konsole's default Ctrl+Alt+T lives in its shipped .desktop (X-KDE-Shortcuts),
# so the user file is usually empty for it even though the chord is effectively
# claimed. Setting _launch=none in the user file overrides that default.
disable_konsole_binding() {
  if dryrun; then
    info "[DRY-RUN] would run: kwriteconfig6 --file $SHORTCUTS_FILE --group services --group $KONSOLE_ID --key _launch none"
  else
    kwriteconfig6 --file "$SHORTCUTS_FILE" --group services --group "$KONSOLE_ID" --key _launch "none"
    info "Disabled Konsole's $CHORD binding ([services][$KONSOLE_ID] _launch=none)."
  fi
}

existing_konsole="$(kreadconfig6 --file "$SHORTCUTS_FILE" --group services --group "$KONSOLE_ID" --key _launch 2>/dev/null || echo '')"
if [ "$existing_konsole" = "none" ]; then
  info "Konsole's $CHORD already disabled — skipping."
elif [ -z "$existing_konsole" ]; then
  # Default state: Konsole claims Ctrl+Alt+T via its package .desktop. Override it.
  disable_konsole_binding
elif [ "$existing_konsole" = "$CHORD" ]; then
  # Konsole explicitly claims our chord in the user file — overwrite to none.
  warn "Konsole explicitly binds $CHORD; it will collide with kitty."
  case "$(ask "Disable Konsole's $CHORD? [Y/n/q]" 'y')" in
    [Nn]*) warn "Leaving Konsole bound to $CHORD (collision with kitty likely)." ;;
    [Qq]*) die "Aborted by user." ;;
    *)     disable_konsole_binding ;;
  esac
else
  # Konsole was deliberately moved to a different chord — not in our way.
  info "Konsole is bound to '$existing_konsole' (not $CHORD) — leaving it alone."
fi

# Spot-check: is Ctrl+Alt+T claimed by some OTHER service too?
existing_owners="$(awk '
  /^\[services\]\[/ { svc=$0; sub(/^\[services\]\[/,"",svc); sub(/\]$/,"",svc); next }
  /^_launch=/ {
    val=$0; sub(/^_launch=/,"",val);
    if (val == "'"$CHORD"'" && svc != "'"$KITTY_ID"'") print svc;
  }
' "$SHORTCUTS_FILE" 2>/dev/null || true)"
if [ -n "$existing_owners" ]; then
  warn "Other services also bind $CHORD; Plasma may surface a conflict:"
  while IFS= read -r owner; do
    [ -n "$owner" ] && printf '        %s\n' "$owner" >&2
  done <<< "$existing_owners"
fi

# ── Step 3: set kitty as KDE's default terminal application ───────────────────
write_default_terminal() {
  if dryrun; then
    info "[DRY-RUN] would run: kwriteconfig6 --file $KDEGLOBALS_FILE --group General --key TerminalApplication kitty"
    info "[DRY-RUN] would run: kwriteconfig6 --file $KDEGLOBALS_FILE --group General --key TerminalService kitty.desktop"
  else
    kwriteconfig6 --file "$KDEGLOBALS_FILE" --group General --key TerminalApplication "kitty"
    kwriteconfig6 --file "$KDEGLOBALS_FILE" --group General --key TerminalService "kitty.desktop"
    info "Set KDE default terminal to kitty ([General] TerminalApplication=kitty, TerminalService=kitty.desktop)."
  fi
}

cur_term_app="$(kreadconfig6 --file "$KDEGLOBALS_FILE" --group General --key TerminalApplication 2>/dev/null || echo '')"
cur_term_svc="$(kreadconfig6 --file "$KDEGLOBALS_FILE" --group General --key TerminalService 2>/dev/null || echo '')"
if [ "$cur_term_app" = "kitty" ] && [ "$cur_term_svc" = "kitty.desktop" ]; then
  info "KDE default terminal already kitty — skipping."
elif [ -z "$cur_term_app" ] && [ -z "$cur_term_svc" ]; then
  write_default_terminal
else
  warn "KDE default terminal currently: TerminalApplication='$cur_term_app' TerminalService='$cur_term_svc'."
  case "$(ask "Set default terminal to kitty? [Y/n/q]" 'y')" in
    [Nn]*) warn "Leaving KDE default terminal unchanged." ;;
    [Qq]*) die "Aborted by user." ;;
    *)     write_default_terminal ;;
  esac
fi

# ── Step 4: best-effort reload of the global-shortcut daemon ──────────────────
# Only the kglobalshortcutsrc changes (steps 1-2) need a reload; the kdeglobals
# change (step 3) is read live on each launch.
if dryrun; then
  info "[DRY-RUN] would restart plasma-kded6.service / kded6 (hosts the global shortcut daemon)"
else
  if command -v systemctl >/dev/null \
     && systemctl --user list-unit-files plasma-kded6.service >/dev/null 2>&1 \
     && systemctl --user is-active --quiet plasma-kded6.service \
     && systemctl --user restart plasma-kded6.service >/dev/null 2>&1; then
    info "Restarted plasma-kded6.service via systemctl --user."
  elif command -v kquitapp6 >/dev/null && pgrep -x kded6 >/dev/null; then
    info "Restarting kded6 (hosts the global shortcut daemon in Plasma 6)..."
    kquitapp6 kded6 >/dev/null 2>&1 || warn "kquitapp6 kded6 failed; continuing."
    sleep 1
    if ! pgrep -x kded6 >/dev/null; then
      if command -v kded6 >/dev/null; then
        (kded6 &) >/dev/null 2>&1
        info "Re-spawned kded6."
      else
        warn "kded6 did not respawn and no binary in PATH. You may need to log out and back in."
      fi
    else
      info "kded6 came back automatically."
    fi
  else
    warn "kded6 not running; nothing to restart. Log out and back in to apply the shortcut."
  fi
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
if dryrun; then
  info "Dry run complete. No changes were made."
else
  info "Done. $CHORD now launches kitty, and kitty is KDE's default terminal."
  info "If $CHORD still opens Konsole: log out and back in (or restart Plasma)"
  info "  to force the global-shortcut daemon to reload."
fi
