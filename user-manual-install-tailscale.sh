#!/usr/bin/env bash
# user-manual-install-tailscale.sh — Install Tailscale and enroll this machine
#
# What this does:
#   Makes remote access between your machines reproducible instead of a manual
#   one-off. On Fedora it:
#     1. Adds Tailscale's official stable RPM repo (idempotent).
#     2. dnf-installs the `tailscale` package (skipped if already present).
#     3. Enables + starts the tailscaled service.
#     4. Enrolls this machine on your tailnet (`tailscale up`).
#
#   With Tailscale up on both the workstation and the mini-PC, each box reaches
#   the other by its Magic DNS name (e.g. `oaknet-nibbler`) over an encrypted
#   WireGuard link, from anywhere — the "remote" half of a peers+remote setup.
#
# Enrollment / auth:
#   Interactive : runs `tailscale up`, which prints a login URL to authenticate
#                 in your browser. Add --ssh to also enable Tailscale SSH.
#   --no-prompt : requires the TS_AUTHKEY env var (a pre-generated auth key from
#                 the Tailscale admin console) and enrolls unattended. The key is
#                 never printed or logged. Fails clearly if TS_AUTHKEY is unset.
#
# Usage:
#   ./user-manual-install-tailscale.sh                    # interactive, browser login
#   ./user-manual-install-tailscale.sh --ssh              # also enable Tailscale SSH
#   TS_AUTHKEY=tskey-... ./user-manual-install-tailscale.sh --no-prompt
#   ./user-manual-install-tailscale.sh --dry-run          # show, change nothing
#
# Auto-sudo: installing packages + managing tailscaled needs root; this re-execs
# under `sudo -E` (preserving TS_AUTHKEY). State checks run unprivileged.

set -euo pipefail

# ── Flag parsing ─────────────────────────────────────────────────────────────
_DRY_RUN=0
_TS_SSH=0
for _arg in "$@"; do
  case "$_arg" in
    --no-prompt) export RUNTOOLS_AS_NONINTERACTIVE=1 ;;
    --dry-run)   _DRY_RUN=1 ;;
    --ssh)       _TS_SSH=1 ;;
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
    exec sudo -E "$0" "$@"   # -E preserves TS_AUTHKEY across the elevation
  fi
}

show_summary() {
  dryrun && return
  command -v tailscale >/dev/null 2>&1 || return
  echo ""
  info "Tailscale status:"
  tailscale status 2>/dev/null | sed 's/^/    /' || true
  local ip
  ip="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
  [ -n "$ip" ] && info "This machine's tailnet IPv4: $ip"
}

# ── Pre-flight ───────────────────────────────────────────────────────────────
if ! grep -q "^ID=fedora" /etc/os-release 2>/dev/null; then
  die "This script targets Fedora. /etc/os-release does not look like Fedora."
fi

require_root "$@"

command -v curl >/dev/null 2>&1 || die "curl is required but not found. Install it: dnf install -y curl"

info "Detected Fedora $(rpm -E %fedora)."
dryrun && warn "Running in --dry-run mode; no changes will be made."

# ── Step 1: Tailscale stable repo ────────────────────────────────────────────
REPO_FILE="/etc/yum.repos.d/tailscale.repo"
REPO_URL="https://pkgs.tailscale.com/stable/fedora/tailscale.repo"
if [ -f "$REPO_FILE" ]; then
  info "Tailscale repo already present ($REPO_FILE) — skipping."
elif dryrun; then
  info "[DRY-RUN] would run: curl -fsSL $REPO_URL -o $REPO_FILE"
else
  info "Adding Tailscale stable repo..."
  curl -fsSL "$REPO_URL" -o "$REPO_FILE" || die "Failed to download $REPO_URL"
fi

# ── Step 2: install the package ──────────────────────────────────────────────
if rpm -q tailscale &>/dev/null; then
  info "tailscale already installed ($(rpm -q --qf '%{VERSION}-%{RELEASE}' tailscale)) — skipping."
