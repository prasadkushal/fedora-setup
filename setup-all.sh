#!/usr/bin/env bash
# setup-all.sh — One-shot, idempotent setup of a fresh Fedora machine
#
# What this does:
#   Composes the repo's two orchestrators plus the optional installers into a
#   single entry point. Every child is idempotent, so re-running is safe; this
#   script only sequences them — each child keeps its own prompts, --dry-run
#   preview, and auto-sudo.
#
#   CORE (always run):
#     1. bootstrap-fedora.sh  — shell environment (modern CLI tools
#        + kitty, starship, zsh plugins, deploy dotfiles, switch to zsh)
#     2. install/apps.sh       — applications (docker, chrome,
#        mullvad, flatpaks, node+npm globals, uv, claude)
#
#   OPTIONAL (interactive: prompted per item, default No; --no-prompt: skipped):
#     3. install/vscode.sh
#     4. install/tailscale.sh                       (needs login)
#     5. configure/ssh-server.sh                    (remote shell)
#     6. configure/rdp-server.sh                    (KDE only)
#     7. configure/xrdp-fallback.sh                 (:3390 fallback)
#     8. configure/remote-access-firewall.sh        (restrict sources)
#     9. install/quick-access-terminal-shortcut.sh  (KDE only)
#    10. configure/default-terminal.sh              (KDE only)
#
#   HARDWARE-SPECIFIC (only with --with-nvidia — NEVER automatic):
#    11. install/nvidia-driver.sh  — DO NOT run on non-NVIDIA
#        hardware (e.g. the AMD mini-PC). It blacklists nouveau for a Blackwell
#        GPU and would be wrong elsewhere.
#
# Usage:
#   ./setup-all.sh                  # core + prompt for each optional
#   ./setup-all.sh --dry-run        # preview everything, change nothing
#   ./setup-all.sh --no-prompt      # core only, optionals skipped
#   ./setup-all.sh --with-nvidia    # also install the NVIDIA driver
#   ./setup-all.sh --dotfiles-dir=~/projects/dotfiles
#
# Why no auto-sudo here: each child elevates itself when it needs root, and the
# user-level children (bootstrap, uv, claude) refuse to run as root. So this
# runs as your normal user.

set -euo pipefail

# ── Flag parsing ──────────────────────────────────────────────────────────────
_DRY_RUN=0
_WITH_NVIDIA=0
_DOTFILES_DIR=""
_pass_through=()        # flags forwarded to every child
for _arg in "$@"; do
  case "$_arg" in
    --no-prompt)      export RUNTOOLS_AS_NONINTERACTIVE=1 ;;
    --dry-run)        _DRY_RUN=1; _pass_through+=("--dry-run") ;;
    --with-nvidia)    _WITH_NVIDIA=1 ;;
    --dotfiles-dir=*) _DOTFILES_DIR="${_arg#*=}" ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *)
      echo "Unknown argument: $_arg" >&2
      echo "Run '$0 --help' for usage." >&2
      exit 64 ;;
  esac
done

# Auto-detect scheduled/non-TTY execution → behave non-interactively.
[ -t 1 ] || export RUNTOOLS_AS_NONINTERACTIVE=1
# Forward --no-prompt to children whenever we are non-interactive.
[ "${RUNTOOLS_AS_NONINTERACTIVE:-0}" = "1" ] && _pass_through+=("--no-prompt")

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Helpers ───────────────────────────────────────────────────────────────────
info() { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*"; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

# KDE? (for the quick-access terminal shortcut, which targets kded6/kglobalshortcutsrc)
_is_kde() {
  case "${XDG_CURRENT_DESKTOP:-}" in *KDE*) return 0 ;; esac
  command -v kwriteconfig6 >/dev/null 2>&1
}

# Run a child script (relative to _SCRIPT_DIR) with the given args. Missing/
# non-executable children are warned and skipped (non-fatal); the caller decides
# how to treat a non-zero exit from the child itself.
_run_child() {
  local label="$1" script="$2"; shift 2
  if [ ! -x "$_SCRIPT_DIR/$script" ]; then
    warn "[$label] missing or not executable: $script — skipping."
    return 0
  fi
  echo ""
  info "==> $label  ($script)"
  local rc=0
  "$_SCRIPT_DIR/$script" "$@" || rc=$?
  return "$rc"
}

# Gate an optional step. Returns 0 to run, 1 to skip. Unattended → always skip.
_ask_optional() {
  local label="$1" ans
  if [ "${RUNTOOLS_AS_NONINTERACTIVE:-0}" = "1" ]; then
    info "(optional skipped — unattended): $label"
    return 1
  fi
  read -r -t 30 -p "Run optional step '$label'? [y/N] (auto-N in 30s): " ans || ans="N"
  case "${ans:-N}" in
    [Yy]*) return 0 ;;
    *)     info "skipped: $label"; return 1 ;;
  esac
}

