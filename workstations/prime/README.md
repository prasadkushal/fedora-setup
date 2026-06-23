# prime Workstation

`prime` is the primary development host. Code lives on `prime`; peer machines
such as `usagi` connect to it through OpenSSH over LAN or Tailscale.

Host facts:

- SSH user: `prime`
- LAN/DNS host: `prime.oaknet.live`
- LAN IP: `10.69.11.77`
- Fedora hostname: `oaknet-ws-fedora`

Host-side setup uses the reusable root scripts:

```bash
cd ~/projects/repos/fedora-setup
sudo ./user-manual-configure-ssh-server.sh --no-prompt
sudo ./user-manual-install-tailscale.sh
```

Do not run usagi client setup on this host.
