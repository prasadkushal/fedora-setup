# Remote access (SSH + RDP) — design

Date: 2026-06-07
Status: implemented

## Goal

Reach this workstation (and, reproducibly, any peer machine) from other
devices: shell access over SSH, full graphical desktop over RDP. Two new
configure scripts, both wired into `user-manual-setup-all.sh` as optional
(prompted, default No) steps.

## Decisions

### SSH: native sshd, not Tailscale-SSH-only

`user-manual-install-tailscale.sh --ssh` already provides SSH over the
tailnet, but it only works tailnet-to-tailnet and couples shell access to
tailscaled being up. Enabling stock `sshd` works on the LAN, over the
tailnet, and survives Tailscale outages. `openssh-server` ships preinstalled
on Fedora Workstation; the script only enables/starts the unit and ensures
the firewall `ssh` service (already in the `FedoraWorkstation` zone by
default). sshd_config is left at Fedora defaults (key+password auth,
`PermitRootLogin prohibit-password`).

### RDP: KDE krdp, not xrdp

This machine (and the planned peers) runs Fedora KDE, Plasma 6.6, Wayland.

- **krdp** is KDE's first-party RDP server, preinstalled with Plasma (≥6.1).
  It shares the *live Wayland session* via the XDG remote-desktop portal —
  what you see locally is what the remote client drives. H.264-encoded,
  configured by System Settings (kcm_krdpserver), runs as a per-user systemd
  unit (`app-org.kde.krdpserver.service`, `WantedBy=plasma-workspace.target`).
- **xrdp** spawns a *separate* X session per connection — wrong model for a
  single-user workstation, poor Wayland/Plasma 6 support, extra package +
  system daemon.

So: krdp. Consequence to be aware of: **RDP only works while the user is
logged in to a graphical session** (the server starts with the Plasma
session). Auto-login or a physically-running session is required for
headless-style access; that trade-off is accepted.

### RDP auth: system user credentials, no stored secret

`krdpserverrc` supports `SystemUserEnabled=true`: RDP clients authenticate
with the local Linux username + password (PAM). The alternative — per-server
username/password stored in KWallet via the KCM — cannot be provisioned
headlessly and adds a second credential to manage. System-user auth keeps the
script secret-free and idempotent.

### TLS certificate

krdpserver requires a TLS cert. The KCM generates a self-signed pair under
`~/.local/share/krdpserver/`; the script reproduces exactly that (openssl,
self-signed, 10 years, key chmod 600) when the files are missing, and points
`Certificate`/`CertificateKey` at them. Clients will see the usual
self-signed warning; acceptable for LAN/tailnet use.

### Privilege model

- `user-manual-configure-ssh-server.sh` — **auto-sudo** (systemd system unit
  + firewalld), tailscale-style. State checks run unprivileged in --dry-run.
- `user-manual-configure-rdp-server.sh` — **runs as the user, refuses root**
  (config, certs, and the systemd *user* unit all live in $HOME; enabling a
  user unit as root would target the wrong user). The one possibly-root step
  — adding the `rdp` firewalld service if absent — uses inline `sudo`
  (`sudo -n` + clear failure under --no-prompt).

### Firewall

Both scripts ensure their firewalld service (`ssh` / `rdp`) in the default
zone, runtime + permanent, skipping when already present (both already are on
USAGI) and warning (not dying) when firewalld is inactive.

### setup-all integration

Both are OPTIONAL steps (prompt-per-item, default No; skipped under
--no-prompt), after Tailscale. The RDP step is additionally gated on
`_is_kde`, like the quick-access shortcut. Remote access is a per-machine
policy decision, so it must never run by default.
