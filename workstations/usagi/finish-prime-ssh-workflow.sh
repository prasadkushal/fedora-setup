#!/usr/bin/env bash
# finish-prime-ssh-workflow.sh - Finish usagi as a client for prime
#
# What this does:
#   Configures the Fedora mini-PC `usagi` to use `prime` as the primary
#   development host. It keeps reusable installers in the repo root and applies
#   only usagi-specific client workflow here:
#     1. Install client-side helpers: openssh-clients, sshfs, krdc.
#     2. Install VS Code through the reusable root installer.
#     3. Install the VS Code Remote SSH extension when `code` is available.
#     4. Install/start/enroll Tailscale through the reusable root installer.
#     5. Add SSH aliases for prime under ~/.ssh/config.d/.
#
# Usage:
#   ./finish-prime-ssh-workflow.sh
#   ./finish-prime-ssh-workflow.sh --dry-run
#   ./finish-prime-ssh-workflow.sh --no-prompt
#   ./finish-prime-ssh-workflow.sh --skip-vscode --skip-tailscale
#
# Direction:
#   usagi -> SSH / VS Code Remote SSH / forwarded dev ports -> prime

set -euo pipefail

_DRY_RUN=0
_SKIP_CLIENT_PACKAGES=0
_SKIP_VSCODE=0
_SKIP_VSCODE_EXTENSION=0
_SKIP_TAILSCALE=0
_SKIP_SSH_CONFIG=0
_ALLOW_NON_USAGI=0
_PRIME_USER="prime"
_PRIME_TAILNET_HOST="oaknet-ws-fedora"
_PRIME_LAN_HOST="10.69.11.77"
_PRIME_OAKNET_HOST="prime.oaknet.live"
_IDENTITY_FILE="$HOME/.ssh/id_ed25519"

for _arg in "$@"; do
  case "$_arg" in
    --no-prompt) export RUNTOOLS_AS_NONINTERACTIVE=1 ;;
    --dry-run) _DRY_RUN=1 ;;
    --skip-client-packages) _SKIP_CLIENT_PACKAGES=1 ;;
    --skip-vscode) _SKIP_VSCODE=1 ;;
    --skip-vscode-extension) _SKIP_VSCODE_EXTENSION=1 ;;
    --skip-tailscale) _SKIP_TAILSCALE=1 ;;
    --skip-ssh-config) _SKIP_SSH_CONFIG=1 ;;
    --allow-non-usagi) _ALLOW_NON_USAGI=1 ;;
    --prime-user=*) _PRIME_USER="${_arg#*=}" ;;
    --prime-tailnet-host=*) _PRIME_TAILNET_HOST="${_arg#*=}" ;;
    --prime-lan-host=*) _PRIME_LAN_HOST="${_arg#*=}" ;;
    --prime-oaknet-host=*) _PRIME_OAKNET_HOST="${_arg#*=}" ;;
    --identity-file=*) _IDENTITY_FILE="${_arg#*=}" ;;
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

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_FEDORA_SETUP_DIR="$(cd "$_SCRIPT_DIR/../.." && pwd)"
_PASS_THROUGH=()
[ "$_DRY_RUN" -eq 1 ] && _PASS_THROUGH+=("--dry-run")
[ "${RUNTOOLS_AS_NONINTERACTIVE:-0}" = "1" ] && _PASS_THROUGH+=("--no-prompt")

info() { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*"; }
die()  { echo "[ERROR] $*" >&2; exit 1; }
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

expand_path() {
  case "$1" in
    \~) printf '%s\n' "$HOME" ;;
    \~/*) printf '%s/%s\n' "$HOME" "${1#~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

run_child() {
  local label="$1" script="$2"
  shift 2
  [ -x "$_FEDORA_SETUP_DIR/$script" ] || die "Missing or non-executable root script: $script"
  echo ""
  info "==> $label ($script)"
  "$_FEDORA_SETUP_DIR/$script" "$@"
}

install_client_packages() {
  local packages=(openssh-clients sshfs krdc)
  local missing=()
  local pkg

  for pkg in "${packages[@]}"; do
    if rpm -q "$pkg" >/dev/null 2>&1; then
      info "$pkg already installed - skipping."
    else
      missing+=("$pkg")
    fi
  done

  [ "${#missing[@]}" -eq 0 ] && return 0

  if dryrun; then
    info "[DRY-RUN] would run: sudo dnf install -y ${missing[*]}"
  else
    info "Installing client packages: ${missing[*]}"
    sudo dnf install -y "${missing[@]}"
  fi
}

install_vscode_extension() {
  local extension="ms-vscode-remote.remote-ssh"

  if ! command -v code >/dev/null 2>&1; then
    warn "code is not on PATH; skipping VS Code Remote SSH extension."
    return 0
  fi

  if code --list-extensions 2>/dev/null | grep -qx "$extension"; then
    info "VS Code extension already installed: $extension"
    return 0
  fi

  if dryrun; then
    info "[DRY-RUN] would run: code --install-extension $extension"
  else
    info "Installing VS Code Remote SSH extension: $extension"
    code --install-extension "$extension"
  fi
}

ensure_ssh_include() {
  local ssh_dir="$HOME/.ssh"
  local config_dir="$ssh_dir/config.d"
  local control_dir="$ssh_dir/controlmasters"
  local config_file="$ssh_dir/config"
  local include_line='Include ~/.ssh/config.d/*.conf'
  local backup tmp

  if dryrun; then
    info "[DRY-RUN] would ensure $config_file includes: $include_line"
    return 0
  fi

  mkdir -p "$config_dir" "$control_dir"
  chmod 700 "$ssh_dir" "$config_dir" "$control_dir"

  if [ ! -e "$config_file" ]; then
    printf '%s\n' "$include_line" > "$config_file"
    chmod 600 "$config_file"
    info "Created $config_file with config.d include."
    return 0
  fi

  if grep -Eq '^[[:space:]]*Include[[:space:]]+~/.ssh/config\.d/\*\.conf([[:space:]]+.*)?$' "$config_file"; then
    info "$config_file already includes ~/.ssh/config.d/*.conf."
    return 0
  fi

  backup="$config_file.$(date +%Y-%m-%dT%H%M%S).bak"
  tmp="$(mktemp)"
  cp "$config_file" "$backup"
  {
    printf '%s\n\n' "$include_line"
    cat "$config_file"
  } > "$tmp"
  cat "$tmp" > "$config_file"
  rm -f "$tmp"
  chmod 600 "$config_file" 2>/dev/null || true
  info "Added config.d include to $config_file; backup: $backup"
}

write_prime_ssh_config() {
  local ssh_dir="$HOME/.ssh"
  local config_dir="$ssh_dir/config.d"
  local config_file="$config_dir/usagi-prime-workflow.conf"
  local identity_expanded identity_for_config tmp backup

  identity_expanded="$(expand_path "$_IDENTITY_FILE")"
  identity_for_config="$_IDENTITY_FILE"

  tmp="$(mktemp)"
  {
    printf '# Managed by fedora-setup/workstations/usagi/finish-prime-ssh-workflow.sh\n'
    printf '# prime is the authoritative development workspace for usagi.\n\n'

    printf 'Host prime prime-tailnet\n'
    printf '    HostName %s\n' "$_PRIME_TAILNET_HOST"
    printf '    User %s\n' "$_PRIME_USER"
    if [ -r "$identity_expanded" ]; then
      printf '    IdentityFile %s\n' "$identity_for_config"
      printf '    IdentitiesOnly yes\n'
    fi
    printf '    AddKeysToAgent yes\n'
    printf '    ServerAliveInterval 30\n'
    printf '    ServerAliveCountMax 3\n'
    printf '    ControlMaster auto\n'
    printf '    ControlPath ~/.ssh/controlmasters/%%C\n'
    printf '    ControlPersist 10m\n\n'

    printf 'Host prime-lan\n'
    printf '    HostName %s\n' "$_PRIME_LAN_HOST"
    printf '    User %s\n' "$_PRIME_USER"
    if [ -r "$identity_expanded" ]; then
      printf '    IdentityFile %s\n' "$identity_for_config"
      printf '    IdentitiesOnly yes\n'
    fi
    printf '    AddKeysToAgent yes\n'
    printf '    ServerAliveInterval 30\n'
    printf '    ServerAliveCountMax 3\n'
    printf '    ControlMaster auto\n'
    printf '    ControlPath ~/.ssh/controlmasters/%%C\n'
    printf '    ControlPersist 10m\n\n'

    printf 'Host prime-oaknet\n'
    printf '    HostName %s\n' "$_PRIME_OAKNET_HOST"
    printf '    User %s\n' "$_PRIME_USER"
    if [ -r "$identity_expanded" ]; then
      printf '    IdentityFile %s\n' "$identity_for_config"
      printf '    IdentitiesOnly yes\n'
    fi
    printf '    AddKeysToAgent yes\n'
    printf '    ServerAliveInterval 30\n'
    printf '    ServerAliveCountMax 3\n'
    printf '    ControlMaster auto\n'
    printf '    ControlPath ~/.ssh/controlmasters/%%C\n'
    printf '    ControlPersist 10m\n'
  } > "$tmp"

  if [ ! -r "$identity_expanded" ]; then
    warn "Identity file not found/readable: $identity_expanded"
    warn "SSH config will allow password auth or any identities your agent offers."
  fi

  if dryrun; then
    info "[DRY-RUN] would write $config_file:"
    sed 's/^/    /' "$tmp"
    rm -f "$tmp"
    return 0
  fi

  mkdir -p "$config_dir" "$ssh_dir/controlmasters"
  chmod 700 "$ssh_dir" "$config_dir" "$ssh_dir/controlmasters"

  if [ -f "$config_file" ] && cmp -s "$tmp" "$config_file"; then
    rm -f "$tmp"
    info "$config_file already matches expected content."
    return 0
  fi

  if [ -f "$config_file" ]; then
    backup="$config_file.$(date +%Y-%m-%dT%H%M%S).bak"
    cp "$config_file" "$backup"
    info "Backed up existing $config_file to $backup"
  fi

  cat "$tmp" > "$config_file"
  rm -f "$tmp"
  chmod 600 "$config_file"
  info "Wrote $config_file"
}

show_summary() {
  echo ""
  info "usagi -> prime workflow targets:"
  info "  ssh prime         # tailnet/MagicDNS target: $_PRIME_TAILNET_HOST"
  info "  ssh prime-lan     # LAN IP target: $_PRIME_LAN_HOST"
  info "  ssh prime-oaknet  # Oaknet DNS target: $_PRIME_OAKNET_HOST"
  info "  code --remote ssh-remote+prime /home/prime/projects/repos"
  info "  ssh -L 5173:127.0.0.1:5173 prime"
  info "Then open http://127.0.0.1:5173 on usagi for a dev server running on prime."
}

if [ "${EUID:-$(id -u)}" -eq 0 ]; then
  die "Run this as your normal user, not root. Child installers elevate only when needed."
fi

if ! grep -q '^ID=fedora' /etc/os-release 2>/dev/null; then
  die "This script targets Fedora."
fi

_host="$(hostname -s 2>/dev/null || true)"
if [ "$_host" != "usagi" ] && [ "$_ALLOW_NON_USAGI" -ne 1 ]; then
  warn "This host is '$_host', not 'usagi'."
  case "$(ask 'Continue anyway? [y/N/q]' 'n')" in
    [Yy]*) ;;
    [Qq]*) die "Aborted by user." ;;
    *) die "Use --allow-non-usagi to run intentionally on another host." ;;
  esac
fi

info "Finishing usagi client workflow for primary host prime."
dryrun && warn "Running in --dry-run mode; no changes will be made."

if [ "$_SKIP_CLIENT_PACKAGES" -eq 0 ]; then
  install_client_packages
else
  info "Skipping client package installation."
fi

if [ "$_SKIP_VSCODE" -eq 0 ]; then
  run_child "VS Code" "user-manual-install-vscode.sh" "${_PASS_THROUGH[@]}"
else
  info "Skipping VS Code installation."
fi

if [ "$_SKIP_VSCODE_EXTENSION" -eq 0 ]; then
  install_vscode_extension
else
  info "Skipping VS Code Remote SSH extension."
fi

if [ "$_SKIP_TAILSCALE" -eq 0 ]; then
  run_child "Tailscale" "user-manual-install-tailscale.sh" "${_PASS_THROUGH[@]}"
else
  info "Skipping Tailscale installation/enrollment."
fi

if [ "$_SKIP_SSH_CONFIG" -eq 0 ]; then
  ensure_ssh_include
  write_prime_ssh_config
else
  info "Skipping SSH config."
fi

if ! dryrun && command -v ssh >/dev/null 2>&1; then
  ssh -G prime >/dev/null 2>&1 || warn "ssh -G prime did not parse cleanly; inspect ~/.ssh/config."
fi

show_summary
