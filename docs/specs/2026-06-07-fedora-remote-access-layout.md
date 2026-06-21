# Fedora workstation remote access layout

**Date:** 2026-06-07
**Status:** Canonical remote-access spec for this repo. Active on `prime`;
partially implemented on `usagi` (SSH + KDE RDP only). Reusable pattern for
Fedora peers. Consolidates the earlier `2026-06-07-remote-access-design.md`
(removed) — the SSH-vs-Tailscale-SSH and krdp-vs-xrdp rationale and the
script/privilege model from that doc are folded in below.
**Goal:** Provide predictable incoming SSH and GUI access without enabling physical-console
autologin or broad LAN/WAN exposure.

## Implemented vs. manual (status at a glance)

| Piece | Scripted? | On `prime` | On `usagi` |
|---|---|---|---|
| OpenSSH server | ✅ `configure/ssh-server.sh` | ✅ | ✅ |
| KDE RDP (`krdp`, :3389) | ✅ `configure/rdp-server.sh` | ✅ | ✅ |
| XRDP fallback (:3390) + fallback user | ❌ manual sketch (below) | ✅ | ❌ not yet |
| Source-restricted firewall (rich rules) | ❌ scripts add the broad service only | ✅ (manual) | ❌ broad service, open to all sources |

The two `configure/*` scripts each ensure their firewalld *service*
(`ssh` / `rdp`) in the default zone — open to every source. The
source-restriction (Users VLAN + Tailscale CGNAT) in **Security Posture** below
is not yet scripted; on `prime` it was applied by hand.

## Current `prime` Layout

Host facts live in `oaknet-registry`; at the time this spec was written:

- Hostname: `prime`
- Fedora host name: `oaknet-ws-fedora`
- Users VLAN IP: `10.69.11.77`

Incoming access:

| Port | Service | Purpose | Login |
|---:|---|---|---|
| `22/tcp` | OpenSSH | Durable remote admin path | `prime` |
| `3389/tcp` | KDE RDP (`krdpserver`) | Primary active Plasma Wayland session sharing | KDE RDP/system user auth |
| `3390/tcp` | XRDP | Fallback pre-login/post-reboot GUI session | `prime-rdp` |

`3389` intentionally stays with KDE RDP because it shares the real active desktop when the
user is already logged into Plasma. `3390` is reserved for XRDP so it can create a separate
remote Xorg/XFCE session after reboot without requiring SDDM autologin.

## Peer: `usagi` (Fedora KDE mini-PC)

Same pattern, currently SSH + KDE RDP only (no XRDP fallback yet).

- Users VLAN IP: `10.69.11.5` (UniFi fixed reservation, MAC `70:70:fc:05:9f:53`)
- `ssh_user` / KDE-RDP login: `prime`
- Reached from `prime` via `connect-prime.sh`'s mirror image (`krdc rdp://10.69.11.5`
  or `xfreerdp /v:10.69.11.5 …`). Full runbook: claude-setup memory
  `oaknet-registry/reference_usagi_rdp.md`.

usagi is the strongest case for the XRDP fallback: it's woken by Wake-on-LAN and
sits at SDDM with **no live session** post-boot, so KDE RDP authenticates then
immediately drops with `ERRINFO_LOGOFF_BY_USER (0x0000000C)`. XRDP on `3390`
(its own session) sidesteps that without enabling autologin. Until then, the
documented workarounds are: log in at usagi's console once, or enable SDDM
autologin.

## krdp authentication & TLS (the :3389 path)

- **Auth = system user (PAM).** `krdpserverrc` sets `SystemUserEnabled=true`; RDP
  clients log in with the machine's Linux username + password. No second secret
  to provision (vs. the KCM's KWallet-stored per-server credential, which can't
  be set up headlessly). This is what makes `configure/rdp-server.sh`
  idempotent and secret-free.
- **TLS:** krdpserver requires a cert; the script generates a self-signed pair
  under `~/.local/share/krdpserver/` (openssl, 10y, key `chmod 600`) when absent
  — the same location/shape the System Settings KCM uses. Clients get a one-time
  trust warning; acceptable on LAN/tailnet.
- **Privilege model:** `configure/ssh-server.sh` auto-sudos (system unit +
  firewalld). `configure/rdp-server.sh` runs as the user and **refuses root**
  (config, certs, and the *user* systemd unit all live in `$HOME`); only its
  firewall step uses inline `sudo`.

## Why SSH (native sshd), not Tailscale-SSH only

`tailscale up --ssh` gives SSH over the tailnet, but only tailnet↔tailnet and only
while `tailscaled` is up. Native `sshd` works on the LAN, over the tailnet, and
survives Tailscale outages — so the scripted path enables stock sshd
(Fedora-default `sshd_config`: key+password, `PermitRootLogin prohibit-password`)
and leaves Tailscale SSH as an orthogonal add-on.

## Security Posture

