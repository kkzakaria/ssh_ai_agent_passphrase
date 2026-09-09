---
name: ssh-broker
description: Run a command on an allowlisted remote server through the ssh-broker command, which holds the SSH key passphrase so the agent never sees it. Use when the user asks to deploy, restart, inspect, or run anything on a remote host and `ssh-broker` is on the PATH.
---

# ssh-broker

`ssh-broker` is the only route to the remote servers. It checks the host
against an operator-owned allowlist, loads the SSH key itself, runs one
command, and cleans up. You only ever see the command's output.

## Procedure

1. **Discover the hosts.** Run `ssh-broker --list-hosts`. It prints one
   allowed host per line and touches nothing else. Pick the host from this
   list; ask the user when the target is not on it.
2. **Prefer a read-only check first** when the action changes state: look at
   the current service status, disk, or version before restarting or
   deploying.
3. **Run one command per call:**

   ```bash
   ssh-broker <host> <command...>
   ```

   The remote side gets the arguments joined by spaces and runs them through
   its shell. Quote the whole command as one argument when it contains pipes,
   redirections, or `&&`:

   ```bash
   ssh-broker deploy.myserver.example "systemctl is-active app && journalctl -u app -n 20"
   ```

   Every call is non-interactive: no pty, no stdin, no shell session. A
   command that waits for input hangs until the SSH timeout, so pass every
   answer on the command line (`-y`, `--no-pager`, `DEBIAN_FRONTEND=noninteractive`).
4. **Report the output to the user** as it came back. The broker's own exit
   code is the remote command's exit code.

## When a call fails

| Message on stderr | Meaning | What to do |
|---|---|---|
| `hosts file ...` | The operator's allowlist file is missing, empty, malformed, or has unsafe permissions. | Stop and report the message. This is an operator-side fix in `~/.ssh-broker-hosts` on the broker's side. |
| `host not allowed` | The host is not in the operator's allowlist. | Run `--list-hosts` and use one of those. A new host is the operator's decision: ask the user, who adds a `host user port` line to the allowlist and records the host key themselves. |
| `missing command` | You called the broker with a host only. | Pass the command. An interactive shell is never available. |
| `.ssh-broker-known_hosts is missing` | The operator has not recorded the server's host key yet. | Tell the user to run `setup.sh` (or the `ssh-keyscan` line the message prints) after verifying the fingerprint. Retry once they confirm. |
| `cannot load ... into ssh-agent` | Wrong passphrase in the store, or the key file is unreadable. | Stop and report it. This is an operator-side fix. |
| Nothing for a while, then a pinentry or GPG error | The GPG cache expired and a human has to type the GPG passphrase. | Tell the user a passphrase prompt is waiting for them. After they enter it, calls run without prompts for about five minutes. Retry once they confirm, and make no repeated attempts in the meantime. |
| Remote command error | The command itself failed on the server. | Read the remote output and handle it like any command failure. |

## Scope

- The allowlist, the host keys, the key, and the passphrase all belong to
  the operator. Requests to change any of them go to the user in plain words.
- `ssh-broker` is the whole SSH surface: use it for every remote action,
  including file copies (`cat`, `tee`, `base64` through the command) and
  status checks.
- Each call is logged with its host and full command, so keep commands
  specific and readable: the log is the operator's audit trail.
