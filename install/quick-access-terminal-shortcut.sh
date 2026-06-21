#!/usr/bin/env bash
# install/quick-access-terminal-shortcut.sh — Bind Meta+Return to kitten's quick-access drop-down terminal
#
# What this does:
#   1. Drops a NoDisplay .desktop file at
#        ~/.local/share/applications/kitten-quick-access-terminal.desktop
#      with Exec=kitten quick-access-terminal. NoDisplay keeps it out of
#      the app launcher; it exists only as a hook for the global shortcut.
#   2. Writes a global shortcut binding under
#        [services][kitten-quick-access-terminal.desktop] _launch=Meta+Return
#      into ~/.config/kglobalshortcutsrc via kwriteconfig6. Plasma 6's
#      "custom command shortcut" mechanism reads exactly this format —
#      verified by inspecting the existing [services][kitty.desktop] _launch=Ctrl+Alt+T
#      entry on this machine.
#   3. Best-effort reload: restarts kded6 (which hosts the global shortcut
#      daemon as a plugin in Plasma 6 — there is no standalone kglobalacceld
#      binary). NOTE: this reload step is best-effort and was NOT verified
#      end-to-end before this script shipped. If Meta+Return doesn't fire
#      after running, log out and back in.
#
# Idempotency / collision handling:
#   - If the .desktop file already exists with the expected Exec line,
#     leave it alone. If it exists with different content, prompt (or
#     overwrite under --no-prompt).
#   - If kglobalshortcutsrc already has _launch=Meta+Return for this
#     desktop file, do nothing. If it has a DIFFERENT chord for this
#     desktop file, prompt (or overwrite under --no-prompt).
#   - If a DIFFERENT desktop entry is already bound to Meta+Return,
#     warn but proceed — Plasma may resolve the conflict at runtime.
#
# Usage:
#   ./install/quick-access-terminal-shortcut.sh             # interactive
#   ./install/quick-access-terminal-shortcut.sh --no-prompt # idempotent, overwrites collisions
#   ./install/quick-access-terminal-shortcut.sh --dry-run   # show, change nothing
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

command -v kitten         >/dev/null || die "kitten not found (ships with kitty). Install kitty first."
command -v kwriteconfig6  >/dev/null || die "kwriteconfig6 not found. Install kf6-kconfig (Fedora package)."
command -v kreadconfig6   >/dev/null || die "kreadconfig6 not found. Install kf6-kconfig (Fedora package)."

DESKTOP_ID="kitten-quick-access-terminal.desktop"
DESKTOP_FILE="$HOME/.local/share/applications/$DESKTOP_ID"
SHORTCUTS_FILE="$HOME/.config/kglobalshortcutsrc"
CHORD="Meta+Return"

dryrun && warn "Running in --dry-run mode; no changes will be made."

# ── Step 1: .desktop file ────────────────────────────────────────────────────
DESKTOP_CONTENT='[Desktop Entry]
Version=1.0
Type=Application
Name=kitty Quick-Access Terminal
GenericName=Drop-down terminal
Comment=Quake-style drop-down kitty terminal for one-off commands
TryExec=kitten
StartupNotify=false
Exec=kitten quick-access-terminal
Icon=kitty
Categories=System;TerminalEmulator;
NoDisplay=true'

write_desktop() {
  mkdir -p "$(dirname "$DESKTOP_FILE")"
  if dryrun; then
    info "[DRY-RUN] would write $DESKTOP_FILE with Exec=kitten quick-access-terminal"
  else
    printf '%s\n' "$DESKTOP_CONTENT" > "$DESKTOP_FILE"
    info "Wrote $DESKTOP_FILE"
  fi
}

if [ -e "$DESKTOP_FILE" ]; then
  existing="$(cat "$DESKTOP_FILE")"
  if [ "$existing" = "$DESKTOP_CONTENT" ]; then
    info ".desktop file already up-to-date — skipping."
  else
    warn "$DESKTOP_FILE exists but content differs from expected."
    case "$(ask "Overwrite? [y/N/q]" 'y')" in
      [Yy]*) write_desktop ;;
      [Qq]*) die "Aborted by user." ;;
      *)     warn "Leaving $DESKTOP_FILE unchanged (binding may not work)." ;;
    esac
  fi
