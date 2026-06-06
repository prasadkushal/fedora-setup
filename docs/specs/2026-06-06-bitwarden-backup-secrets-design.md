# Bitwarden-backed Oaknet backup secrets on Fedora

**Date:** 2026-06-06
**Status:** Proposed; implementation blocked
**Goal:** Replace persistent plaintext Fedora backup runtime secret files with a
scoped unattended secret fetch that is suitable for systemd backup jobs.

## Scope

This is a host-side Fedora setup design for Oaknet backup clients such as
`oaknet-ws-fedora` and `oaknet-nibbler`.

In scope:

- restic repository encryption password delivery
- rest-server REST Basic Auth password delivery
- Uptime Kuma Push URL delivery after successful backups
- systemd service/runtime integration on Fedora
- future `fedora-setup` installer or wrapper design

Out of scope:

- deploying the lab backup server, rest-server, Caddy, AdGuard, or Tailscale path
- creating live Bitwarden secrets, tokens, passwords, or Push URLs
- storing any live secret in this repo
- proving restore success or backup freshness

The lab substrate remains owned by `incubator/lab`. Cross-project risk and
security tracking remains owned by `oaknet-hardening`.

## Current blocker

The Fedora backup walkthrough for `oaknet-ws-fedora` reached restic's network
step, then failed because `backup.oaknet.live` did not resolve or route through
the expected private Oaknet path. Public DNS returned `NXDOMAIN`, Tailscale was
not running, and expected Lab VLAN backup services were not reachable from the
workstation.

Do not build around `/etc/hosts` as a workaround. DNS alone does not solve the
missing backup substrate if rest-server, Caddy, AdGuard, or the LAN/Tailscale path
is absent.

## Proposed architecture

Use Bitwarden Secrets Manager for unattended runtime secrets:

- Project: `oaknet-backups`
- Machine account per host, for example `oaknet-prime-fedora-backup`
- Machine account permissions: read-only access to that host's backup secrets
- Host-local bootstrap credential: the machine-account access token
- Preferred token storage: systemd encrypted credential, TPM-bound where practical

Secrets stored in Bitwarden Secrets Manager:

- restic repository encryption password
- rest-server REST Basic Auth password
- Uptime Kuma Push URL

Non-secret host config can stay in normal root-owned files or checked-in templates:

- repository URL, for example `rest:https://backup.oaknet.live/oaknet-prime-fedora/`
- REST username, for example `oaknet-prime-fedora`
- backup scope file
- timer/service names

This reduces persistent plaintext files such as:

- `/etc/restic/password`
- `/etc/restic/rest-password`
- `/etc/restic/heartbeat.curl`

It does not make unattended backups secret-free. The host still needs one local
bootstrap secret: the scoped machine-account access token.

## Why Secrets Manager instead of normal Bitwarden CLI

Normal Bitwarden Password Manager CLI (`bw`) is designed around unlocking a user
vault and maintaining a session. For unattended systemd jobs, that means the host
must also store or obtain an unlock secret/session key. That recreates the same
bootstrap-secret problem with a broader user-vault tool.

Bitwarden Secrets Manager is a better fit for machine access:

- machine accounts are intended for non-human runtime access
- access can be scoped to one project or one host's secrets
- token revocation and rotation are operationally clearer
- the runtime can fetch specific secrets without unlocking a full personal vault

KeePassX/KeePassXC-style local password managers are useful for operator access,
but are not the preferred unattended backup runtime unless their unlock path is
explicitly solved without adding a stronger plaintext secret on disk.

## systemd runtime shape

The future service should fetch secrets shortly before invoking restic:

1. systemd loads the Bitwarden machine-account token as an encrypted credential.
2. The wrapper reads the credential from systemd's runtime credential directory.
3. The wrapper uses `bws` to fetch the restic password, REST password, and Kuma
   Push URL for the host.
4. restic receives the repository encryption password through a password command,
   password file, or environment interface that avoids command arguments and
   shell history.
5. restic receives the REST Basic Auth password through the least-bad available
   runtime path.
6. The Kuma Push URL is used only after restic exits successfully.
7. Fetched secret material is removed from temporary files and not logged.

Known residual risk:

- Current restic REST Basic Auth delivery still appears to require transient
  `RESTIC_REST_PASSWORD` environment exposure for this wrapper shape. That is
  better than embedding credentials in repository URLs or command arguments, but
  it remains a risk tracked in `oaknet-hardening`.

## Installer follow-up

After the backup substrate exists, add a script such as
`user-manual-install-oaknet-backup-client.sh`.

The script should:

- support `--dry-run`, `--no-prompt`, and `--help`
- install or verify restic and the Bitwarden Secrets Manager CLI
- install the Oaknet backup wrapper and systemd service/timer
- create only non-secret config files from prompts or explicit arguments
- refuse to write live passwords, Push URLs, or Bitwarden tokens into git-tracked
  locations
- guide the user through creating/importing the systemd encrypted credential
  without printing the token
- validate file permissions before enabling the timer
- keep the timer disabled until one manual backup and heartbeat test succeeds

## Completion criteria

This design is implemented only when:

- `backup.oaknet.live` resolves internally through the approved Oaknet path
- the Fedora host can reach the backup server over LAN or Tailscale
- the restic repo exists and a manual backup succeeds
- the Kuma monitor records a success push after that backup
- the runtime does not depend on persistent plaintext restic password, REST
  password, or Kuma URL files
- `oaknet-hardening` records the resulting risk reduction

## Sources

- Bitwarden machine accounts: https://bitwarden.com/help/machine-accounts/
- Bitwarden Secrets Manager CLI: https://bitwarden.com/help/secrets-manager-cli/
- Bitwarden Password Manager CLI: https://bitwarden.com/help/cli/
- systemd credentials: https://systemd.io/CREDENTIALS/
- restic repository/password options:
  https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html
