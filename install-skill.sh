#!/usr/bin/env bash
# install-skill.sh — make the agent skill usable, same-user posture
#
# Links skills/ssh-broker into Claude Code's user skills directory and puts
# an `ssh-broker` command on the PATH that runs ssh-broker.sh from this
# checkout. Run it as the user the agent runs as. For the isolated posture
# (dedicated sshbroker user + sudo), see "Agent skill" in the README: the
# wrapper must call sudo instead, and needs root to install.
#
# Safe to rerun. Never overwrites a file that is not already our link.

set -euo pipefail
umask 077

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_DIR="${HOME}/.claude/skills"
BIN_DIR="${HOME}/.local/bin"

# link <target> <link-path>: create the symlink, accept it if already ours,
# refuse anything else so a user's own file is never clobbered.
link() {
  local target="$1" path="$2"
  if [ -L "${path}" ] && [ "$(readlink -f "${path}")" = "$(readlink -f "${target}")" ]; then
    echo "already linked: ${path}"
    return 0
  fi
  if [ -e "${path}" ] || [ -L "${path}" ]; then
    echo "Error: ${path} already exists and is not a link to ${target}. Remove it first." >&2
    return 1
  fi
  mkdir -p "$(dirname "${path}")"
  ln -s "${target}" "${path}"
  echo "linked: ${path} -> ${target}"
}

link "${REPO_DIR}/skills/ssh-broker" "${SKILLS_DIR}/ssh-broker"
link "${REPO_DIR}/ssh-broker.sh"     "${BIN_DIR}/ssh-broker"

case ":${PATH}:" in
  *":${BIN_DIR}:"*) ;;
  *) echo "Note: ${BIN_DIR} is not on your PATH. Add it, e.g.: export PATH=\"${BIN_DIR}:\$PATH\"" ;;
esac

echo
echo "Done. The agent can now run: ssh-broker --list-hosts"
echo "Broker side (hosts, keys, passphrase) is set up separately by ./setup.sh."