elif dryrun; then
  info "[DRY-RUN] would run: dnf install -y tailscale"
else
  info "Installing tailscale..."
  dnf install -y tailscale || die "dnf install tailscale failed."
fi

# ── Step 3: enable + start the service ───────────────────────────────────────
if systemctl is-enabled --quiet tailscaled 2>/dev/null && systemctl is-active --quiet tailscaled 2>/dev/null; then
  info "tailscaled already enabled and running — skipping."
elif dryrun; then
  info "[DRY-RUN] would run: systemctl enable --now tailscaled"
else
  info "Enabling and starting tailscaled..."
  systemctl enable --now tailscaled || die "Failed to enable tailscaled."
fi

# ── Step 4: enrollment ───────────────────────────────────────────────────────
# Distinguish three backend states so we only demand credentials when truly
# logged out:
#   Running    → already up on the tailnet; nothing to do.
#   Stopped    → authenticated but link down; `tailscale up` (no key needed).
#   NeedsLogin → logged out / fresh; needs browser login or TS_AUTHKEY.
# (`tailscale status` is read-only, so this is safe to inspect in dry-run too.)
ts_backend_state() {
  command -v tailscale >/dev/null 2>&1 || { echo ""; return; }
  local json line
  # Capture first, then match: piping a long-running producer into `grep -m1`
  # trips SIGPIPE under `set -o pipefail` (exit 141). BackendState appears once,
  # so a plain grep over the captured text is both correct and safe.
  json="$(tailscale status --json 2>/dev/null || true)"
  line="$(printf '%s\n' "$json" | grep '"BackendState"' || true)"
  printf '%s' "$line" | sed -E 's/.*"BackendState"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
}

_state="$(ts_backend_state)"
info "Tailscale backend state: ${_state:-unknown (not yet installed)}"

if [ "$_state" = "Running" ]; then
  info "Already up on the tailnet — nothing to enroll."
  show_summary
  exit 0
fi

TS_UP_ARGS=(up)
if [ "$_TS_SSH" -eq 1 ]; then
  TS_UP_ARGS+=(--ssh)
  info "Tailscale SSH will be enabled (--ssh): tailnet peers can SSH in via your ACLs."
fi

if [ "$_state" = "Stopped" ]; then
  # Authenticated already — just bring the link up; no auth key required.
  if dryrun; then
    info "[DRY-RUN] would run: tailscale ${TS_UP_ARGS[*]}  (already authenticated; just bringing the link up)"
  else
    info "Authenticated but down — bringing the link up..."
    tailscale "${TS_UP_ARGS[@]}" || die "tailscale up failed."
  fi
elif [ "${RUNTOOLS_AS_NONINTERACTIVE:-0}" = "1" ]; then
  # Logged out, unattended → needs a pre-generated auth key.
  if [ -z "${TS_AUTHKEY:-}" ]; then
    die "Running non-interactively and this machine is logged out, but TS_AUTHKEY is not set.
       Generate an auth key at https://login.tailscale.com/admin/settings/keys
       then re-run:  TS_AUTHKEY=tskey-... $0 --no-prompt"
  fi
  if dryrun; then
    info "[DRY-RUN] would run: tailscale ${TS_UP_ARGS[*]} --authkey [REDACTED]"
  else
    info "Enrolling unattended with TS_AUTHKEY..."
    tailscale "${TS_UP_ARGS[@]}" --authkey "$TS_AUTHKEY" || die "tailscale up failed."
  fi
else
  # Logged out, interactive → browser login.
  if dryrun; then
    info "[DRY-RUN] would run: tailscale ${TS_UP_ARGS[*]}  (prints a browser login URL)"
  else
    info "Enrolling — a login URL will be printed; open it in your browser to authenticate."
    tailscale "${TS_UP_ARGS[@]}" || die "tailscale up failed."
  fi
fi

# ── Done ─────────────────────────────────────────────────────────────────────
show_summary
echo ""
if dryrun; then
  info "Dry run complete. No changes were made."
else
  info "Tailscale install + enrollment complete."
fi
