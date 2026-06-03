# Reproduce manually-installed apps on a peer machine

**Date:** 2026-06-03
**Status:** Approved (design); implementation pending
**Goal:** Reproduce the applications/tools manually installed on the main
workstation (`oaknet-ws-fedora`) onto the mini-PC (`oaknet-nibbler`) — and any
future Fedora peer — using the repo's existing idempotent-script idiom.

## Background

`fedora-setup` already scripts a handful of installs (VS Code, Tailscale, NVIDIA,
the modern-CLI set, starship, zsh plugins). A survey of the workstation found
more software that was installed by hand and is **not** yet reproducible:

- **dnf, from third-party repos:** Docker CE, Google Chrome, Mullvad (VPN +
  browser). (VS Code, Tailscale, NVIDIA already scripted. Steam's repo is
  enabled but no Steam package is installed — excluded.)
- **Flatpaks:** Obsidian, GIMP, Zen Browser, Firefox. (Entangle excluded as
  niche.)
- **Standalone CLI tools:** `uv`, `claude` (Claude Code), npm globals
  (`codex`, `firebase-tools`), and `git-filter-repo`.

## Approach — hybrid (match each tier to its representation)

Chosen over "per-tool scripts for everything" (sprawl: 4 near-identical flatpak
scripts) and "manifests everywhere" (a flat list cannot express the distinct
signed-repo setup each dnf app needs).

- **Imperative per-tool scripts** where the work is genuinely per-app and
  stateful (import a key, write a `.repo`, enable a service, add a group).
- **Declarative manifest + apply script** where the work is a homogeneous list
  (flatpaks, npm globals).
- **Official-installer scripts** (the existing `starship` pattern) for tools
  that ship their own installer (`uv`, `claude`).

## Components

### Tier ① — per-tool dnf scripts

Each mirrors `user-manual-install-vscode.sh` / `-tailscale.sh`: Fedora pre-flight
check, auto-sudo via `sudo -E`, idempotent (`rpm -q` + repo-file existence),
`--dry-run` / `--no-prompt` / `--help`. Packages install latest-from-repo (no
version pinning — consistent with existing scripts).

| Script | Repo setup | Packages | Extra |
|---|---|---|---|
| `user-manual-install-docker.sh` | write `/etc/yum.repos.d/docker-ce.repo` from `https://download.docker.com/linux/fedora/docker-ce.repo` | `docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin` | `systemctl enable --now docker`; add invoking user to `docker` group |
| `user-manual-install-chrome.sh` | write `/etc/yum.repos.d/google-chrome.repo` (baseurl `https://dl.google.com/linux/chrome/rpm/stable/x86_64`, gpgkey `https://dl.google.com/linux/linux_signing_key.pub`) | `google-chrome-stable` | — |
| `user-manual-install-mullvad.sh` | `curl` `https://repository.mullvad.net/rpm/stable/mullvad.repo` → `/etc/yum.repos.d/` | `mullvad-vpn mullvad-browser` | — |

**Docker specifics:**
- The `docker` group is **root-equivalent**. The script adds the user anyway (it
  matches the workstation) but prints an explicit security warning and notes that
  **the user must log out/in** for the group to take effect.
- Under auto-sudo the script runs as root; the group-add must target the real
  user via `${SUDO_USER:-$(logname)}`, **not** root. Membership is checked first
  (`id -nG`) and skipped if already present.

### Tier ② — flatpaks (manifest + apply)

- **`flatpak-apps.list`** — one Flathub app-ID per line, `#` comments allowed:
  ```
  md.obsidian.Obsidian
  org.gimp.GIMP
  app.zen_browser.zen
  org.mozilla.firefox
  ```
