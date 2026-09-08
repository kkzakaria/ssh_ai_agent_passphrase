#!/usr/bin/env bash
# ssh-broker.sh — hardened version
#
# Tool exposed to the AI agent (via function calling / tool use) as a plain
# shell command: ssh-broker.sh <host> <command...>
#
# Requirements: OpenSSH >= 8.4 (SSH_ASKPASS_REQUIRE), util-linux (setsid -w).

set -euo pipefail
umask 077   # log and temp files are never readable by other users

# Pinned PATH: the binaries (pass, gpg, ssh, ssh-agent, setsid) cannot be
# shadowed through a PATH manipulated by the caller.
export PATH="/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"

KEY_PATH="${HOME}/.ssh/id_ed25519_agent"
PASS_ENTRY="ssh-broker/passphrase"
LOG_FILE="${HOME}/.ssh-broker.log"

# DEDICATED known_hosts file, filled by setup.sh after a human has checked
# the fingerprints. The broker never writes to it (StrictHostKeyChecking=yes).
KNOWN_HOSTS="${HOME}/.ssh-broker-known_hosts"

# Same DEDICATED keyring/store as setup.sh — isolated from the user's
# personal GPG/pass.
export GNUPGHOME="${HOME}/.ssh-broker-gnupg"
export PASSWORD_STORE_DIR="${HOME}/.ssh-broker-password-store"

# If SSH_BROKER_FLUSH_GPG_CACHE=1, the GPG passphrase is purged from the
# cache right after each call: the safest posture, but it forces a new
# human entry (pinentry) on every agent invocation.
# By default (0), we rely on the short TTL set in gpg-agent.conf (5 min)
# to allow several automated calls in a row after a single human entry.
FLUSH_AFTER_USE="${SSH_BROKER_FLUSH_GPG_CACHE:-0}"

declare -A ALLOWED_HOSTS=(
  ["deploy.myserver.example"]="deploy:22"
)

# Discovery for the agent: list the allowed hosts and stop. Handled before
# anything else, so it never logs and never touches GPG.
if [[ "${1:-}" == "--list-hosts" ]]; then
  printf '%s\n' "${!ALLOWED_HOSTS[@]}" | sort
  exit 0
fi

HOST="${1:?Usage: ssh-broker.sh <host> <command...> | --list-hosts}"
shift

if [[ -z "${ALLOWED_HOSTS[$HOST]+x}" ]]; then
  echo "Error: host not allowed: ${HOST}" >&2
  exit 1
fi
IFS=':' read -r SSH_USER SSH_PORT <<< "${ALLOWED_HOSTS[$HOST]}"

if [[ $# -lt 1 ]]; then
  echo "Error: missing command (an interactive remote shell is not allowed)" >&2
  echo "Usage: ssh-broker.sh <host> <command...>" >&2
  exit 1
fi

if [[ ! -r "${KNOWN_HOSTS}" ]]; then
  echo "Error: ${KNOWN_HOSTS} is missing. Record the host key with setup.sh" >&2
  echo "(or: ssh-keyscan -p ${SSH_PORT} ${HOST} >> ${KNOWN_HOSTS}, after checking the fingerprint)." >&2
  exit 1
fi

# Audit: never the passphrase. Arguments are escaped (%q) so a newline in
# the command cannot forge a log line.
# Copy to syslog when available: a log out of reach of the user running the
# broker, hence not forgeable by the agent.
LOG_LINE="host=${HOST} cmd=$(printf '%q ' "$@")"
echo "$(date -Is) ${LOG_LINE}" >> "${LOG_FILE}"
command -v logger >/dev/null 2>&1 && logger -t ssh-broker -- "${LOG_LINE}" || true

get_passphrase() {
  if ! command -v pass >/dev/null 2>&1; then
    echo "'pass' is not installed" >&2
    return 1
  fi
  pass show "${PASS_ENTRY}" | head -1
}

flush_gpg_cache() {
  # Purge the gpg-agent cache: close the exposure window right after use
  # instead of waiting for the TTL. Important: the ENCRYPTION subkey
  # (capability 'e') is what pass/gpg decrypt with, not the primary key —
  # that is the one to purge precisely.
  local keygrip
  keygrip=$(gpg --list-secret-keys --with-keygrip --with-colons "ssh-broker-agent" 2>/dev/null | \
    awk -F: '
      $1=="ssb" && $12 ~ /e/ { want=1; next }
      want && $1=="grp" { print $10; want=0 }
    ')
  [[ -n "${keygrip}" ]] && \
    echo "CLEAR_PASSPHRASE --mode=normal ${keygrip}" | gpg-connect-agent >/dev/null 2>&1 || true
}

eval "$(ssh-agent -s)" >/dev/null
cleanup() {
  ssh-agent -k >/dev/null 2>&1 || true
  [[ -n "${ASKPASS_SCRIPT:-}" ]] && rm -f "${ASKPASS_SCRIPT}"
  [[ -n "${ASKPASS_DIR:-}" ]] && rmdir "${ASKPASS_DIR}" 2>/dev/null || true
  [[ "${FLUSH_AFTER_USE}" == "1" ]] && flush_gpg_cache
}
trap cleanup EXIT

ASKPASS_DIR=$(mktemp -d /dev/shm/sshaskpass.XXXXXX 2>/dev/null || mktemp -d)
chmod 700 "${ASKPASS_DIR}"
ASKPASS_SCRIPT="${ASKPASS_DIR}/askpass.sh"

cat > "${ASKPASS_SCRIPT}" <<'EOS'
#!/usr/bin/env bash
echo "${SSH_BROKER_PASSPHRASE}"
EOS
chmod 700 "${ASKPASS_SCRIPT}"

export SSH_ASKPASS="${ASKPASS_SCRIPT}"
export SSH_ASKPASS_REQUIRE=force
export SSH_BROKER_PASSPHRASE
SSH_BROKER_PASSPHRASE="$(get_passphrase)"

# setsid -w: wait for ssh-add to finish even if setsid has to fork, so the
# askpass script and the variable are never removed before being read.
if ! setsid -w ssh-add "${KEY_PATH}" < /dev/null > /dev/null 2>&1; then
  echo "Error: cannot load ${KEY_PATH} into ssh-agent (wrong passphrase or unreadable key)" >&2
  exit 1
fi

unset SSH_BROKER_PASSPHRASE
rm -f "${ASKPASS_SCRIPT}"
ASKPASS_SCRIPT=""

# No forwarding of any kind on the client side: what the agent may do is
# enforced server-side (restrict,command="..." in authorized_keys), but we
# explicitly close everything that is not the requested command.
ssh -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="${KNOWN_HOSTS}" \
    -o BatchMode=yes \
    -o RequestTTY=no \
    -o ForwardAgent=no \
    -o ClearAllForwardings=yes \
    -p "${SSH_PORT}" \
    "${SSH_USER}@${HOST}" \
    -- "$@"
exit $?
