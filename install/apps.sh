#!/usr/bin/env bash
# apps.sh
# Orchestrate the manually-curated application set: run the seven install
# scripts in order (NVIDIA driver intentionally excluded — it is
# workstation-specific; see docs/specs/2026-06-03-reproduce-manual-apps-design.md).
# Each child script keeps its own prompting, --dry-run preview, and idempotency;
# this orchestrator only sequences them and gates each step.
#
# Usage:
#   ./apps.sh                 # confirm before each step
#   ./apps.sh --dry-run       # preview (passed to children)
#   ./apps.sh --no-prompt     # run all 7, no gating
#
# Why no auto-sudo here: uv, claude, and rmapi children refuse to run as root;
# docker/chrome/mullvad/node children self-elevate when they need root.
# Running this orchestrator under sudo would break the user-level installs.

set -euo pipefail

# ── Flag parsing ──────────────────────────────────────────────────────────────
_DRY_RUN=0
_pass_through=()        # flags forwarded to every child
for _arg in "$@"; do
  case "$_arg" in
    --no-prompt)   export RUNTOOLS_AS_NONINTERACTIVE=1 ;;
    --dry-run)     _DRY_RUN=1; _pass_through+=("--dry-run") ;;
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
  echo "  The user-level steps (uv, claude) write into \$HOME and refuse to run"
  echo "  as root; docker/chrome/mullvad/node self-elevate when they need root."
  exit 1
fi

# ── The sequence (NVIDIA driver intentionally excluded) ───────────────────────
_steps=(
  "docker.sh"
  "chrome.sh"
  "mullvad.sh"
  "flatpaks.sh"
  "node-and-npm-globals.sh"
  "uv.sh"
  "claude.sh"
  "rmapi.sh"
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

echo "install-apps — $(hostname -s)"
echo "  Will run ${#_steps[@]} scripts in order. NVIDIA driver is skipped"
echo "  (workstation-specific; see docs/specs/2026-06-03-reproduce-manual-apps-design.md)."
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

  # Run the child; a non-zero exit is treated as critical (later steps may
  # depend on earlier ones — e.g. npm globals need node installed first).
  _rc=0
  "$_SCRIPT_DIR/$_s" "${_pass_through[@]}" || _rc=$?
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
echo "install-apps complete: $_ran run, $_skipped skipped, of $_total."
exit 0
