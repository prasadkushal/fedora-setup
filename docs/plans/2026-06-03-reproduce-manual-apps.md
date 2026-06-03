# Reproduce Manually-Installed Apps — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add scripts that reproduce the workstation's manually-installed apps (Docker, Chrome, Mullvad, four flatpaks, and CLI tools uv/claude/node-globals/git-filter-repo) on any Fedora peer, plus an orchestrator to run them.

**Architecture:** Hybrid per the spec (`docs/specs/2026-06-03-reproduce-manual-apps-design.md`): imperative per-tool dnf scripts for repo-backed apps, manifest+apply scripts for the homogeneous tiers (flatpaks, npm globals), official-installer scripts for uv/claude, and an `install-apps.sh` orchestrator kept separate from `bootstrap-fedora.sh`.

**Tech Stack:** Bash (the repo's existing house style — `set -euo pipefail`, `info/warn/die/dryrun/ask` helpers, `require_root` re-exec via `sudo -E`, `[ -t 1 ]` non-TTY detection), dnf5, flatpak, npm. Verification: `shellcheck -S warning`, `bash -n`, `--dry-run`, and idempotent re-run against the workstation's live state.

## House-style scaffold (every new script copies this)

All new `user-manual-install-*.sh` scripts share the identical scaffold already used across the repo. **Copy the scaffold from the named mirror file, then apply this task's deltas.** The scaffold = lines covering: shebang + `# header` usage block, `set -euo pipefail`, flag-parsing loop (`--no-prompt`/`--dry-run`/`-h|--help` via `sed -n '2,/^$/p' "$0" | sed 's/^# \?//'`), `[ -t 1 ] || export RUNTOOLS_AS_NONINTERACTIVE=1`, the `info/warn/die/dryrun/ask` helpers, and (for sudo scripts) `require_root` + the Fedora `/etc/os-release` pre-flight.

| Mirror file | Use it as the template for |
|---|---|
| `user-manual-install-tailscale.sh` | curl-a-`.repo` + auto-sudo (Docker, Mullvad) |
| `user-manual-install-vscode.sh` | write-an-embedded-`.repo` + import key + auto-sudo (Chrome) |
| `user-manual-install-starship.sh` | `curl \| sh` user install, refuses root (uv, claude) |
| `user-manual-install-modern-cli-tools.sh` | `PACKAGES` array + dnf install (node-globals, git-filter-repo edit) |
| `user-manual-bootstrap-fedora.sh` | step-sequencing orchestrator (install-apps) |

**Verification recipe (reused by every script task), run from the repo root:**
- `shellcheck -S warning <script>` → expect **no output** (clean).
- `bash -n <script>` → expect exit 0.
- `./<script> --dry-run` → expect the documented `[DRY-RUN] would …` lines, exit 0, no state change.
- `./<script>` (real, on the workstation) → expect the **already-installed skip path** (the workstation has all these apps), proving the idempotency guard. Safe because every guarded step detects existing state and skips.

---

### Task 1: Add `git-filter-repo` to modern-cli-tools

**Files:**
- Modify: `user-manual-install-modern-cli-tools.sh` (header tool list + `PACKAGES` array)

- [ ] **Step 1: Add the package to the array**

In the `PACKAGES=( … )` array, add `git-filter-repo` after `kitty`:

```bash
  zsh
  kitty
  git-filter-repo
)
```

- [ ] **Step 2: Add it to the header tool list**

After the `kitty` description block in the `# ` header, add:

```bash
#     git-filter-repo — surgical git history rewriting (single-purpose CLI)
```

- [ ] **Step 3: Verify**

Run: `shellcheck -S warning user-manual-install-modern-cli-tools.sh` → clean.
Run: `bash -n user-manual-install-modern-cli-tools.sh` → exit 0.
Run: `./user-manual-install-modern-cli-tools.sh --dry-run` → output includes a line mentioning `git-filter-repo` (either "already installed — skipping" or in the would-install set).

- [ ] **Step 4: Commit**

```bash
git add user-manual-install-modern-cli-tools.sh
git commit -m "modern-cli-tools: add git-filter-repo"
```

---

### Task 2: `user-manual-install-docker.sh`

**Files:**
- Create: `user-manual-install-docker.sh` (mirror `user-manual-install-tailscale.sh`)

- [ ] **Step 1: Write the script**

Copy the scaffold from `user-manual-install-tailscale.sh` (header usage block, flags, helpers, `require_root`, Fedora pre-flight). Replace the body with these steps. Header `# What this does:` must describe: add Docker CE repo → install engine+plugins → enable service → add user to `docker` group (root-equivalent; re-login needed).

```bash
require_root "$@"
info "Detected Fedora $(rpm -E %fedora)."
dryrun && warn "Running in --dry-run mode; no changes will be made."

# ── Step 1: Docker CE repo ────────────────────────────────────────────────────
REPO_FILE="/etc/yum.repos.d/docker-ce.repo"
REPO_URL="https://download.docker.com/linux/fedora/docker-ce.repo"
if [ -f "$REPO_FILE" ]; then
  info "Docker CE repo already present ($REPO_FILE) — skipping."
elif dryrun; then
  info "[DRY-RUN] would run: curl -fsSL $REPO_URL -o $REPO_FILE"
else
  command -v curl >/dev/null 2>&1 || die "curl is required. Install it: dnf install -y curl"
  curl -fsSL "$REPO_URL" -o "$REPO_FILE" || die "Failed to download $REPO_URL"
  info "Added Docker CE repo."
fi

# ── Step 2: install packages ──────────────────────────────────────────────────
DOCKER_PKGS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
to_install=()
for p in "${DOCKER_PKGS[@]}"; do rpm -q "$p" &>/dev/null || to_install+=("$p"); done
if [ "${#to_install[@]}" -eq 0 ]; then
  info "All Docker packages already installed — skipping."
elif dryrun; then
  info "[DRY-RUN] would run: dnf install -y ${to_install[*]}"
else
  dnf install -y "${to_install[@]}" || die "dnf install failed."
fi

# ── Step 3: enable + start service ────────────────────────────────────────────
if systemctl is-enabled --quiet docker 2>/dev/null && systemctl is-active --quiet docker 2>/dev/null; then
  info "docker service already enabled and running — skipping."
elif dryrun; then
  info "[DRY-RUN] would run: systemctl enable --now docker"
else
  systemctl enable --now docker || die "Failed to enable docker service."
fi

# ── Step 4: add the real user to the docker group ─────────────────────────────
# Resolve the invoking user, not root (we are under sudo here).
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "${USER:-}")}"
if [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; then
  warn "Could not resolve a non-root user; skipping docker-group add. Run: sudo usermod -aG docker <you>"
elif id -nG "$REAL_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
  info "$REAL_USER already in the docker group — skipping."
else
  warn "Adding $REAL_USER to the 'docker' group grants effective ROOT (any container can mount the host)."
  if dryrun; then
    info "[DRY-RUN] would run: usermod -aG docker $REAL_USER"
  else
    case "$(ask "Add $REAL_USER to the docker group? [Y/n/q]" 'y')" in
      [Nn]*) info "Skipped group add." ;;
      [Qq]*) die "Aborted by user." ;;
      *) usermod -aG docker "$REAL_USER"
         info "Added $REAL_USER to docker group. LOG OUT and back in for it to take effect." ;;
    esac
  fi
fi

echo ""
dryrun && info "Dry run complete. No changes were made." || info "Docker install complete. Log out/in if the group was just added."
```

- [ ] **Step 2: chmod + verify (apply the Verification recipe)**

```bash
chmod +x user-manual-install-docker.sh
shellcheck -S warning user-manual-install-docker.sh   # clean
bash -n user-manual-install-docker.sh                  # exit 0
./user-manual-install-docker.sh --dry-run              # [DRY-RUN] lines, exit 0
```
Then real idempotency on the workstation (docker is installed): `./user-manual-install-docker.sh` → expect "repo already present", "All Docker packages already installed", "service already enabled", "already in the docker group" — all skips, exit 0.

- [ ] **Step 3: Commit**

```bash
git add user-manual-install-docker.sh
git commit -m "Add user-manual-install-docker.sh"
```

---

### Task 3: `user-manual-install-chrome.sh`

**Files:**
- Create: `user-manual-install-chrome.sh` (mirror `user-manual-install-vscode.sh`)

- [ ] **Step 1: Write the script**

Copy the scaffold from `user-manual-install-vscode.sh` (it already does import-key → write-`.repo` → `dnf install`, which is exactly Chrome's shape). Deltas:

```bash
# Step 1 — GPG key
KEY_URL="https://dl.google.com/linux/linux_signing_key.pub"
# guard: rpm -q gpg-pubkey ... | grep -qi 'google' ; else rpm --import "$KEY_URL"

# Step 2 — repo file
REPO_FILE=/etc/yum.repos.d/google-chrome.repo
REPO_CONTENT=$(cat <<'EOF'
[google-chrome]
name=google-chrome
baseurl=https://dl.google.com/linux/chrome/rpm/stable/x86_64
enabled=1
gpgcheck=1
gpgkey=https://dl.google.com/linux/linux_signing_key.pub
EOF
)
# write/compare/backup exactly as vscode.sh does for its REPO_FILE

# Step 3 — install
# rpm -q google-chrome-stable guard; else dnf install -y google-chrome-stable
```

Keep vscode.sh's idempotent repo-file compare (`diff -q <(printf '%s\n' "$REPO_CONTENT") "$REPO_FILE"`) and the "already installed → offer upgrade (default n)" pattern for the package.

- [ ] **Step 2: chmod + verify**

```bash
chmod +x user-manual-install-chrome.sh
shellcheck -S warning user-manual-install-chrome.sh   # clean
bash -n user-manual-install-chrome.sh                  # exit 0
./user-manual-install-chrome.sh --dry-run              # [DRY-RUN] lines
./user-manual-install-chrome.sh                        # real: key imported, repo matches, "already installed" — skips
```

- [ ] **Step 3: Commit**

```bash
git add user-manual-install-chrome.sh
git commit -m "Add user-manual-install-chrome.sh"
```

---

### Task 4: `user-manual-install-mullvad.sh`

**Files:**
- Create: `user-manual-install-mullvad.sh` (mirror `user-manual-install-tailscale.sh`)

- [ ] **Step 1: Write the script**

Copy the tailscale scaffold. Deltas:

```bash
REPO_FILE="/etc/yum.repos.d/mullvad.repo"
REPO_URL="https://repository.mullvad.net/rpm/stable/mullvad.repo"
# curl-or-skip exactly like docker/tailscale

MULLVAD_PKGS=(mullvad-vpn mullvad-browser)
to_install=()
for p in "${MULLVAD_PKGS[@]}"; do rpm -q "$p" &>/dev/null || to_install+=("$p"); done
# install the missing set, dnf install -y "${to_install[@]}"
```
No service/group steps. Done message: note `mullvad-vpn` provides the GUI + `mullvad` CLI.

- [ ] **Step 2: chmod + verify**

```bash
chmod +x user-manual-install-mullvad.sh
shellcheck -S warning user-manual-install-mullvad.sh   # clean
bash -n user-manual-install-mullvad.sh                  # exit 0
./user-manual-install-mullvad.sh --dry-run             # [DRY-RUN] lines
./user-manual-install-mullvad.sh                       # real: repo present + both pkgs installed → skips
```

- [ ] **Step 3: Commit**

```bash
git add user-manual-install-mullvad.sh
git commit -m "Add user-manual-install-mullvad.sh"
```

---

### Task 5: Flatpaks — manifest + apply script

**Files:**
- Create: `flatpak-apps.list`
- Create: `user-manual-install-flatpaks.sh`

- [ ] **Step 1: Write the manifest**

`flatpak-apps.list`:

```
# Flathub app IDs to install. One per line; # comments and blank lines ignored.
# Edit this list to add/remove apps; user-manual-install-flatpaks.sh applies it.
md.obsidian.Obsidian
org.gimp.GIMP
app.zen_browser.zen
org.mozilla.firefox
```

- [ ] **Step 2: Write the apply script**

Mirror the tailscale scaffold for flags/helpers. Add a `--user` flag (default = system install). System install needs root, so `require_root "$@"` runs **unless** `--user` was passed. Body:

```bash
MANIFEST="$_SCRIPT_DIR/flatpak-apps.list"   # _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$MANIFEST" ] || die "Manifest not found: $MANIFEST"
SCOPE_FLAG=""; [ "$_USER_SCOPE" -eq 1 ] && SCOPE_FLAG="--user"

# ensure flatpak present
if ! rpm -q flatpak &>/dev/null; then
  if dryrun; then info "[DRY-RUN] would run: dnf install -y flatpak"
  else dnf install -y flatpak || die "Failed to install flatpak."; fi
fi

# flathub remote
if flatpak remote-list ${SCOPE_FLAG} 2>/dev/null | grep -qw flathub; then
  info "flathub remote already present — skipping."
elif dryrun; then
  info "[DRY-RUN] would run: flatpak remote-add ${SCOPE_FLAG} --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo"
else
  flatpak remote-add ${SCOPE_FLAG} --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
fi

# install each manifest entry
while IFS= read -r app; do
  app="${app%%#*}"; app="$(echo "$app" | xargs)"   # strip comments + whitespace
  [ -z "$app" ] && continue
  if flatpak info ${SCOPE_FLAG} "$app" &>/dev/null; then
    info "$app already installed — skipping."
  elif dryrun; then
    info "[DRY-RUN] would run: flatpak install ${SCOPE_FLAG} -y --noninteractive flathub $app"
  else
    flatpak install ${SCOPE_FLAG} -y --noninteractive flathub "$app" || warn "Failed to install $app (continuing)."
  fi
done < "$MANIFEST"
```

Note: `require_root` must be skipped when `--user`. Implement by parsing `--user` into `_USER_SCOPE` first, then calling `require_root "$@"` only when `[ "$_USER_SCOPE" -eq 0 ]`.

- [ ] **Step 3: chmod + verify**

```bash
chmod +x user-manual-install-flatpaks.sh
shellcheck -S warning user-manual-install-flatpaks.sh   # clean
bash -n user-manual-install-flatpaks.sh                  # exit 0
./user-manual-install-flatpaks.sh --dry-run             # [DRY-RUN] line per manifest entry
./user-manual-install-flatpaks.sh                       # real: flathub present + 4 apps installed → skips
```

- [ ] **Step 4: Commit**

```bash
git add flatpak-apps.list user-manual-install-flatpaks.sh
git commit -m "Add flatpak manifest + install-flatpaks.sh"
```

---

### Task 6: Node + npm globals — manifest + script

**Files:**
- Create: `npm-globals.list`
- Create: `user-manual-install-node-and-npm-globals.sh`

- [ ] **Step 1: Confirm the codex package name**

Run: `npm view @openai/codex version` → if it errors, run `npm view @openai/codex` / search to find the correct name; update the manifest accordingly. (Open item from the spec.)

- [ ] **Step 2: Write the manifest**

`npm-globals.list`:

```
# npm packages to install globally (npm install -g). One per line; # comments ok.
@openai/codex
firebase-tools
```

- [ ] **Step 3: Write the script**

Mirror the modern-cli-tools scaffold (auto-sudo; dnf install). Body:

```bash
require_root "$@"
# ensure node + npm
NODE_PKGS=(nodejs npm); to_install=()
for p in "${NODE_PKGS[@]}"; do rpm -q "$p" &>/dev/null || to_install+=("$p"); done
if [ "${#to_install[@]}" -gt 0 ]; then
  if dryrun; then info "[DRY-RUN] would run: dnf install -y ${to_install[*]}"
  else dnf install -y "${to_install[@]}" || die "Failed to install node/npm."; fi
fi
# install globals from manifest
MANIFEST="$_SCRIPT_DIR/npm-globals.list"
[ -f "$MANIFEST" ] || die "Manifest not found: $MANIFEST"
while IFS= read -r pkg; do
  pkg="${pkg%%#*}"; pkg="$(echo "$pkg" | xargs)"; [ -z "$pkg" ] && continue
  if npm ls -g "$pkg" &>/dev/null; then
    info "$pkg already installed globally — skipping."
  elif dryrun; then
    info "[DRY-RUN] would run: npm install -g $pkg"
  else
    npm install -g "$pkg" || warn "Failed to install $pkg (continuing)."
  fi
done < "$MANIFEST"
```

- [ ] **Step 4: chmod + verify**

```bash
chmod +x user-manual-install-node-and-npm-globals.sh
shellcheck -S warning user-manual-install-node-and-npm-globals.sh   # clean
bash -n user-manual-install-node-and-npm-globals.sh                  # exit 0
./user-manual-install-node-and-npm-globals.sh --dry-run             # [DRY-RUN] lines
./user-manual-install-node-and-npm-globals.sh                       # real: node present + globals installed → skips
```

- [ ] **Step 5: Commit**

```bash
git add npm-globals.list user-manual-install-node-and-npm-globals.sh
git commit -m "Add npm-globals manifest + node/npm-globals installer"
```

---

### Task 7: `user-manual-install-uv.sh`

**Files:**
- Create: `user-manual-install-uv.sh` (mirror `user-manual-install-starship.sh`)

- [ ] **Step 1: Write the script**

Copy starship.sh wholesale; swap the tool. Deltas: refuse root (`[ "$EUID" -eq 0 ] && die`), `UV_BIN="$HOME/.local/bin/uv"`, idempotent on `[ -x "$UV_BIN" ]` (report version, prompt re-run default skip), installer line:

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```
Done message: note uv also provides `uvx`.

- [ ] **Step 2: chmod + verify**

```bash
chmod +x user-manual-install-uv.sh
shellcheck -S warning user-manual-install-uv.sh   # clean
bash -n user-manual-install-uv.sh                  # exit 0
./user-manual-install-uv.sh --dry-run             # [DRY-RUN] curl … | sh line
./user-manual-install-uv.sh                        # real: "uv already installed: …" → default skip, exit 0
```

- [ ] **Step 3: Commit**

```bash
git add user-manual-install-uv.sh
git commit -m "Add user-manual-install-uv.sh"
```

---

### Task 8: `user-manual-install-claude.sh`

**Files:**
- Create: `user-manual-install-claude.sh` (mirror `user-manual-install-starship.sh`)

- [ ] **Step 1: Confirm the installer**

Verify the current Claude Code install method before writing: check `https://docs.claude.com/en/docs/claude-code` / the install one-liner. Use the native installer if available:

```bash
curl -fsSL https://claude.ai/install.sh | bash
```
If the native installer URL has changed or npm is the documented path, use that instead and note it in the header. (Open item from the spec.)

- [ ] **Step 2: Write the script**

Copy starship.sh. Deltas: refuse root, idempotent on `command -v claude` (report `claude --version`, prompt re-run default skip), the installer line from Step 1. Done message: note `claude` lands in `~/.local/bin` (or `~/.claude/local`) and may need a shell restart / PATH check.

- [ ] **Step 3: chmod + verify**

```bash
chmod +x user-manual-install-claude.sh
shellcheck -S warning user-manual-install-claude.sh   # clean
bash -n user-manual-install-claude.sh                  # exit 0
./user-manual-install-claude.sh --dry-run             # [DRY-RUN] installer line
./user-manual-install-claude.sh                        # real: "claude already installed" → default skip
```

- [ ] **Step 4: Commit**

```bash
git add user-manual-install-claude.sh
git commit -m "Add user-manual-install-claude.sh"
```

---

### Task 9: `user-manual-install-apps.sh` orchestrator

**Files:**
- Create: `user-manual-install-apps.sh` (mirror `user-manual-bootstrap-fedora.sh`)

- [ ] **Step 1: Write the orchestrator**

Copy `user-manual-bootstrap-fedora.sh` wholesale (flag parsing, non-root guard, dependency check, per-step gate loop, pass-through, summary). Change only the `_steps` array and the intro text. The non-root guard stays (uv/claude children refuse root; dnf children self-elevate):

```bash
_steps=(
  "user-manual-install-docker.sh"
  "user-manual-install-chrome.sh"
  "user-manual-install-mullvad.sh"
  "user-manual-install-flatpaks.sh"
  "user-manual-install-node-and-npm-globals.sh"
  "user-manual-install-uv.sh"
  "user-manual-install-claude.sh"
)
```
Intro text: "fedora apps — installs the manually-curated application set (see docs/specs/2026-06-03-reproduce-manual-apps-design.md). NVIDIA excluded." Drop the `--dotfiles-dir` handling (no child here takes it).

- [ ] **Step 2: chmod + verify**

```bash
chmod +x user-manual-install-apps.sh
shellcheck -S warning user-manual-install-apps.sh   # clean
bash -n user-manual-install-apps.sh                  # exit 0
./user-manual-install-apps.sh --dry-run --no-prompt  # runs each child with --dry-run; every child prints its [DRY-RUN] lines; final "complete" summary, exit 0
```

- [ ] **Step 3: Commit**

```bash
git add user-manual-install-apps.sh
git commit -m "Add user-manual-install-apps.sh orchestrator"
```

---

### Task 10: Documentation — README + CLAUDE.md

**Files:**
- Modify: `README.md` (add entries for all 7 new scripts + orchestrator)
- Modify: `CLAUDE.md` (add the same to the "Current scripts" list)

- [ ] **Step 1: README entries**

Under `## Scripts`, add the three dnf apps near vscode/tailscale, the flatpak + CLI scripts in a new `### Applications` subsection, and `install-apps.sh` as the orchestrator lead (mirror how `### zsh bootstrap` leads with `bootstrap-fedora.sh`). Each entry: one paragraph, link, what it does, sudo?, flags — matching the existing entry style.

- [ ] **Step 2: CLAUDE.md entries**

Add one bullet per new script to the `Current scripts:` list, in the established terse style (path — what it does — sudo — flags). Add `install-apps.sh` near `bootstrap-fedora.sh`.

- [ ] **Step 3: Verify doc coverage invariant**

```bash
for s in user-manual-*.sh; do
  grep -q "$s" README.md && grep -q "$s" CLAUDE.md || echo "MISSING DOC: $s"
done   # expect no output
```

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "Document app-install scripts + orchestrator"
```

---

### Task 11: NIBBLER.md — apps step

**Files:**
- Modify: `NIBBLER.md`

- [ ] **Step 1: Add the apps step**

After the zsh-bootstrap section (Step 2 / optional extras), add a step that runs `./user-manual-install-apps.sh`, and note: (a) Docker group membership needs a **log out/in**; (b) GUI flatpaks (Obsidian/GIMP/Zen/Firefox) need a desktop session; (c) `claude`/`uv` land in `~/.local/bin` (already on PATH via dotfiles). Add `./user-manual-install-apps.sh` to the "Quick reference — full sequence" block after the bootstrap line.

- [ ] **Step 2: Commit**

```bash
git add NIBBLER.md
git commit -m "NIBBLER: add apps-install step"
```

---

## Self-Review (completed during planning)

- **Spec coverage:** Docker/Chrome/Mullvad → Tasks 2–4; flatpaks → Task 5; uv/claude → Tasks 7–8; node+npm globals → Task 6; git-filter-repo → Task 1; orchestrator → Task 9; docs → Task 10; NIBBLER → Task 11. The spec's three "open items" are pinned to explicit confirmation steps (Task 6 Step 1 for codex; Task 8 Step 1 for the claude installer; flatpak scope default = system, with `--user` flag in Task 5). All spec sections map to a task.
- **Naming consistency:** every new file uses `user-manual-install-<thing>.sh`; manifests are `flatpak-apps.list` / `npm-globals.list`; the docker group-target variable is `REAL_USER` throughout; the flatpak scope variable is `_USER_SCOPE` / `SCOPE_FLAG` throughout.
- **No placeholders:** repo URLs, package arrays, service names, and guard conditions are concrete. The only deliberate "confirm at implementation" steps are the two genuinely external unknowns (codex npm name, claude installer URL), each with a concrete command to resolve it.
