# usagi Workstation

`usagi` is a Fedora mini-PC client for the primary development workstation
`prime`.

Run this after the normal Fedora bootstrap has cloned `fedora-setup`:

```bash
cd ~/projects/repos/fedora-setup/workstations/usagi
./finish-prime-ssh-workflow.sh
```

The script:

- installs SSH client helpers, `sshfs`, and a KDE RDP client;
- installs VS Code and the Remote SSH extension;
- installs/enrolls Tailscale using the reusable root script;
- adds `prime`, `prime-tailnet`, `prime-lan`, and `prime-oaknet` SSH aliases;
- leaves `prime` as the source of truth for code.

It does not enable an SSH server on `usagi`. The intended direction is:

```text
usagi -> SSH / VS Code Remote SSH / forwarded dev ports -> prime
```
