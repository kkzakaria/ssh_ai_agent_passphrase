#!/usr/bin/env bash
# setup.sh — hardened version, storage in a DEDICATED `pass` store
# Run ONCE, manually, by a human.

set -euo pipefail
umask 077   # everything created here is 600/700 by default

KEY_PATH="${HOME}/.ssh/id_ed25519_agent"
PASS_ENTRY="ssh-broker/passphrase"

# GPG keyring and pass store DEDICATED to this broker: isolated from the
# user's "personal" GPG and pass, to limit the blast radius if the agent
# is compromised (it can reach ONLY this one secret, not the rest of your
# password vault).
export GNUPGHOME="${HOME}/.ssh-broker-gnupg"
export PASSWORD_STORE_DIR="${HOME}/.ssh-broker-password-store"

echo "== 0. Checking prerequisites =="
for bin in pass gpg gpg-agent gpg-connect-agent ssh ssh-keyscan setsid; do
  command -v "${bin}" >/dev/null 2>&1 || {
    echo "'${bin}' is required. Debian/Ubuntu: sudo apt install pass gnupg" >&2
    exit 1
  }
done
# SSH_ASKPASS_REQUIRE (used by ssh-broker.sh) needs OpenSSH >= 8.4.
SSH_VER=$(ssh -V 2>&1 | sed -n 's/^OpenSSH_\([0-9]*\)\.\([0-9]*\).*/\1 \2/p')
if [ -z "${SSH_VER}" ] || [ "$(echo "${SSH_VER}" | awk '{print ($1 > 8 || ($1 == 8 && $2 >= 4))}')" != "1" ]; then
  echo "OpenSSH >= 8.4 required (SSH_ASKPASS_REQUIRE). Detected: $(ssh -V 2>&1)" >&2
  exit 1
fi

echo
echo "== 1. Dedicated GPG keyring =="
mkdir -p "${GNUPGHOME}"
chmod 700 "${GNUPGHOME}"

cat > "${GNUPGHOME}/gpg-agent.conf" <<'EOF'
# Short cache: the GPG passphrase (hence access to the SSH passphrase)
# stays valid only briefly after a human entry.
default-cache-ttl 300
max-cache-ttl 900
EOF

if ! gpg --list-secret-keys "ssh-broker-agent" >/dev/null 2>&1; then
  echo "Generating a GPG key DEDICATED to this broker (not your personal GPG key)."
  echo "You will have to choose a passphrase for this key: enter it when the"
  echo "pinentry window/prompt asks for it."
  gpg --quick-generate-key "ssh-broker-agent" default default never
else
  echo "Dedicated GPG key already present."
fi

echo
echo "== 2. Dedicated pass store =="
if [ ! -d "${PASSWORD_STORE_DIR}" ]; then
  GPG_ID=$(gpg --list-secret-keys --with-colons "ssh-broker-agent" | awk -F: '/^fpr:/{print $10; exit}')
  pass init "${GPG_ID}"
fi
chmod 700 "${PASSWORD_STORE_DIR}"

echo
echo "== 3. Generating the agent's dedicated SSH key =="
if [ -f "${KEY_PATH}" ]; then
  echo "Key already exists: ${KEY_PATH}"
else
  ssh-keygen -t ed25519 -f "${KEY_PATH}" -C "ci-agent@$(hostname)"
fi
chmod 600 "${KEY_PATH}"
chmod 700 "$(dirname "${KEY_PATH}")"

echo
echo "== 4. Storing the SSH passphrase in the dedicated store =="
read -r -s -p "SSH key passphrase: " PASSPHRASE
echo
printf '%s\n' "${PASSPHRASE}" | pass insert -m "${PASS_ENTRY}" >/dev/null
unset PASSPHRASE
echo "Stored, encrypted with the dedicated GPG key."

echo
echo "== 5. Host keys of the allowed servers =="
KNOWN_HOSTS="${HOME}/.ssh-broker-known_hosts"
touch "${KNOWN_HOSTS}"
chmod 600 "${KNOWN_HOSTS}"
echo "ssh-broker.sh refuses any connection to a host missing from ${KNOWN_HOSTS}."
echo "For each entry of ALLOWED_HOSTS, enter host[:port] (empty to finish)."
echo "VERIFY every displayed fingerprint through an independent channel (server"
echo "console, provider) before accepting it."
while true; do
  read -r -p "Host to record [host:port]: " ENTRY
  [ -z "${ENTRY}" ] && break
  KH_HOST="${ENTRY%%:*}"
  KH_PORT="${ENTRY##*:}"
  [ "${KH_PORT}" = "${ENTRY}" ] && KH_PORT=22
  SCAN=$(ssh-keyscan -p "${KH_PORT}" -t ed25519,rsa,ecdsa "${KH_HOST}" 2>/dev/null || true)
  if [ -z "${SCAN}" ]; then
    echo "No key retrieved for ${KH_HOST}:${KH_PORT}." >&2
    continue
  fi
  echo "Fingerprints obtained:"
  printf '%s\n' "${SCAN}" | ssh-keygen -lf /dev/stdin
  read -r -p "Accept and record? [y/N]: " OK
  case "${OK}" in
    y|Y|yes|YES)
      printf '%s\n' "${SCAN}" >> "${KNOWN_HOSTS}"
      echo "Recorded."
      ;;
    *) echo "Skipped." ;;
  esac
done

echo
echo "== 6. Done =="
echo "Public key to add to ~/.ssh/authorized_keys on the target server:"
cat "${KEY_PATH}.pub"
echo
echo 'Restrict this entry server-side: "restrict" disables pty, forwarding,'
echo 'agent forwarding and X11; "command=" fixes the only possible action. E.g.:'
echo '  restrict,command="/opt/agent/allowed-command.sh" ssh-ed25519 AAAA... ci-agent'
echo
echo "Important reminder:"
echo "- The dedicated GPG keyring is in : ${GNUPGHOME}"
echo "- The dedicated pass store is in  : ${PASSWORD_STORE_DIR}"
echo "- Accepted host keys are in       : ${KNOWN_HOSTS}"
echo "- ssh-broker.sh must use exactly these three paths (already configured)."
echo "- For further hardening (OS-level isolation, key on a YubiKey), see the"
echo "  corresponding section of the README."