# ── Guard: do not run as root ─────────────────────────────────────────────────
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
  die "Run as your normal user, not root. Each child elevates itself when it needs root; the user-level children refuse to run as root."
fi

# ── Dependency check: the two CORE scripts must exist ─────────────────────────
for _s in bootstrap-fedora.sh install/apps.sh; do
  [ -x "$_SCRIPT_DIR/$_s" ] || die "Missing or non-executable core script: $_s — cannot proceed."
done

echo "fedora setup-all — $(hostname -s)"
[ "$_DRY_RUN" -eq 1 ] && info "DRY-RUN: children invoked with --dry-run (no changes)."
[ "${RUNTOOLS_AS_NONINTERACTIVE:-0}" = "1" ] && info "Non-interactive: optionals will be skipped."

_optional_failed=0

# ── CORE (always) ─────────────────────────────────────────────────────────────
_bootstrap_args=("${_pass_through[@]}")
[ -n "$_DOTFILES_DIR" ] && _bootstrap_args+=("--dotfiles-dir=$_DOTFILES_DIR")
_run_child "Shell environment" "bootstrap-fedora.sh" "${_bootstrap_args[@]}" \
  || die "Core step 'Shell environment' failed; aborting. Fix the above and re-run — it's idempotent."
_run_child "Applications" "install/apps.sh" "${_pass_through[@]}" \
  || die "Core step 'Applications' failed; aborting. Fix the above and re-run — it's idempotent."

# ── OPTIONAL (gated; skipped when unattended) ─────────────────────────────────
if _ask_optional "VS Code"; then
  _run_child "VS Code" "install/vscode.sh" "${_pass_through[@]}" \
    || { warn "VS Code step failed (continuing)."; _optional_failed=1; }
fi

if _ask_optional "Tailscale (remote access; prints a login URL)"; then
  _run_child "Tailscale" "install/tailscale.sh" "${_pass_through[@]}" \
    || { warn "Tailscale step failed (continuing)."; _optional_failed=1; }
fi

if _ask_optional "SSH server (enable sshd for remote shell access)"; then
  _run_child "SSH server" "configure/ssh-server.sh" "${_pass_through[@]}" \
    || { warn "SSH server step failed (continuing)."; _optional_failed=1; }
fi

if _is_kde; then
  if _ask_optional "RDP server (KDE krdp; share the desktop session)"; then
    _run_child "RDP server" "configure/rdp-server.sh" "${_pass_through[@]}" \
      || { warn "RDP server step failed (continuing)."; _optional_failed=1; }
  fi
else
  info "(not a KDE session — skipping the krdp RDP server)"
fi

if _ask_optional "XRDP fallback (:3390 separate session for post-WoL/pre-login GUI; creates a fallback user)"; then
  _run_child "XRDP fallback" "configure/xrdp-fallback.sh" "${_pass_through[@]}" \
    || { warn "XRDP fallback step failed (continuing)."; _optional_failed=1; }
fi

if _ask_optional "Remote-access firewall (restrict ssh/rdp/3390 to Users VLAN + Tailscale)"; then
  _run_child "Remote-access firewall" "configure/remote-access-firewall.sh" "${_pass_through[@]}" \
    || { warn "Remote-access firewall step failed (continuing)."; _optional_failed=1; }
fi

if _is_kde; then
  if _ask_optional "KDE quick-access terminal shortcut (Meta+Return)"; then
    _run_child "Quick-access shortcut" "install/quick-access-terminal-shortcut.sh" "${_pass_through[@]}" \
      || { warn "Quick-access step failed (continuing)."; _optional_failed=1; }
  fi
else
  info "(not a KDE session — skipping the quick-access terminal shortcut)"
fi

if _is_kde; then
  if _ask_optional "KDE default terminal = kitty (Ctrl+Alt+T → kitty, replaces Konsole)"; then
    _run_child "Default terminal" "configure/default-terminal.sh" "${_pass_through[@]}" \
      || { warn "Default terminal step failed (continuing)."; _optional_failed=1; }
  fi
else
  info "(not a KDE session — skipping the default-terminal config)"
fi

# ── HARDWARE-SPECIFIC (explicit opt-in only) ──────────────────────────────────
if [ "$_WITH_NVIDIA" -eq 1 ]; then
  warn "Installing the NVIDIA driver (--with-nvidia). This is correct ONLY on NVIDIA hardware."
  _run_child "NVIDIA driver" "install/nvidia-driver.sh" "${_pass_through[@]}" \
    || { warn "NVIDIA step failed (continuing)."; _optional_failed=1; }
else
  info "(NVIDIA driver not requested — pass --with-nvidia to include it; NVIDIA hardware only)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [ "$_DRY_RUN" -eq 1 ]; then
  info "Dry run complete. No changes were made."
elif [ "$_optional_failed" -eq 1 ]; then
  warn "Setup finished, but one or more OPTIONAL steps failed (see above). Core completed successfully."
  exit 2
else
  info "Setup complete."
fi
