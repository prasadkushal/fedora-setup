#!/usr/bin/env bash
# install/docker.sh — Install Docker CE on Fedora
#
# What this does:
#   Gives you a fully-working Docker CE install via Docker's official repo:
#     1. Adds the Docker CE RPM repo (idempotent).
#     2. dnf-installs docker-ce, docker-ce-cli, containerd.io,
#        docker-buildx-plugin, and docker-compose-plugin (skipped if present).
#     3. Enables + starts the docker service.
#     4. Adds the invoking user to the `docker` group so containers can be
#        run without sudo. NOTE: membership in the docker group is effectively
#        root-equivalent — any container can mount the host filesystem.
#        A fresh login is required for the group to take effect.
#
# Usage:
#   ./install/docker.sh                  # interactive
#   ./install/docker.sh --no-prompt      # unattended (auto-confirms)
#   ./install/docker.sh --dry-run        # show what would happen, change nothing
#
# Auto-sudo: installing packages + managing the docker service needs root; this
# re-execs under `sudo -E`. State checks run unprivileged (--dry-run stays as
# the invoking user).

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

ask() {
  local prompt="$1" default="$2" answer
  if [ "${RUNTOOLS_AS_NONINTERACTIVE:-0}" = "1" ]; then
    echo "$default"
    return
  fi
  read -r -t 30 -p "  $prompt (auto-$default in 30s): " answer || answer=""
  echo "${answer:-$default}"
}

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

# ── Step 1: Docker CE repo ────────────────────────────────────────────────────
REPO_FILE="/etc/yum.repos.d/docker-ce.repo"
REPO_URL="https://download.docker.com/linux/fedora/docker-ce.repo"
if [ -f "$REPO_FILE" ]; then
  info "Docker CE repo already present ($REPO_FILE) — skipping."
elif dryrun; then
  info "[DRY-RUN] would run: curl -fsSL $REPO_URL -o $REPO_FILE"
else
  command -v curl >/dev/null 2>&1 || die "curl is required. Install it: dnf install -y curl"
  curl -fsSL "$REPO_URL" -o "$REPO_FILE" || die "Failed to download $REPO_URL"
  info "Added Docker CE repo."
fi

# ── Step 2: install packages ──────────────────────────────────────────────────
DOCKER_PKGS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
to_install=()
for p in "${DOCKER_PKGS[@]}"; do rpm -q "$p" &>/dev/null || to_install+=("$p"); done
if [ "${#to_install[@]}" -eq 0 ]; then
  info "All Docker packages already installed — skipping."
elif dryrun; then
  info "[DRY-RUN] would run: dnf install -y ${to_install[*]}"
else
  dnf install -y "${to_install[@]}" || die "dnf install failed."
fi

# ── Step 3: enable + start service ────────────────────────────────────────────
if systemctl is-enabled --quiet docker 2>/dev/null && systemctl is-active --quiet docker 2>/dev/null; then
  info "docker service already enabled and running — skipping."
elif dryrun; then
  info "[DRY-RUN] would run: systemctl enable --now docker"
else
  systemctl enable --now docker || die "Failed to enable docker service."
fi

# ── Step 4: add the real user to the docker group ─────────────────────────────
# Resolve the invoking user, not root (we are under sudo here).
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "${USER:-}")}"
if [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; then
  warn "Could not resolve a non-root user; skipping docker-group add. Run: sudo usermod -aG docker <you>"
elif id -nG "$REAL_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
  info "$REAL_USER already in the docker group — skipping."
else
  warn "Adding $REAL_USER to the 'docker' group grants effective ROOT (any container can mount the host)."
  if dryrun; then
    info "[DRY-RUN] would run: usermod -aG docker $REAL_USER"
  else
    case "$(ask "Add $REAL_USER to the docker group? [Y/n/q]" 'y')" in
      [Nn]*) info "Skipped group add." ;;
      [Qq]*) die "Aborted by user." ;;
      *) usermod -aG docker "$REAL_USER"
         info "Added $REAL_USER to docker group. LOG OUT and back in for it to take effect." ;;
    esac
  fi
fi

echo ""
dryrun && info "Dry run complete. No changes were made." || info "Docker install complete. Log out/in if the group was just added."
