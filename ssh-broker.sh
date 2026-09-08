#!/usr/bin/env bash
# ssh-broker.sh — version renforcée
#
# Outil exposé à l'agent IA (via function calling / tool use) comme une
# simple commande shell : ssh-broker.sh <host> <commande...>
#
# Prérequis : OpenSSH >= 8.4 (SSH_ASKPASS_REQUIRE), util-linux (setsid -w).

set -euo pipefail
umask 077   # journal et fichiers temporaires jamais lisibles par d'autres utilisateurs

# PATH figé : les binaires (pass, gpg, ssh, ssh-agent, setsid) ne peuvent pas
# être substitués via un PATH manipulé par l'appelant.
export PATH="/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"

KEY_PATH="${HOME}/.ssh/id_ed25519_agent"
PASS_ENTRY="ssh-broker/passphrase"
LOG_FILE="${HOME}/.ssh-broker.log"

# Fichier known_hosts DÉDIÉ, rempli par setup.sh après vérification humaine
# des empreintes. Le broker n'écrit jamais dedans (StrictHostKeyChecking=yes).
KNOWN_HOSTS="${HOME}/.ssh-broker-known_hosts"

# Mêmes trousseau/magasin DÉDIÉS que setup.sh — isolés du GPG/pass
# personnels de l'utilisateur.
export GNUPGHOME="${HOME}/.ssh-broker-gnupg"
export PASSWORD_STORE_DIR="${HOME}/.ssh-broker-password-store"

# Si SSH_BROKER_FLUSH_GPG_CACHE=1, la passphrase GPG est purgée du cache
# immédiatement après chaque appel : posture la plus sûre, mais impose
# une nouvelle saisie humaine (pinentry) à chaque invocation de l'agent.
# Par défaut (0), on s'appuie sur le TTL court défini dans gpg-agent.conf
# (5 min) pour permettre plusieurs appels automatisés d'affilée après une
# seule saisie humaine.
FLUSH_AFTER_USE="${SSH_BROKER_FLUSH_GPG_CACHE:-0}"

declare -A ALLOWED_HOSTS=(
  ["deploy.monserveur.example"]="deploy:22"
)

HOST="${1:?Usage: ssh-broker.sh <host> <commande...>}"
shift

if [[ -z "${ALLOWED_HOSTS[$HOST]+x}" ]]; then
  echo "Erreur : hôte non autorisé : ${HOST}" >&2
  exit 1
fi
IFS=':' read -r SSH_USER SSH_PORT <<< "${ALLOWED_HOSTS[$HOST]}"

if [[ $# -lt 1 ]]; then
  echo "Erreur : commande manquante (un shell interactif distant n'est pas autorisé)" >&2
  echo "Usage: ssh-broker.sh <host> <commande...>" >&2
  exit 1
fi

if [[ ! -r "${KNOWN_HOSTS}" ]]; then
  echo "Erreur : ${KNOWN_HOSTS} absent. Enregistrez la clé d'hôte via setup.sh" >&2
  echo "(ou : ssh-keyscan -p ${SSH_PORT} ${HOST} >> ${KNOWN_HOSTS}, après vérification de l'empreinte)." >&2
  exit 1
fi

# Audit : jamais la passphrase. Les arguments sont échappés (%q) pour qu'un
# retour à la ligne dans la commande ne puisse pas forger de ligne de journal.
# Copie vers syslog quand disponible : un journal hors de portée de l'utilisateur
# qui exécute le broker, donc non falsifiable par l'agent.
LOG_LINE="host=${HOST} cmd=$(printf '%q ' "$@")"
echo "$(date -Is) ${LOG_LINE}" >> "${LOG_FILE}"
command -v logger >/dev/null 2>&1 && logger -t ssh-broker -- "${LOG_LINE}" || true

get_passphrase() {
  if ! command -v pass >/dev/null 2>&1; then
    echo "'pass' n'est pas installé" >&2
    return 1
  fi
  pass show "${PASS_ENTRY}" | head -1
}

flush_gpg_cache() {
  # Purge le cache gpg-agent : referme la fenêtre d'exposition immédiatement
  # après usage plutôt que d'attendre le TTL. Important : c'est la sous-clé
  # de CHIFFREMENT (capacité 'e') qui sert au déchiffrement pass/gpg, pas la
  # clé primaire — il faut purger celle-ci précisément.
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

# setsid -w : attend la fin de ssh-add même si setsid doit forker, pour que
# le script askpass et la variable ne soient jamais supprimés avant lecture.
if ! setsid -w ssh-add "${KEY_PATH}" < /dev/null > /dev/null 2>&1; then
  echo "Erreur : impossible de charger ${KEY_PATH} dans ssh-agent (passphrase incorrecte ou clé illisible)" >&2
  exit 1
fi

unset SSH_BROKER_PASSPHRASE
rm -f "${ASKPASS_SCRIPT}"
ASKPASS_SCRIPT=""

# Aucune redirection ni transfert d'agent côté client : le contrôle de ce que
# l'agent peut faire se fait côté serveur (restrict,command="..." dans
# authorized_keys), mais on ferme explicitement tout ce qui n'est pas la
# commande demandée.
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
