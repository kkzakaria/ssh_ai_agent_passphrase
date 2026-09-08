# ssh-broker

Let an AI agent run SSH commands on servers you choose, **without ever handing
it the key passphrase**.

Two bash scripts, no exotic dependencies: `pass`, GnuPG, OpenSSH.

## The problem

An AI agent that deploys, restarts a service, or reads a remote log needs an
SSH key. Giving it a passphrase-less key, or the passphrase in plain text in
its environment, gives it permanent, uncontrolled access. Giving it your
personal `pass` store exposes every other secret you own if the agent is
hijacked by a prompt injection.

## How it works

`ssh-broker.sh` is the only tool exposed to the agent. It takes a host and a
command, and handles everything else:

1. checks the host against a hardcoded allowlist;
2. requires an explicit command, never an interactive shell;
3. checks that the host key is already present in a dedicated known_hosts file;
4. logs the call, locally and to syslog;
5. fetches the passphrase from a dedicated `pass` store, encrypted by a
   dedicated GPG key;
6. loads the SSH key into a throwaway `ssh-agent` through `SSH_ASKPASS`, so the
   passphrase never touches a persistent file, `argv`, or the log;
7. runs the command, then kills the agent and removes the temporary files.

The agent only ever sees the command output.

## What is isolated, and why

`pass` has no per-application access control: any process that can talk to
the right `gpg-agent` can decrypt everything that keyring protects. The broker
therefore uses a GPG keyring and a `pass` store that exist for it alone. If the
agent is hijacked, it can reach **this one SSH passphrase** and nothing else.

| Measure | Detail |
|---|---|
| GPG key | dedicated, passphrase-protected, in `~/.ssh-broker-gnupg` |
| `pass` store | dedicated, in `~/.ssh-broker-password-store` |
| GPG cache | short TTL: 5 min by default, 15 min maximum |
| Cache purge | optional after every call (`SSH_BROKER_FLUSH_GPG_CACHE=1`) |
| Host keys | dedicated `~/.ssh-broker-known_hosts`, filled by a human after checking fingerprints, never written by the broker |
| Log | local file in mode 600 plus a syslog copy via `logger`, arguments escaped |
| SSH session | command required, `RequestTTY=no`, `ForwardAgent=no`, `ClearAllForwardings=yes`, `BatchMode=yes` |
| Permissions | `umask 077` in both scripts, `chmod 700` on keyring and store |
| `PATH` | pinned at the top of the broker |

## Prerequisites

- Linux with bash 4 or later, `util-linux` for `setsid -w`
- OpenSSH 8.4 or later, for `SSH_ASKPASS_REQUIRE`
- `pass` and GnuPG 2.1 or later

```bash
sudo apt install pass gnupg   # Debian / Ubuntu
```

## Installation

```bash
git clone https://github.com/kkzakaria/ssh_ai_agent_passphrase.git
cd ssh_ai_agent_passphrase
chmod +x setup.sh ssh-broker.sh
./setup.sh
```

`setup.sh` is interactive and runs once, by a human. It:

- checks the prerequisites;
- generates a dedicated GPG key, whose passphrase you choose;
- initializes the dedicated `pass` store;
- generates the agent's SSH key and stores its passphrase;
- records your servers' host keys after showing their fingerprints, which
  you should verify through an independent channel;
- prints the public key to install on the server.

It is idempotent: every step skips what already exists, so rerun it to add a
server.

Then:

1. Edit `ALLOWED_HOSTS` in `ssh-broker.sh` with your servers, as
   `["host"]="user:port"`.
2. Add the public key to `~/.ssh/authorized_keys` on the target server,
   restricted to the intended action:

   ```
   restrict,command="/opt/agent/allowed-command.sh" ssh-ed25519 AAAA... ci-agent
   ```

   `restrict` disables pty, forwarding, agent forwarding, and X11. `command=`
   fixes the one command that runs, whatever the client asks for.

