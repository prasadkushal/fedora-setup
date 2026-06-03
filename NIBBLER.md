# NIBBLER.md — provisioning the Beelink SER6 mini-PC (`oaknet-nibbler`)

Runbook for bringing up the Beelink SER6 mini-PC as `oaknet-nibbler` with the
same shell/CLI/Claude environment as the main workstation (`oaknet-ws-fedora`).

This is **config reproduction, not a disk clone.** We rebuild the environment
from versioned repos + idempotent scripts rather than imaging the workstation's
disk — a block-level clone would carry the workstation's NVIDIA Blackwell driver
stack onto hardware that has no NVIDIA GPU.

---

## ⚠️ The one hardware divergence — read first

| | Workstation (`oaknet-ws-fedora`) | nibbler (Beelink SER6) |
|---|---|---|
| Discrete GPU | NVIDIA RTX 5070 Ti (GB203 Blackwell) | none |
| Integrated GPU | AMD Raphael iGPU | AMD Radeon APU |

**Do NOT run `user-manual-install-nvidia-driver.sh` on the nibbler.** It is the
only workstation-specific script in this repo. The SER6's Radeon graphics use
the in-kernel `amdgpu` driver that ships with stock Fedora — nothing to install,
nothing to blacklist. Every other script in this repo applies cleanly.

The `user-manual-bootstrap-fedora.sh` orchestrator codifies exactly the Step 2
sequence below (NVIDIA omitted), so on the nibbler you can run that one script
instead of the five individually.

---

## Step 0 — base OS + identity (manual)

1. **Install Fedora 43 KDE Plasma** from the official ISO. Match the
   workstation's release (43) and desktop. KDE is assumed because
   `user-manual-install-quick-access-terminal-shortcut.sh` targets KDE's
   `kded6` / `kglobalshortcutsrc`.
2. **Set the hostname:**
   ```bash
   sudo hostnamectl set-hostname oaknet-nibbler
   ```
3. **Network placement:** put the nibbler on the **Users VLAN** (VLAN 11,
   `10.69.11.0/24`) — that's where `oaknet-nibbler` belongs per
   `reference_network_unifi.md`, *not* the Lab VLAN 50 (which is for the
   Proxmox host + its service VMs).
4. **Git auth:** set up an HTTPS token or SSH key / `gh auth login` so the
   repo clones in Step 1 succeed.

---

## Step 1 — clone the repos

```bash
mkdir -p ~/projects/repos && cd ~/projects/repos
git clone <remote>/fedora-setup.git
git clone <remote>/dotfiles.git
git clone <remote>/claude-setup.git
# + any other repos you actually want on a mini-PC — decide deliberately,
#   the workstation carries ~18 and most are irrelevant on nibbler.
```

`dotfiles` and `claude-setup` are required: the bootstrap scripts symlink from
`dotfiles`, and `claude-setup` is the Claude Code config hub.

---

## Step 2 — bootstrap scripts

**Single command for the whole machine:** `./user-manual-setup-all.sh` runs the
shell-environment bootstrap *and* the application set (Step 2 + the Applications
step below) in one go, prompting for each optional. On the nibbler do **not**
pass `--with-nvidia` (AMD APU). Preview with `--dry-run` first. The rest of this
section describes the shell-environment bootstrap on its own.

The quickest path for just the shell environment is its orchestrator, which runs
the five scripts below in order (NVIDIA omitted) and passes through `--dry-run` /
`--no-prompt`:

```bash
cd ~/projects/repos/fedora-setup
./user-manual-setup-all.sh --dry-run          # preview EVERYTHING (shell + apps)
./user-manual-setup-all.sh                    # the whole machine, prompts for optionals
# …or just the shell environment:
./user-manual-bootstrap-fedora.sh --dry-run   # preview first
./user-manual-bootstrap-fedora.sh             # real run
```

If you'd rather run them by hand, this is the equivalent sequence. Do a
**`--dry-run` pass first** on each — all scripts are idempotent (`rpm -q` per
package, skip-if-correct-symlink per file), so re-running is safe.

| # | Command | What it does | sudo? |
|---|---|---|---|
| 1 | `./user-manual-install-modern-cli-tools.sh` | dnf-installs eza/bat/fd-find/zoxide/git-delta/direnv/fzf/ripgrep/nvtop + zsh | auto |
| 2 | `./user-manual-install-starship.sh` | starship prompt → `~/.local/bin` | no |
| 3 | `./user-manual-install-zsh-plugins.sh` | clones autosuggestions / syntax-highlighting / completions into `~/.config/zsh/plugins/` | no |
| 4 | `./user-manual-deploy-dotfiles.sh` | symlinks `~/.zshrc`, `~/.bashrc`, `~/.config/kitty/*`, `~/.claude/settings.local.json` from the dotfiles repo | no |
| 5 | `./user-manual-configure-shell-to-zsh.sh` | `chsh -s /bin/zsh` + kitty `shell` override (prompts for password via PAM) | no |