- **`user-manual-install-flatpaks.sh`** — ensure `flatpak` is installed (`dnf
  install flatpak` if missing) → `flatpak remote-add --if-not-exists flathub
  https://dl.flathub.org/repo/flathub.flatpakrepo` → install each manifest entry,
  skipping any already present (`flatpak info <id>`).
  - **Install scope: system-wide** (matches a default `flatpak install`), which
    needs root — the script auto-elevates for the install/remote steps. A
    `--user` flag flips to per-user/no-sudo installs.
  - `--dry-run` / `--no-prompt` / `--help`. `--no-prompt` installs every manifest
    entry.

### Tier ③ — CLI tools

- **`user-manual-install-uv.sh`** — `curl -LsSf https://astral.sh/uv/install.sh
  | sh` into `~/.local/bin`. No sudo; **refuses to run as root** (like starship).
  Idempotent: if `~/.local/bin/uv` exists, report version and prompt to re-run
  the installer (default skip).
- **`user-manual-install-claude.sh`** — Claude Code's official installer
  (`curl -fsSL https://claude.ai/install.sh | bash`; exact URL/flags verified at
  implementation). No sudo; refuses root; idempotent on `command -v claude`.
- **`npm-globals.list`** + **`user-manual-install-node-and-npm-globals.sh`** —
  `dnf install nodejs npm`, then `npm install -g` each manifest entry. The global
  prefix is `/usr/local`, so this needs root → auto-sudo. Idempotent via
  `npm ls -g <pkg>`. Manifest (exact npm package names confirmed at
  implementation):
  ```
  @openai/codex
  firebase-tools
  ```
- **Modify `user-manual-install-modern-cli-tools.sh`** — add `git-filter-repo`
  (stock Fedora dnf package) to the `PACKAGES` array + header list.

### Orchestrator

- **`user-manual-install-apps.sh`** — sequences the app installers with per-step
  gating and `--dry-run` / `--no-prompt` / `--dotfiles-dir`-style pass-through,
  structured exactly like `user-manual-bootstrap-fedora.sh`. Runs as the
  user; children self-elevate where needed (the `uv`/`claude` children refuse
  root, so the orchestrator must not run under sudo). Order:
  1. `install-docker.sh`, `install-chrome.sh`, `install-mullvad.sh`
  2. `install-flatpaks.sh`
  3. `install-node-and-npm-globals.sh`
  4. `install-uv.sh`, `install-claude.sh`
- **Kept separate from `bootstrap-fedora.sh`**, which provisions the shell/CLI
  *environment*. "Applications" is a distinct concern with a distinct cadence.
- NVIDIA is **not** included (separate, workstation-specific).

## Non-interactive defaults (per script-creation convention)

| Script | Interactive prompts? | `--no-prompt` default |
|---|---|---|
| dnf app installers | confirm before `dnf install` | proceed (install) |
| docker group-add | — | add the user (warn regardless) |
| flatpaks | confirm before installing the set | install all manifest entries |
| uv / claude | prompt only if already installed (re-run installer?) | skip re-run |
| node + npm globals | confirm before install | install all |
| orchestrator | gate each step | run all steps |

## Documentation & integration

- **`docs/specs/`** convention seeded by this file; a `## Docs` section added to
  the repo `CLAUDE.md` records it.
- **README.md** + **CLAUDE.md** gain an entry per new script (preserving the
  "every script documented in both" invariant).
- **NIBBLER.md** gains an **apps step** after the shell bootstrap, referencing
  `install-apps.sh`, and noting (a) the Docker re-login requirement and (b) that
  GUI flatpaks need a desktop session.

## Non-goals

- No "snapshot everything installed" capture tool — this is a **curated**,
  hand-edited declarative set.
- Not reproduced: the user's own project entry points (`notemap`,
  `concept-linker` — repo-specific), Steam (not installed), Entangle (excluded),
  NVIDIA (workstation-only), the pile of `~/.local/bin` pip/uv tool-shims (build
  byproducts, not apps).
- No version pinning — latest-from-source, matching existing scripts.

## Open items to confirm at implementation

- Exact `claude` installer URL/flags (native installer vs npm).
- Exact npm package name for `codex` (`@openai/codex` assumed).
- Whether flatpaks should default to system or `--user` (spec assumes system).
