#!/usr/bin/env bash
# install/vscode.sh — Install Visual Studio Code via Microsoft's RPM repo
#
# What this does:
#   1. Imports Microsoft's GPG signing key into the RPM keyring.
#   2. Writes /etc/yum.repos.d/vscode.repo pointing at the Microsoft yum repo.
#   3. Installs the `code` package via dnf.
#
# Each step is idempotent: if state already matches what the script would
# produce, the step is skipped silently. If state differs, you're prompted
# (interactive mode, default), or the existing state is overwritten with a
# timestamped backup (--no-prompt / RUNTOOLS_AS_NONINTERACTIVE=1).
#
# Usage:
#   ./install/vscode.sh                # interactive
#   ./install/vscode.sh --no-prompt    # non-interactive, idempotent
#   ./install/vscode.sh --dry-run      # show what would happen, change nothing

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

# Read a one-character answer with a 30s timeout. Echoes the chosen char.
# In non-interactive mode, echoes the default without prompting.
ask() {
  local prompt="$1" default="$2" answer
  if [ "${RUNTOOLS_AS_NONINTERACTIVE:-0}" = "1" ]; then
    echo "$default"
    return
  fi
  read -r -t 30 -p "  $prompt (auto-$default in 30s): " answer || answer=""
  echo "${answer:-$default}"
}

# Re-exec under sudo if not already root. In dry-run, stay unprivileged
# (state-checking commands all work without root; only writes need it).
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

# ── Step 1: Microsoft GPG key ────────────────────────────────────────────────
KEY_URL="https://packages.microsoft.com/keys/microsoft.asc"

if rpm -q gpg-pubkey --qf '%{SUMMARY}\n' 2>/dev/null | grep -qi 'microsoft'; then
  info "Microsoft GPG key already imported — skipping."
else
  info "Importing Microsoft GPG key from $KEY_URL"
  if dryrun; then
    info "[DRY-RUN] would run: rpm --import $KEY_URL"
  else
    rpm --import "$KEY_URL" || die "GPG key import failed."
  fi
fi

# ── Step 2: vscode.repo ──────────────────────────────────────────────────────
REPO_FILE=/etc/yum.repos.d/vscode.repo
REPO_CONTENT=$(cat <<'EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
autorefresh=1
type=rpm-md
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
)

write_repo() {
  if dryrun; then
    info "[DRY-RUN] would write $REPO_FILE"
    return
  fi
  printf '%s\n' "$REPO_CONTENT" > "$REPO_FILE"
  chmod 0644 "$REPO_FILE"
  info "Wrote $REPO_FILE"
}

backup_repo() {
  local ts bak
  ts=$(date +%Y-%m-%dT%H%M)
  bak="${REPO_FILE}.${ts}.bak"
  if dryrun; then
    info "[DRY-RUN] would back up $REPO_FILE → $bak"
    return
  fi
  cp -a "$REPO_FILE" "$bak"
  info "Backed up existing $REPO_FILE → $bak"
}

if [ ! -e "$REPO_FILE" ]; then
  info "$REPO_FILE missing — creating."
  write_repo
elif diff -q <(printf '%s\n' "$REPO_CONTENT") "$REPO_FILE" &>/dev/null; then
  info "$REPO_FILE already matches expected content — skipping."
else
  warn "$REPO_FILE exists with different content. Diff (existing → desired):"
  diff -u "$REPO_FILE" <(printf '%s\n' "$REPO_CONTENT") || true
  case "$(ask 'Replace existing repo file? [Y/n/q]' 'y')" in
    [Yy]*) backup_repo; write_repo ;;
    [Qq]*) die "Aborted by user." ;;
    *)     info "Keeping existing $REPO_FILE." ;;
  esac
fi

# ── Step 3: install code package ─────────────────────────────────────────────
if rpm -q code &>/dev/null; then
  installed=$(rpm -q --qf '%{VERSION}-%{RELEASE}' code)
  info "code is already installed ($installed)."
  case "$(ask 'Run dnf upgrade for code? [y/N/q]' 'n')" in
    [Yy]*)
      if dryrun; then
        info "[DRY-RUN] would run: dnf upgrade -y code"
      else
        dnf upgrade -y code
      fi
      ;;
    [Qq]*) die "Aborted by user." ;;
    *)     info "Leaving installed version unchanged." ;;
  esac
else
  info "Installing code package..."
  if dryrun; then
    info "[DRY-RUN] would run: dnf install -y code"
  else
    dnf install -y code
  fi
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
if dryrun; then
  info "Dry run complete. No changes were made."
else
  if command -v code &>/dev/null; then
    info "VS Code installed: $(code --version | head -1)"
    info "Launch with: code ."
  else
    warn "code command not found on PATH after install — verify manually."
  fi
fi
