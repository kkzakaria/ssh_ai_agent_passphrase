# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A two-script bash tool that lets an AI agent run SSH commands on a fixed set of hosts without ever seeing the SSH key passphrase. The passphrase lives in a `pass` store encrypted by a GPG key that exists only for this broker, both isolated from the user's personal GPG keyring and password store. The README is in French and is the design rationale; read it before changing any security posture.

- `setup.sh` — run once, by a human, interactively. Creates the dedicated GPG keyring, the dedicated `pass` store, the SSH key, and stores the passphrase.
- `ssh-broker.sh <host> <command...>` — the only entry point exposed to the agent. Checks the host against `ALLOWED_HOSTS`, logs the call, decrypts the passphrase via `pass`, loads the key into a throwaway `ssh-agent`, runs the command, cleans up.

## Commands

There is no build, test suite, or lint config. Check syntax with:

```bash
bash -n setup.sh ssh-broker.sh
```

`shellcheck` and `pass` are not installed on this machine, so the broker cannot be run end to end here. Exercise the host-allowlist path without secrets by calling with an unlisted host, which must fail before touching GPG:

```bash
./ssh-broker.sh not.allowed.example uptime   # expect "hôte non autorisé", exit 1
```

## Invariants to preserve

These are the whole point of the design; a change that weakens one is a security regression, not a refactor.

- **Paths are hardcoded and paired.** `GNUPGHOME` and `PASSWORD_STORE_DIR` are exported to the same dedicated paths in both scripts (`~/.ssh-broker-gnupg`, `~/.ssh-broker-password-store`). Keep them identical in both files; never fall back to the user's default keyring or store.
- **`ALLOWED_HOSTS` is the sole gate on destinations**, checked before anything else runs. Its values are `user:port`. The agent must not be able to edit it, so do not move it to an env var, a config file, or a CLI flag.
- **The passphrase never reaches a file, argv, or the log.** It flows `pass show` → env var → `SSH_ASKPASS` script that echoes the env var → `ssh-add` under `setsid` (so ssh-add has no TTY and is forced to use askpass). The askpass script lives in `/dev/shm` and is deleted, and the env var unset, before `ssh` runs. The log line records host and command only.
- **`gpg-agent.conf` TTLs are short by design** (300s default, 900s max, written by `setup.sh`). `SSH_BROKER_FLUSH_GPG_CACHE=1` purges the cache after each call; the purge targets the encryption subkey's keygrip (the `ssb` line with capability `e`), not the primary key, because that is the key `pass` actually decrypts with.
- **`umask 077` and `set -euo pipefail`** at the top of both scripts; the `trap cleanup EXIT` in the broker must keep killing the ssh-agent and removing the askpass files on every exit path.

## Conventions

- Comments and user-facing messages are in French; keep new ones in French for consistency.
- `setup.sh` is idempotent: every step checks for existing state (key, store, SSH key) before creating it. Preserve that when adding steps.
