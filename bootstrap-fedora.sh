#!/usr/bin/env bash
# bootstrap-fedora.sh
# Orchestrate the fresh-machine bootstrap: run the five user-level setup
# scripts in the documented order (NVIDIA driver intentionally excluded — it
# is workstation-specific; see USAGI.md). Each child script keeps its own
# prompting, --dry-run preview, and idempotency; this orchestrator only
# sequences them and gates each step.
#
# Usage:
#   ./bootstrap-fedora.sh                 # confirm before each step
#   ./bootstrap-fedora.sh --dry-run       # preview (passed to children)
#   ./bootstrap-fedora.sh --no-prompt     # run all 5, no gating
#   ./bootstrap-fedora.sh --dotfiles-dir ~/projects/repos/dotfiles
#
# Why no auto-sudo here: only modern-cli-tools needs root and it re-execs
# under sudo itself. The other four create files in the invoking user's HOME;
# running this orchestrator under sudo would root-own them. So we run as the
# user and let each child elevate as needed.

set -euo pipefail

# ── Flag parsing ──────────────────────────────────────────────────────────────
_DRY_RUN=0
_DOTFILES_DIR=""
_pass_through=()        # flags forwarded to every child
for _arg in "$@"; do
  case "$_arg" in
    --no-prompt)   export RUNTOOLS_AS_NONINTERACTIVE=1 ;;
    --dry-run)     _DRY_RUN=1; _pass_through+=("--dry-run") ;;
    --dotfiles-dir=*) _DOTFILES_DIR="${_arg#*=}" ;;
    -h|--help)
      sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "⚠ unknown argument: $_arg" >&2; exit 1 ;;
  esac
done

# Auto-detect scheduled/non-TTY execution
[ -t 1 ] || export RUNTOOLS_AS_NONINTERACTIVE=1

# Forward --no-prompt to children whenever we are non-interactive
[ "${RUNTOOLS_AS_NONINTERACTIVE:-0}" = "1" ] && _pass_through+=("--no-prompt")

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Guard: do not run as root ─────────────────────────────────────────────────
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
  echo "✗ Run this as your normal user, not root."
  echo "  The user-level steps (starship, zsh plugins, dotfiles, shell config)"
  echo "  write into \$HOME; modern-cli-tools elevates itself when it needs root."
  exit 1
fi

# ── The sequence (NVIDIA driver intentionally excluded) ───────────────────────
# Steps 4 and 5 also accept --dotfiles-dir; it is appended for those only.
_steps=(
  "install/modern-cli-tools.sh"
  "install/starship.sh"
  "install/zsh-plugins.sh"
  "dotfiles/deploy.sh"
  "configure/shell-to-zsh.sh"
)

# ── Dependency check: every child must exist and be executable ────────────────
_missing=0
for _s in "${_steps[@]}"; do
  if [ ! -x "$_SCRIPT_DIR/$_s" ]; then
    echo "✗ missing or non-executable: $_s"
    _missing=1
  fi
done
[ "$_missing" -eq 1 ] && { echo "  Cannot proceed — fix the above and re-run."; exit 1; }

echo "fedora bootstrap — $(hostname -s)"
echo "  Will run ${#_steps[@]} scripts in order. NVIDIA driver is skipped"
echo "  (workstation-specific; see USAGI.md)."
[ "$_DRY_RUN" -eq 1 ] && echo "  DRY-RUN: children invoked with --dry-run (no changes)."
echo ""

# ── Run loop ──────────────────────────────────────────────────────────────────
_total="${#_steps[@]}"
_ran=0; _skipped=0; _i=0
for _s in "${_steps[@]}"; do
  _i=$((_i + 1))

  # Per-step gate (auto-proceed when non-interactive)
  if [ "${RUNTOOLS_AS_NONINTERACTIVE:-0}" = "1" ]; then
    echo "[$_i/$_total] $_s — running (no-prompt)"
  else
    read -r -t 30 -p "[$_i/$_total] $_s — run? [Y/n/abort] (auto-Y in 30s): " _ans || _ans="Y"
    case "${_ans:-Y}" in
      [Nn]*)            echo "  skipped."; _skipped=$((_skipped + 1)); continue ;;
      [Aa]bort|[Aa])    echo "  aborted at step $_i/$_total."; exit 3 ;;
    esac
  fi

  # Assemble args: common pass-through + --dotfiles-dir for the two that take it
  _args=("${_pass_through[@]}")
  if [ -n "$_DOTFILES_DIR" ] && \
     { [ "$_s" = "dotfiles/deploy.sh" ] || \
       [ "$_s" = "configure/shell-to-zsh.sh" ]; }; then
    _args+=("--dotfiles-dir" "$_DOTFILES_DIR")
  fi

  # Run the child; a non-zero exit is treated as critical (later steps build on
  # earlier ones — e.g. configure-shell expects dotfiles already deployed).
  _rc=0
  "$_SCRIPT_DIR/$_s" "${_args[@]}" || _rc=$?
  if [ "$_rc" -ne 0 ]; then
    echo "✗ [$_i/$_total] $_s failed (exit $_rc)."
    if [ "${RUNTOOLS_AS_NONINTERACTIVE:-0}" = "1" ]; then
      echo "  Aborting (non-interactive)."
      exit 1
    fi
    read -r -t 30 -p "  Continue with remaining steps anyway? [y/N] (auto-N in 30s): " _c || _c="N"
    case "${_c:-N}" in
      [Yy]*) echo "  continuing despite failure." ;;
      *)     echo "  aborting."; exit 1 ;;
    esac
  fi
  _ran=$((_ran + 1))
done

echo ""
echo "bootstrap complete: $_ran run, $_skipped skipped, of $_total."
echo "  Next: verify per USAGI.md Step 4, then handle the out-of-scope items"
echo "  (Tailscale, backup enrollment, credentials)."
exit 0