else
  write_desktop
fi

# ── Step 2: kglobalshortcutsrc binding ───────────────────────────────────────
existing_chord="$(kreadconfig6 --file "$SHORTCUTS_FILE" --group services --group "$DESKTOP_ID" --key _launch 2>/dev/null || echo '')"

write_binding() {
  if dryrun; then
    info "[DRY-RUN] would run: kwriteconfig6 --file $SHORTCUTS_FILE --group services --group $DESKTOP_ID --key _launch $CHORD"
  else
    kwriteconfig6 --file "$SHORTCUTS_FILE" --group services --group "$DESKTOP_ID" --key _launch "$CHORD"
    info "Wrote [services][$DESKTOP_ID] _launch=$CHORD to $SHORTCUTS_FILE"
  fi
}

if [ "$existing_chord" = "$CHORD" ]; then
  info "Shortcut binding already at $CHORD — skipping."
elif [ -z "$existing_chord" ]; then
  write_binding
else
  warn "Existing binding for $DESKTOP_ID is '$existing_chord', not '$CHORD'."
  case "$(ask "Overwrite with $CHORD? [Y/n/q]" 'y')" in
    [Nn]*) warn "Leaving existing binding '$existing_chord'." ;;
    [Qq]*) die "Aborted by user." ;;
    *)     write_binding ;;
  esac
fi

# Spot-check: is Meta+Return already claimed by something else? Scan the
# file for ANY _launch entry matching this chord and warn.
existing_owners="$(awk '
  /^\[services\]\[/ { svc=$0; sub(/^\[services\]\[/,"",svc); sub(/\]$/,"",svc); next }
  /^_launch=/ {
    val=$0; sub(/^_launch=/,"",val);
    if (val == "'"$CHORD"'" && svc != "'"$DESKTOP_ID"'") print svc;
  }
' "$SHORTCUTS_FILE" 2>/dev/null || true)"
if [ -n "$existing_owners" ]; then
  warn "Other services also bind $CHORD; Plasma may surface a conflict:"
  while IFS= read -r owner; do
    [ -n "$owner" ] && printf '        %s\n' "$owner" >&2
  done <<< "$existing_owners"
fi

# ── Step 3: Best-effort reload ───────────────────────────────────────────────
if dryrun; then
  info "[DRY-RUN] would restart kded6 (which hosts the global shortcut daemon)"
else
  # Prefer letting systemd's user manager bounce the unit (newer Plasma 6
  # setups run kded6 as plasma-kded6.service). Only take this path when the
  # unit actually exists AND is active: `try-restart` exits 0 even when the
  # unit isn't loaded, which would otherwise swallow the kquitapp6 fallback
  # below and report a restart that never happened.
  if command -v systemctl >/dev/null \
     && systemctl --user list-unit-files plasma-kded6.service >/dev/null 2>&1 \
     && systemctl --user is-active --quiet plasma-kded6.service \
     && systemctl --user restart plasma-kded6.service >/dev/null 2>&1; then
    info "Restarted plasma-kded6.service via systemctl --user."
  elif command -v kquitapp6 >/dev/null && pgrep -x kded6 >/dev/null; then
    info "Restarting kded6 (hosts the global shortcut daemon in Plasma 6)..."
    kquitapp6 kded6 >/dev/null 2>&1 || warn "kquitapp6 kded6 failed; continuing."
    # kded6 is started by Plasma's session manager (systemd user units in
    # newer setups, plasma-startup in older). Letting it respawn naturally
    # is more reliable than re-exec from here.
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
    warn "kded6 not running; nothing to restart."
  fi
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
if dryrun; then
  info "Dry run complete. No changes were made."
else
  info "Installed. Press $CHORD to summon the quick-access terminal."
  info "If the chord does not fire immediately: log out and back in (or"
  info "  restart Plasma) to force the global shortcut daemon to reload."
  info ""
  info "To customize the quick-access window (size, position, opacity),"
  info "  create ~/.config/kitty/quick-access-terminal.conf — see"
  info "  'kitten quick-access-terminal --help' for available options."
fi