## Usage

```bash
./ssh-broker.sh --list-hosts                       # allowed hosts, one per line
./ssh-broker.sh deploy.myserver.example "uptime"
```

By default a human enters the GPG passphrase once, and the agent can then
chain calls without interaction until the 5-minute cache expires.

For sensitive actions, purge the cache after each call. A human then has to
re-enter the passphrase on every invocation:

```bash
SSH_BROKER_FLUSH_GPG_CACHE=1 ./ssh-broker.sh deploy.myserver.example "uptime"
```

## Agent skill

`skills/ssh-broker/SKILL.md` teaches an agent how to use the broker: discover
hosts with `--list-hosts`, run one non-interactive command per call, read the
error messages, and route every allowlist or key change through the human. It
follows the Agent Skills format, so it works with Claude Code and any other
agent that reads `SKILL.md` files.

Install it for Claude Code by linking the directory:

```bash
mkdir -p ~/.claude/skills
ln -s "$PWD/skills/ssh-broker" ~/.claude/skills/ssh-broker
```

The skill calls the broker as `ssh-broker`, so put a wrapper by that name on
the agent's `PATH`. Same-user setup:

```bash
ln -s "$PWD/ssh-broker.sh" ~/.local/bin/ssh-broker
```

Isolated setup (see below), where the agent may only reach the broker through
`sudo`:

```bash
sudo tee /usr/local/bin/ssh-broker >/dev/null <<'EOF'
#!/usr/bin/env bash
exec sudo -u sshbroker /opt/ssh-broker/ssh-broker.sh "$@"
EOF
sudo chmod 755 /usr/local/bin/ssh-broker
```

## Tests

```bash
bash tests/guards.sh
```

Runs every path that must end before any GPG access, in a throwaway `HOME`:
the host allowlist, the mandatory command, the dedicated known_hosts file,
`--list-hosts`, and the log file mode. It needs no server, no key, and no
passphrase.

## Threat model and limits

**The broker controls where the agent connects, not what it runs.** The remote
command is entirely chosen by the agent. The only control over the "what" is
server-side, with `restrict,command="..."`.

**The broker does not protect against a process running as the same user.**
As long as the agent and the broker share a Unix account, the agent can read
the private key, talk to the `gpg-agent` while the cache is warm, edit
`ALLOWED_HOSTS`, or tamper with the local log. Everything above is defense in
depth; the real barrier is the isolation described below.

Other points:

- `~/.ssh-broker.log` belongs to the broker's user, so a compromised agent can
  edit it. The syslog copy is the authoritative trace.
- Back up `~/.ssh-broker-gnupg` and `~/.ssh-broker-password-store`: losing
  them makes the SSH passphrase unrecoverable.

## OS-level isolation

Native keyrings (`secret-tool` on Linux, `security` on macOS) offer
per-application ACLs that `pass` cannot replicate. The closest equivalent in
plain Unix is a **dedicated system user** for the broker, separate from the one
running the agent, with a single call allowed through `sudo`.

```bash
# As root, once:
useradd --system --home /opt/ssh-broker --shell /usr/sbin/nologin sshbroker
# Run setup.sh as that user and place the scripts in /opt/ssh-broker

# In /etc/sudoers.d/ssh-broker (via visudo -f):
agentuser ALL=(sshbroker) NOPASSWD: /opt/ssh-broker/ssh-broker.sh
```

The agent, running as `agentuser`, then calls:

```bash
sudo -u sshbroker /opt/ssh-broker/ssh-broker.sh deploy.myserver.example "uptime"
```

It can run only that exact script and has no access to `sshbroker`'s
`gpg-agent`, `pass` store, private key, or log.

**Going further**: host the GPG key on a YubiKey (OpenPGP applet). The private
key never leaves the hardware, and every decryption can require a physical
touch.

## License

MIT, see [LICENSE](LICENSE).
