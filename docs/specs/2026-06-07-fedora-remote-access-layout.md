# Fedora workstation remote access layout

**Date:** 2026-06-07
**Status:** Active on `prime`; reusable pattern for Fedora peers
**Goal:** Provide predictable incoming SSH and GUI access without enabling physical-console
autologin or broad LAN/WAN exposure.

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
