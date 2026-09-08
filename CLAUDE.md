# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A two-script bash tool that lets an AI agent run SSH commands on a fixed set of hosts without ever seeing the SSH key passphrase. The passphrase lives in a `pass` store encrypted by a GPG key that exists only for this broker, both isolated from the user's personal GPG keyring and password store. The README is the design rationale; read it before changing any security posture.

- `setup.sh` — run once, by a human, interactively. Creates the dedicated GPG keyring, the dedicated `pass` store, the SSH key, and stores the passphrase.
- `ssh-broker.sh <host> <command...>` — the only entry point exposed to the agent. Checks the host against `ALLOWED_HOSTS`, requires a command, requires the host in the dedicated known_hosts file, logs the call, decrypts the passphrase via `pass`, loads the key into a throwaway `ssh-agent`, runs the command, cleans up.

## Commands

There is no build, test suite, or lint config. Check syntax with:

```bash
bash -n setup.sh ssh-broker.sh
```

`shellcheck` and `pass` are not installed on this machine, so the broker cannot be run end to end here. Exercise the guard paths without secrets, in a throwaway `HOME` so the real log is untouched. Each must fail before any GPG access, in this order:

```bash
export HOME=$(mktemp -d)
./ssh-broker.sh not.allowed.example uptime      # "hôte non autorisé", exit 1
./ssh-broker.sh deploy.monserveur.example       # "commande manquante", exit 1
./ssh-broker.sh deploy.monserveur.example uptime # known_hosts absent, exit 1, no log line
touch "$HOME/.ssh-broker-known_hosts"
./ssh-broker.sh deploy.monserveur.example uptime # logs, then fails on "'pass' n'est pas installé"
```

## Invariants to preserve

These are the whole point of the design; a change that weakens one is a security regression, not a refactor.

- **Paths are hardcoded and paired.** `GNUPGHOME` and `PASSWORD_STORE_DIR` are exported to the same dedicated paths in both scripts (`~/.ssh-broker-gnupg`, `~/.ssh-broker-password-store`). Keep them identical in both files; never fall back to the user's default keyring or store.
- **`ALLOWED_HOSTS` is the sole gate on destinations**, checked before anything else runs. Its values are `user:port`. The agent must not be able to edit it, so do not move it to an env var, a config file, or a CLI flag.
- **Host keys come only from `~/.ssh-broker-known_hosts`**, written by a human in `setup.sh` after seeing the fingerprints. The broker passes it as `UserKnownHostsFile` with `StrictHostKeyChecking=yes` and refuses to run if it is missing. Never point the broker at the shared `~/.ssh/known_hosts`.
- **The broker restricts where, never what.** The remote command is fully agent-controlled; `RequestTTY=no`, `ForwardAgent=no`, `ClearAllForwardings=yes` close everything except the command. The "what" is enforced server-side by `restrict,command="..."` in `authorized_keys`, which `setup.sh` prints as the recommended entry.
- **`PATH` is pinned** at the top of the broker so no binary it calls can be shadowed by the caller's environment.
- **The passphrase never reaches a file, argv, or the log.** It flows `pass show` → env var → `SSH_ASKPASS` script that echoes the env var → `ssh-add` under `setsid` (so ssh-add has no TTY and is forced to use askpass). The askpass script lives in `/dev/shm` and is deleted, and the env var unset, before `ssh` runs. `setsid -w` guarantees ssh-add has finished before that cleanup. The log line records host and `%q`-escaped arguments only, to the 600 file and to syslog via `logger` when present.
- **`gpg-agent.conf` TTLs are short by design** (300s default, 900s max, written by `setup.sh`). `SSH_BROKER_FLUSH_GPG_CACHE=1` purges the cache after each call; the purge targets the encryption subkey's keygrip (the `ssb` line with capability `e`), not the primary key, because that is the key `pass` actually decrypts with.
- **`set -euo pipefail`** at the top of both scripts and `umask 077` in both, so the log and temp files are never world-readable. The broker refuses an empty command and sets `RequestTTY=no` so the agent can never obtain an interactive remote shell. The `trap cleanup EXIT` in the broker must keep killing the ssh-agent and removing the askpass files on every exit path.

## Conventions

- Comments and user-facing messages are in French; keep new ones in French for consistency.
- `setup.sh` is idempotent: every step checks for existing state (key, store, SSH key) before creating it. Preserve that when adding steps.