Do not expose these services to the WAN.

Firewall scope should be:

- allow SSH/RDP from Users VLAN `10.69.11.0/24`
- allow SSH/RDP from Tailscale CGNAT `100.64.0.0/10`
- do not keep broad public-zone `ssh` or `rdp` services enabled
- no router port forwards

Remote users:

- Use `prime` for SSH and the active KDE session.
- Use a separate non-admin user such as `prime-rdp` for XRDP fallback sessions.
- Do not reuse the main `prime` password for `prime-rdp`.

## Why Two RDP Ports

KDE RDP and XRDP both default to `3389/tcp`. Running both on the same port is not possible.

The selected layout is:

- `3389`: KDE RDP, active Wayland session sharing
- `3390`: XRDP, separate Xorg/XFCE fallback session

This avoids SDDM autologin. Plain autologin can leave the physical workstation session open
after boot, which is not the right default for a primary workstation.

## Authentication Workflow for Setup

Avoid GUI/Polkit password popups for service and firewall commands. They can be short-lived
and confusing.

Use a terminal:

```bash
sudo -v
```

Then run privileged commands with `sudo` in that terminal. Automation should use `sudo -n`
and stop if sudo is not already authorized.

Do not use short `timeout` wrappers around commands that may require authentication.

## Setup Sketch

Install packages:

```bash
sudo dnf install -y xrdp xorgxrdp xfce4-session xfce4-panel xfdesktop xfwm4 \
  xfce4-settings xfce4-terminal Thunar dbus-x11
```

Create the fallback user:

```bash
sudo useradd -m -s /bin/bash prime-rdp
sudo passwd prime-rdp
```

Fedora XRDP uses `~/startwm.sh` when `EnableUserWindowManager=true` and
`UserWindowManager=startwm.sh` in `/etc/xrdp/sesman.ini`:

```bash
sudo tee /home/prime-rdp/startwm.sh > /dev/null <<'EOF'
#!/bin/sh
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
exec dbus-run-session startxfce4
EOF

sudo chown prime-rdp:prime-rdp /home/prime-rdp/startwm.sh
sudo chmod 755 /home/prime-rdp/startwm.sh
```

Move XRDP to `3390`:

```bash
sudo cp /etc/xrdp/xrdp.ini "/etc/xrdp/xrdp.ini.bak.$(date +%Y%m%d%H%M%S)"
sudo sed -i '0,/^port=/{s/^port=.*/port=3390/}' /etc/xrdp/xrdp.ini
sudo systemctl enable --now xrdp
sudo systemctl restart xrdp
```

Enable KDE RDP for the active Plasma session as the logged-in user:

```bash
systemctl --user enable --now app-org.kde.krdpserver.service
systemctl --user restart app-org.kde.krdpserver.service
```

Firewall intent:

```bash
sudo firewall-cmd --permanent --zone=public --remove-service=rdp 2>/dev/null || true
sudo firewall-cmd --permanent --zone=public --remove-service=ssh 2>/dev/null || true

sudo firewall-cmd --permanent --zone=public --add-rich-rule='rule family="ipv4" source address="10.69.11.0/24" service name="ssh" accept'
sudo firewall-cmd --permanent --zone=public --add-rich-rule='rule family="ipv4" source address="10.69.11.0/24" service name="rdp" accept'
sudo firewall-cmd --permanent --zone=public --add-rich-rule='rule family="ipv4" source address="10.69.11.0/24" port port="3390" protocol="tcp" accept'

sudo firewall-cmd --permanent --zone=public --add-rich-rule='rule family="ipv4" source address="100.64.0.0/10" service name="ssh" accept'
sudo firewall-cmd --permanent --zone=public --add-rich-rule='rule family="ipv4" source address="100.64.0.0/10" service name="rdp" accept'
sudo firewall-cmd --permanent --zone=public --add-rich-rule='rule family="ipv4" source address="100.64.0.0/10" port port="3390" protocol="tcp" accept'

sudo firewall-cmd --reload
```

## Verification

```bash
systemctl is-active xrdp xrdp-sesman sshd
systemctl is-enabled xrdp sshd
systemctl --user is-active app-org.kde.krdpserver.service
systemctl --user is-enabled app-org.kde.krdpserver.service
ss -ltnp | rg ':(22|3389|3390)\b'
```

Expected listeners:

- `22`: `sshd`
- `3389`: `krdpserver`
- `3390`: `xrdp`

Client targets:

- SSH: `ssh prime@<host-ip>`
- Primary RDP: `<host-ip>:3389`
- Fallback RDP: `<host-ip>:3390`

## Future Helper

A narrow root-owned helper such as `/usr/local/sbin/oaknet-remote-access` would make this
less error-prone. It should only support fixed check/apply actions for SSH, KDE RDP, XRDP,
Users VLAN, and Tailscale sources. Do not grant passwordless sudo for broad `firewall-cmd` or
`systemctl`.
