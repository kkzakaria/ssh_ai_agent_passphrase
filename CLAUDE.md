# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A small bash tool that lets an AI agent run SSH commands on a fixed set of hosts without ever seeing the SSH key passphrase. The passphrase lives in a `pass` store encrypted by a GPG key that exists only for this broker, both isolated from the user's personal GPG keyring and password store. The README is the design rationale; read it before changing any security posture.

- `setup.sh` — run once, by a human, interactively. Creates the dedicated GPG keyring, the dedicated `pass` store, the SSH key, and stores the passphrase.
- `ssh-broker.sh <host> <command...>` — the only entry point exposed to the agent. It first loads the allowlist from `~/.ssh-broker-hosts` and refuses to run unless that file is safe (see invariants). `--list-hosts` then prints the allowlist and exits. Otherwise it checks the host against the allowlist, requires a command, requires the host in the dedicated known_hosts file, logs the call, decrypts the passphrase via `pass`, loads the key into a throwaway `ssh-agent`, runs the command, cleans up.
- `skills/ssh-broker/SKILL.md` — Agent Skills document for the agent that *uses* the broker (not for working on this repo). It assumes a wrapper named `ssh-broker` on the PATH. Keep its error table in sync with the messages in the broker.
- `install-skill.sh` — same-user installer for the skill: symlinks `skills/ssh-broker` into `~/.claude/skills/` and `ssh-broker.sh` as `~/.local/bin/ssh-broker`. Idempotent, refuses to overwrite anything that is not already its own link. The isolated posture needs a root-installed `sudo` wrapper instead, documented in the README, and is deliberately out of this script's scope.

## Commands

There is no build or lint config. `shellcheck` is not installed here.

```bash
bash -n setup.sh ssh-broker.sh install-skill.sh   # syntax
bash tests/guards.sh                              # every broker guard path, throwaway HOME, no secrets
bash tests/install-skill.sh                       # the skill installer, throwaway HOME
```

The guard test is the regression suite for the hosts file checks, the broker's early exits, and `--list-hosts`. It runs without a server or a real store, and it must stay that way. Any new guard in the broker gets a line there first (the `check` helper takes label, expected exit code, expected stderr substring, then the broker arguments). The end-to-end path through GPG and SSH can only be exercised manually against a real host.

## Invariants to preserve

These are the whole point of the design; a change that weakens one is a security regression, not a refactor.

- **Paths are hardcoded and paired.** `GNUPGHOME` and `PASSWORD_STORE_DIR` are exported to the same dedicated paths in both scripts (`~/.ssh-broker-gnupg`, `~/.ssh-broker-password-store`). Keep them identical in both files; never fall back to the user's default keyring or store.
- **The hosts file is the sole gate on destinations**, and it must be as protected as the script. `load_allowed_hosts` refuses the file unless it is a regular file (no symlink), owned by the current user, and not writable by group or others. Lines are `host user port`; a malformed line or an empty list is a hard error, never a warning. Keep the path fixed in the script: an env var or CLI flag would hand the allowlist to the agent.
- **Host keys come only from `~/.ssh-broker-known_hosts`**, written by a human in `setup.sh` after seeing the fingerprints. The broker passes it as `UserKnownHostsFile` with `StrictHostKeyChecking=yes` and refuses to run if it is missing. Never point the broker at the shared `~/.ssh/known_hosts`.
- **The broker restricts where, never what.** The remote command is fully agent-controlled; `RequestTTY=no`, `ForwardAgent=no`, `ClearAllForwardings=yes` close everything except the command. The "what" is enforced server-side by `restrict,command="..."` in `authorized_keys`, which `setup.sh` prints as the recommended entry.
- **`PATH` is pinned** at the top of the broker so no binary it calls can be shadowed by the caller's environment.
- **The passphrase never reaches a file, argv, or the log.** It flows `pass show` → env var → `SSH_ASKPASS` script that echoes the env var → `ssh-add` under `setsid` (so ssh-add has no TTY and is forced to use askpass). The askpass script lives in `/dev/shm` and is deleted, and the env var unset, before `ssh` runs. `setsid -w` guarantees ssh-add has finished before that cleanup. The log line records host and `%q`-escaped arguments only, to the 600 file and to syslog via `logger` when present.
- **`gpg-agent.conf` TTLs are short by design** (300s default, 900s max, written by `setup.sh`). `SSH_BROKER_FLUSH_GPG_CACHE=1` purges the cache after each call; the purge targets the encryption subkey's keygrip (the `ssb` line with capability `e`), not the primary key, because that is the key `pass` actually decrypts with.
- **`set -euo pipefail`** at the top of both scripts and `umask 077` in both, so the log and temp files are never world-readable. The broker refuses an empty command and sets `RequestTTY=no` so the agent can never obtain an interactive remote shell. The `trap cleanup EXIT` in the broker must keep killing the ssh-agent and removing the askpass files on every exit path, and must always return 0: under `set -e` a failing last command in the trap replaces the remote command's exit status, which the agent relies on. Use `if` blocks there, never a trailing `[[ cond ]] && action`. The guard test extracts `cleanup()` and checks this.

## Conventions

- Comments, user-facing messages, and docs are in English.
- `setup.sh` is idempotent: every step checks for existing state (key, store, SSH key) before creating it. Preserve that when adding steps.
