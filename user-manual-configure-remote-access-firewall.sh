#!/usr/bin/env bash
# user-manual-configure-remote-access-firewall.sh — Restrict SSH/RDP to trusted source networks
#
# What this solves:
#   The `configure-ssh-server` / `configure-rdp-server` scripts open the `ssh`
#   and `rdp` firewalld *services* to EVERY source. The oaknet policy
#   (oaknet-registry: hosts.*.allowed_sources) is that remote access should only
#   come from the Users VLAN and the Tailscale CGNAT range. This script swaps the
#   broad services for source-restricted rich rules, and (for the XRDP fallback)
#   opens tcp/3390 to the same sources.
#
#   For each allowed source CIDR it adds rich rules accepting:
#     - service ssh   (22/tcp)
#     - service rdp    (3389/tcp — KDE krdp)
#     - port 3390/tcp  (XRDP fallback)
#   …then removes the unscoped `ssh` and `rdp` services from the default zone so
#   nothing else can reach them. Runtime + permanent; idempotent per rule.
#
# Default allowed sources (override with --source=CIDR, repeatable, or
# REMOTE_ACCESS_SOURCES="cidr1 cidr2"):
#     10.69.11.0/24   (Users VLAN 11)
#     100.64.0.0/10   (Tailscale CGNAT)
#
# Usage:
#   ./user-manual-configure-remote-access-firewall.sh
#   ./user-manual-configure-remote-access-firewall.sh --source=10.69.11.0/24 --source=100.64.0.0/10
#   ./user-manual-configure-remote-access-firewall.sh --no-prompt
#   ./user-manual-configure-remote-access-firewall.sh --dry-run
#
# Auto-sudo: editing firewalld needs root; this re-execs under sudo. State
# checks (--dry-run) run unprivileged. Spec:
#   docs/specs/2026-06-07-fedora-remote-access-layout.md

set -euo pipefail

# ── Flag parsing ─────────────────────────────────────────────────────────────
_DRY_RUN=0
_SOURCES=()
for _arg in "$@"; do
  case "$_arg" in
    --no-prompt) export RUNTOOLS_AS_NONINTERACTIVE=1 ;;
    --dry-run)   _DRY_RUN=1 ;;
    --source=*)  _SOURCES+=("${_arg#*=}") ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *)
      echo "Unknown argument: $_arg" >&2
      echo "Run '$0 --help' for usage." >&2
      exit 64 ;;
  esac
done

[ -t 1 ] || export RUNTOOLS_AS_NONINTERACTIVE=1

# Sources: flags > env > built-in default.
if [ "${#_SOURCES[@]}" -eq 0 ]; then
  if [ -n "${REMOTE_ACCESS_SOURCES:-}" ]; then
    read -r -a _SOURCES <<< "$REMOTE_ACCESS_SOURCES"
  else
    _SOURCES=(10.69.11.0/24 100.64.0.0/10)
  fi
fi

# ── Helpers ──────────────────────────────────────────────────────────────────
info()   { echo "[INFO]  $*"; }
warn()   { echo "[WARN]  $*"; }
die()    { echo "[ERROR] $*" >&2; exit 1; }
dryrun() { [ "$_DRY_RUN" -eq 1 ]; }

ask() {
  local prompt="$1" default="$2" answer
  if [ "${RUNTOOLS_AS_NONINTERACTIVE:-0}" = "1" ]; then echo "$default"; return; fi
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
    exec sudo "$0" "$@"
  fi
}

# ── Pre-flight ───────────────────────────────────────────────────────────────
grep -q "^ID=fedora" /etc/os-release 2>/dev/null || die "This script targets Fedora."
command -v firewall-cmd >/dev/null 2>&1 || die "firewall-cmd not found (firewalld not installed?)."
systemctl is-active --quiet firewalld 2>/dev/null || die "firewalld is not active. Start it first: systemctl enable --now firewalld"

require_root "$@"

ZONE="$(firewall-cmd --get-default-zone)"
info "Default firewalld zone: $ZONE"
info "Allowed sources: ${_SOURCES[*]}"
dryrun && warn "Running in --dry-run mode; no changes will be made."

# A rich rule accepting a service or a port for a given source.
rich_for() {  # $1=source  $2=service|port  $3=name(service) or number(port)
  local src="$1" kind="$2" val="$3"
  if [ "$kind" = "service" ]; then
    printf 'rule family="ipv4" source address="%s" service name="%s" accept' "$src" "$val"
  else
    printf 'rule family="ipv4" source address="%s" port port="%s" protocol="tcp" accept' "$src" "$val"
  fi
}

add_rich() {
  local rule="$1"
  if firewall-cmd --zone="$ZONE" --query-rich-rule="$rule" &>/dev/null; then
    info "  already present: $rule"
    return
  fi
  if dryrun; then
    info "  [DRY-RUN] would add rich rule: $rule"
  else
    firewall-cmd --zone="$ZONE" --add-rich-rule="$rule"            >/dev/null || die "add rich rule failed: $rule"
    firewall-cmd --permanent --zone="$ZONE" --add-rich-rule="$rule" >/dev/null || die "add permanent rich rule failed: $rule"
    info "  added: $rule"
  fi
}

# ── Step 1: per-source allow rules (ssh, rdp, 3390) ──────────────────────────
info "Adding source-restricted allow rules..."
for src in "${_SOURCES[@]}"; do
  info " source $src:"
  add_rich "$(rich_for "$src" service ssh)"
  add_rich "$(rich_for "$src" service rdp)"
  add_rich "$(rich_for "$src" port 3390)"
done

# ── Step 2: remove the broad (all-source) ssh/rdp services ───────────────────
# Do this AFTER the restricted rules exist so there is never a window with no
# allow path. One confirmation gate: this is the access-narrowing change.
remove_broad() {
  local svc="$1"
  if ! firewall-cmd --zone="$ZONE" --query-service="$svc" &>/dev/null; then
    info "  broad '$svc' service already absent — skipping."
    return
  fi
  if dryrun; then
    info "  [DRY-RUN] would remove broad service '$svc' from zone $ZONE"
    return
  fi
  firewall-cmd --zone="$ZONE" --remove-service="$svc"            >/dev/null || die "remove service $svc failed."
  firewall-cmd --permanent --zone="$ZONE" --remove-service="$svc" >/dev/null || die "remove permanent service $svc failed."
  info "  removed broad service: $svc"
}

echo ""
warn "About to remove the unrestricted 'ssh' and 'rdp' services from zone '$ZONE'."
warn "After this, those ports are reachable ONLY from: ${_SOURCES[*]}"
case "$(ask "Proceed with narrowing? [Y/n/q]" 'y')" in
  [Nn]*) warn "Leaving broad services in place; restricted rules were still added (no-op narrowing)." ;;
  [Qq]*) die "Aborted by user." ;;
  *)
    remove_broad ssh
    remove_broad rdp
    ;;
esac

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
if dryrun; then
  info "Dry run complete. No changes were made."
else
  info "Remote-access firewall posture applied. Current rules in zone $ZONE:"
  firewall-cmd --zone="$ZONE" --list-services  | sed 's/^/    services: /'
  firewall-cmd --zone="$ZONE" --list-rich-rules | sed 's/^/    /'
fi