### Optional extras (not run by the orchestrator)

| Command | When | sudo? |
|---|---|---|
| `./user-manual-install-vscode.sh` | if you want VS Code | auto |
| `./user-manual-install-quick-access-terminal-shortcut.sh` | KDE only — binds `Meta+Return` to a quick-access terminal | no |
| `./user-manual-install-tailscale.sh` | remote access — reach the workstation (and vice-versa) by Magic DNS name from anywhere | auto |

After Tailscale is up on both boxes, keep them in sync with
`./user-manual-reload-dotfiles.sh` on each machine: it pulls the other's
committed dotfiles changes and re-links any new files. Because the dotfiles are
symlinks into the repo, the pull updates your live config in place. The flow for
a config change is: edit on machine A → commit & push (or let
`reload-dotfiles` option 3 do it) → run `reload-dotfiles` on machine B.

### Applications

Reproduce the workstation's manually-installed apps with the orchestrator
(design: `docs/specs/2026-06-03-reproduce-manual-apps-design.md`):

```bash
./user-manual-install-apps.sh            # docker, chrome, mullvad, flatpaks,
                                         # node+npm globals, uv, claude
```

Notes:

- **Docker** adds you to the `docker` group (effectively root) — **log out and
  back in** before `docker` works without sudo.
- The **flatpaks** (Obsidian, GIMP, Zen, Firefox) are GUI apps — they need a
  desktop session to launch. Edit `flatpak-apps.list` to curate the set.
- `uv` and `claude` install to `~/.local/bin` (already on PATH via the dotfiles).
- NVIDIA is **not** part of this set (workstation-specific).
- Curate before running: the set reflects the workstation. Drop anything the
  nibbler doesn't need by editing `user-manual-install-apps.sh`'s step list or
  the manifests.

---

## Step 3 — Claude Code config layer

`claude-setup` self-applies via its **SessionStart hook**
(`system-auto-apply-latest-config-from-repo.sh`) — you don't run anything by
hand for this layer. Two things to verify after Step 2:

1. `~/.claude/settings.local.json` (deployed by Step 2.4) sets **`CLAUDE_SETUP_DIR`**.
   Confirm it resolves to the nibbler's clone path: `~/projects/repos/claude-setup`.
   This is the one genuinely machine-specific value in the deployed dotfiles —
   check it even though the dotfiles repo's convention is "no machine-specific
   values."
2. Start a Claude Code session in any repo and confirm the SessionStart hook
   applied config without errors.

---

## Step 4 — verify

```bash
echo $SHELL                 # /bin/zsh
exec zsh                    # land in zsh; starship prompt + tip rotator visible
tools                       # the dotfiles cheatsheet function resolves
command -v eza bat fd zoxide rg delta direnv fzf   # all present
readlink ~/.zshrc           # → ~/projects/repos/dotfiles/.zshrc
readlink ~/.config/kitty/kitty.conf                # → dotfiles repo
echo $CLAUDE_SETUP_DIR      # ~/projects/repos/claude-setup
```

---

## Out of scope — NOT automated by this repo

These are real parts of "like the workstation" that no script here covers.
Handle them separately and deliberately:

- **Backup-client enrollment** — `oaknet-nibbler` is a *planned* restic/ZFS
  backup client (already listed in `incubator/lab/configs/server/oaknet-zfs-keys.service`
  and `configs/README` "each Linux device"), but the lab substrate is **not yet
  executing**. This is future lab work, separate from cloning the workstation.
- **Credentials** — git/SSH keys, `gh auth`, app logins: manual.
- **GUI apps / Flatpaks** beyond VS Code: not captured anywhere.

---

## Quick reference — full sequence

```bash
# Step 0 (manual): install Fedora 43 KDE, then:
sudo hostnamectl set-hostname oaknet-nibbler

# Step 1:
mkdir -p ~/projects/repos && cd ~/projects/repos
git clone <remote>/fedora-setup.git
git clone <remote>/dotfiles.git
git clone <remote>/claude-setup.git

# Step 2 (NVIDIA script intentionally omitted — AMD APU):
cd ~/projects/repos/fedora-setup
./user-manual-bootstrap-fedora.sh
# optional: ./user-manual-install-vscode.sh
# optional (KDE): ./user-manual-install-quick-access-terminal-shortcut.sh

# Applications (curate first — reflects the workstation; docker needs a re-login):
./user-manual-install-apps.sh

# Remote access (peers + remote): enroll on the tailnet.
# Interactive prints a browser login URL; unattended needs TS_AUTHKEY.
./user-manual-install-tailscale.sh            # add --ssh to enable Tailscale SSH

# Thereafter, pull the workstation's committed dotfiles changes anytime:
./user-manual-reload-dotfiles.sh
```
