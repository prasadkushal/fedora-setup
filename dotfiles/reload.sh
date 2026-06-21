#!/usr/bin/env bash
# dotfiles/reload.sh — Pull the dotfiles repo from remote, reconcile
#                                  divergence, then re-deploy symlinks.
#
# What this does (the "reload" idiom: fetch remote first, then apply):
#   1. Fetches the dotfiles repo's remote and reports exactly what diverged
#      (incoming remote commits, local-only commits, uncommitted changes).
#   2. Reconciles the divergence. Because ~/.zshrc etc. are SYMLINKS into this
#      repo (see dotfiles/deploy.sh), updating the repo updates
#      your live config in place — no copy step needed.
#   3. Re-runs the deploy script so any NEWLY-ADDED dotfiles get symlinked too.
#
# Reconciliation choices (interactive — shown when the repo has diverged):
#   1) Replace local with remote  — git reset --hard <upstream> (DISCARDS
#                                    uncommitted changes + local-only commits)
#   2) Keep local, ignore remote  — skip the pull; run with what you have
#   3) Commit & push local first  — commit dirty tree, rebase on remote, push,
#                                    leaving local and remote identical
#
# Non-interactive (--no-prompt / non-TTY): "pull only if clean" — fast-forward
#   to the remote when the working tree is clean and not ahead; otherwise abort
#   without touching anything (exit 2) so no local work is ever lost unattended.
#
# Usage:
#   ./dotfiles/reload.sh                       # interactive 3-way
#   ./dotfiles/reload.sh --no-prompt           # ff-if-clean, else abort
#   ./dotfiles/reload.sh --dry-run             # show, change nothing
#   ./dotfiles/reload.sh --skip-deploy         # pull only, no symlink refresh
#   ./dotfiles/reload.sh --dotfiles-dir <path> # override repo location
#
# No sudo: everything happens inside the dotfiles repo and your $HOME.

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
DOTFILES_DIR="$HOME/projects/repos/dotfiles"
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Flag parsing ─────────────────────────────────────────────────────────────
_DRY_RUN=0
_SKIP_DEPLOY=0
_PASS_THROUGH=()
while [ $# -gt 0 ]; do
  case "$1" in
    --no-prompt)      export RUNTOOLS_AS_NONINTERACTIVE=1; _PASS_THROUGH+=("--no-prompt") ;;
    --dry-run)        _DRY_RUN=1; _PASS_THROUGH+=("--dry-run") ;;
    --skip-deploy)    _SKIP_DEPLOY=1 ;;
    --dotfiles-dir)   DOTFILES_DIR="$2"; shift ;;
    --dotfiles-dir=*) DOTFILES_DIR="${1#--dotfiles-dir=}" ;;
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

# Run git inside the dotfiles repo regardless of cwd.
g() { git -C "$DOTFILES_DIR" "$@"; }

run_deploy() {
  if [ "$_SKIP_DEPLOY" -eq 1 ]; then
    info "Skipping symlink refresh (--skip-deploy)."
    return
  fi
  local deploy="$_SCRIPT_DIR/deploy.sh"
  if [ ! -x "$deploy" ]; then
    warn "Deploy script not found at $deploy — skipping symlink refresh."
    warn "Any newly-added dotfiles won't be linked until you run it manually."
    return
  fi
  echo ""
  info "Refreshing symlinks (new files get linked; correct ones skip silently)..."
  "$deploy" "${_PASS_THROUGH[@]}" --dotfiles-dir "$DOTFILES_DIR"
}

do_fast_forward() {
  if dryrun; then
    info "[DRY-RUN] would run: git merge --ff-only $_UPSTREAM"
    return
  fi
  g merge --ff-only "$_UPSTREAM" || die "Fast-forward failed. Resolve manually in $DOTFILES_DIR."
  info "Fast-forwarded to $_UPSTREAM."
}

reconcile_replace() {
  if [ "$_DIRTY" -eq 1 ] || [ "$_AHEAD" -gt 0 ]; then
    local lose=""
    [ "$_DIRTY" -eq 1 ] && lose="uncommitted changes"
    [ "$_AHEAD" -gt 0 ] && lose="${lose:+$lose and }$_AHEAD local-only commit(s)"
    warn "This will DISCARD: $lose."
    case "$(ask 'Are you sure? [y/N]' 'n')" in
      [Yy]*) ;;
      *) die "Aborted; nothing changed." ;;
    esac
  fi
  if dryrun; then
    info "[DRY-RUN] would run: git reset --hard $_UPSTREAM"
    return
  fi
  g reset --hard "$_UPSTREAM"
  info "Local now matches $_UPSTREAM."
}

reconcile_push() {
  if [ "$_DIRTY" -eq 1 ]; then
    local default_msg msg
    default_msg="dotfiles: sync from $(hostname -s) $(date +%Y-%m-%dT%H%M)"
    if [ "${RUNTOOLS_AS_NONINTERACTIVE:-0}" = "1" ]; then
      msg="$default_msg"
    else
      read -r -p "  Commit message [$default_msg]: " msg || msg=""
      msg="${msg:-$default_msg}"
    fi
    if dryrun; then
      info "[DRY-RUN] would run: git add -A && git commit -m \"$msg\""
    else
      g add -A
      g commit -m "$msg"
      info "Committed local changes."
    fi
  fi
  if [ "$_BEHIND" -gt 0 ]; then
    if dryrun; then
      info "[DRY-RUN] would run: git rebase $_UPSTREAM"
    else
      if ! g rebase "$_UPSTREAM"; then
        g rebase --abort 2>/dev/null || true
        die "Rebase onto $_UPSTREAM hit conflicts. Resolve manually in $DOTFILES_DIR, then re-run."
      fi
      info "Rebased local commits on top of $_UPSTREAM."
    fi
  fi
  if dryrun; then
    info "[DRY-RUN] would run: git push"
  else
    g push || die "git push failed. Resolve and retry."
    info "Pushed to $_UPSTREAM. Local and remote are in sync."
  fi
}

# ── Pre-flight ───────────────────────────────────────────────────────────────
[ "$EUID" -eq 0 ] && die "Don't run this as root — it operates on your \$HOME dotfiles repo."
[ -d "$DOTFILES_DIR" ] || die "Dotfiles dir '$DOTFILES_DIR' not found. Pass --dotfiles-dir=<path> to override."
DOTFILES_DIR="$(cd "$DOTFILES_DIR" && pwd)"
[ -d "$DOTFILES_DIR/.git" ] || die "$DOTFILES_DIR is not a git repo."
g rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1 \
  || die "No upstream tracking branch for $(g rev-parse --abbrev-ref HEAD). Set one: git -C $DOTFILES_DIR branch --set-upstream-to=origin/<branch>"

_BRANCH="$(g rev-parse --abbrev-ref HEAD)"
_UPSTREAM="$(g rev-parse --abbrev-ref '@{u}')"

dryrun && warn "Running in --dry-run mode; no changes will be made (a read-only git fetch still refreshes remote-tracking refs)."

# ── Fetch (read-only: updates remote-tracking refs only, never your work) ─────
info "Fetching $_UPSTREAM ..."
g fetch --prune || die "git fetch failed (network?). Aborting; nothing changed."

# ── Compute divergence ───────────────────────────────────────────────────────
_DIRTY=0
[ -n "$(g status --porcelain)" ] && _DIRTY=1
read -r _AHEAD _BEHIND < <(g rev-list --left-right --count "HEAD...$_UPSTREAM")

echo ""
info "Repo:     $DOTFILES_DIR"
info "Branch:   $_BRANCH → $_UPSTREAM"
info "Ahead:    $_AHEAD commit(s) local-only"
info "Behind:   $_BEHIND commit(s) on remote"
info "Worktree: $([ "$_DIRTY" -eq 1 ] && echo 'DIRTY (uncommitted changes)' || echo 'clean')"
if [ "$_BEHIND" -gt 0 ]; then
  echo ""; info "Incoming from remote:"
  g --no-pager log --oneline "HEAD..$_UPSTREAM" | sed 's/^/    /'
fi
if [ "$_AHEAD" -gt 0 ]; then
  echo ""; info "Local-only commits:"
  g --no-pager log --oneline "$_UPSTREAM..HEAD" | sed 's/^/    /'
fi
if [ "$_DIRTY" -eq 1 ]; then
  echo ""; info "Uncommitted changes:"
  g status --short | sed 's/^/    /'
fi
echo ""

# ── Already in sync ──────────────────────────────────────────────────────────
if [ "$_DIRTY" -eq 0 ] && [ "$_AHEAD" -eq 0 ] && [ "$_BEHIND" -eq 0 ]; then
  info "Already in sync with $_UPSTREAM — nothing to pull."
  run_deploy
  exit 0
fi

# ── Non-interactive: pull only if clean, else abort untouched ────────────────
if [ "${RUNTOOLS_AS_NONINTERACTIVE:-0}" = "1" ]; then
  if [ "$_DIRTY" -eq 0 ] && [ "$_AHEAD" -eq 0 ]; then
    [ "$_BEHIND" -gt 0 ] && do_fast_forward || info "Nothing to fast-forward."
    run_deploy
    exit 0
  fi
  warn "Diverged from remote (dirty=$_DIRTY, ahead=$_AHEAD) and running non-interactively."
  warn "Refusing to auto-pull so no local work is lost. Re-run interactively to reconcile:"
  warn "    $0 --dotfiles-dir $DOTFILES_DIR"
  exit 2
fi

# ── Interactive 3-way reconciliation ─────────────────────────────────────────
echo "How do you want to reconcile?"
echo "  1) Replace local with remote   (git reset --hard $_UPSTREAM — DISCARDS uncommitted + local-only commits)"
echo "  2) Keep local, ignore remote   (skip the pull; run with what you have)"
echo "  3) Commit & push local first   (commit dirty tree, rebase on remote, push)"
case "$(ask 'Choice [1/2/3/q]' '2')" in
  1)     reconcile_replace ;;
  2)     info "Keeping local as-is; not pulling." ;;
  3)     reconcile_push ;;
  [Qq]*) die "Aborted by user." ;;
  *)     die "Unrecognized choice. Aborting (nothing changed)." ;;
esac

run_deploy

echo ""
if dryrun; then
  info "Dry run complete. No changes were made."
else
  info "Reload complete."
fi
