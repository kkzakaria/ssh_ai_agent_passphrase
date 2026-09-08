#!/usr/bin/env bash
# setup.sh — version renforcée, stockage via un magasin `pass` DÉDIÉ
# À exécuter UNE SEULE FOIS, manuellement, par un humain.

set -euo pipefail
umask 077   # tout ce qui est créé ici est 600/700 par défaut

KEY_PATH="${HOME}/.ssh/id_ed25519_agent"
PASS_ENTRY="ssh-broker/passphrase"

# Magasin et trousseau GPG DÉDIÉS à ce broker : isolés du GPG et du pass
# "personnels" de l'utilisateur, pour limiter le rayon d'exposition en cas
# de compromission de l'agent (il ne peut atteindre QUE ce secret précis,
# pas le reste de votre coffre de mots de passe).
export GNUPGHOME="${HOME}/.ssh-broker-gnupg"
export PASSWORD_STORE_DIR="${HOME}/.ssh-broker-password-store"

echo "== 0. Vérification des prérequis =="
for bin in pass gpg gpg-agent gpg-connect-agent ssh ssh-keyscan setsid; do
  command -v "${bin}" >/dev/null 2>&1 || {
    echo "'${bin}' est requis. Debian/Ubuntu : sudo apt install pass gnupg" >&2
    exit 1
  }
done
# SSH_ASKPASS_REQUIRE (utilisé par ssh-broker.sh) exige OpenSSH >= 8.4.
SSH_VER=$(ssh -V 2>&1 | sed -n 's/^OpenSSH_\([0-9]*\)\.\([0-9]*\).*/\1 \2/p')
if [ -z "${SSH_VER}" ] || [ "$(echo "${SSH_VER}" | awk '{print ($1 > 8 || ($1 == 8 && $2 >= 4))}')" != "1" ]; then
  echo "OpenSSH >= 8.4 requis (SSH_ASKPASS_REQUIRE). Version détectée : $(ssh -V 2>&1)" >&2
  exit 1
fi

echo
echo "== 1. Trousseau GPG dédié =="
mkdir -p "${GNUPGHOME}"
chmod 700 "${GNUPGHOME}"

cat > "${GNUPGHOME}/gpg-agent.conf" <<'EOF'
# Cache court : la passphrase GPG (donc l'accès à la passphrase SSH)
# n'est valable que peu de temps après une saisie humaine.
default-cache-ttl 300
max-cache-ttl 900
EOF

if ! gpg --list-secret-keys "ssh-broker-agent" >/dev/null 2>&1; then
  echo "Génération d'une clé GPG DÉDIÉE à ce broker (pas votre clé GPG personnelle)."
  echo "Vous allez devoir choisir une passphrase pour cette clé : saisissez-la"
  echo "quand la fenêtre/pinentry vous le demande."
  gpg --quick-generate-key "ssh-broker-agent" default default never
else
  echo "Clé GPG dédiée déjà présente."
fi

echo
echo "== 2. Magasin pass dédié =="
if [ ! -d "${PASSWORD_STORE_DIR}" ]; then
  GPG_ID=$(gpg --list-secret-keys --with-colons "ssh-broker-agent" | awk -F: '/^fpr:/{print $10; exit}')
  pass init "${GPG_ID}"
fi
chmod 700 "${PASSWORD_STORE_DIR}"

echo
echo "== 3. Génération de la clé SSH dédiée à l'agent =="
if [ -f "${KEY_PATH}" ]; then
  echo "La clé existe déjà : ${KEY_PATH}"
else
  ssh-keygen -t ed25519 -f "${KEY_PATH}" -C "ci-agent@$(hostname)"
fi
chmod 600 "${KEY_PATH}"
chmod 700 "$(dirname "${KEY_PATH}")"

echo
echo "== 4. Stockage de la passphrase SSH dans le magasin dédié =="
read -r -s -p "Passphrase de la clé SSH: " PASSPHRASE
echo
printf '%s\n' "${PASSPHRASE}" | pass insert -m "${PASS_ENTRY}" >/dev/null
unset PASSPHRASE
echo "Stockée, chiffrée par la clé GPG dédiée."

echo
echo "== 5. Clés d'hôte des serveurs autorisés =="
KNOWN_HOSTS="${HOME}/.ssh-broker-known_hosts"
touch "${KNOWN_HOSTS}"
chmod 600 "${KNOWN_HOSTS}"
echo "ssh-broker.sh refuse toute connexion à un hôte absent de ${KNOWN_HOSTS}."
echo "Pour chaque entrée de ALLOWED_HOSTS, saisissez hote[:port] (vide pour terminer)."
echo "VÉRIFIEZ chaque empreinte affichée par un canal indépendant (console du"
echo "serveur, fournisseur) avant de l'accepter."
while true; do
  read -r -p "Hôte à enregistrer [hote:port] : " ENTRY
  [ -z "${ENTRY}" ] && break
  KH_HOST="${ENTRY%%:*}"
  KH_PORT="${ENTRY##*:}"
  [ "${KH_PORT}" = "${ENTRY}" ] && KH_PORT=22
  SCAN=$(ssh-keyscan -p "${KH_PORT}" -t ed25519,rsa,ecdsa "${KH_HOST}" 2>/dev/null || true)
  if [ -z "${SCAN}" ]; then
    echo "Aucune clé récupérée pour ${KH_HOST}:${KH_PORT}." >&2
    continue
  fi
  echo "Empreintes obtenues :"
  printf '%s\n' "${SCAN}" | ssh-keygen -lf /dev/stdin
  read -r -p "Accepter et enregistrer ? [o/N] : " OK
  case "${OK}" in
    o|O|oui|OUI)
      printf '%s\n' "${SCAN}" >> "${KNOWN_HOSTS}"
      echo "Enregistré."
      ;;
    *) echo "Ignoré." ;;
  esac
done

echo
echo "== 6. Terminé =="
echo "Clé publique à ajouter dans ~/.ssh/authorized_keys du serveur cible :"
cat "${KEY_PATH}.pub"
echo
echo 'Restreignez cette entrée côté serveur : "restrict" coupe pty, redirections,'
echo 'transfert d agent et X11 ; "command=" fixe la seule action possible. Ex :'
echo '  restrict,command="/opt/agent/allowed-command.sh" ssh-ed25519 AAAA... ci-agent'
echo
echo "Rappel important :"
echo "- Le trousseau GPG dédié est dans : ${GNUPGHOME}"
echo "- Le magasin pass dédié est dans  : ${PASSWORD_STORE_DIR}"
echo "- Les clés d'hôte acceptées sont dans : ${KNOWN_HOSTS}"
echo "- ssh-broker.sh doit utiliser exactement ces trois chemins (déjà configuré)."
echo "- Pour un renforcement supplémentaire (isolation au niveau OS, clé sur"
echo "  YubiKey), voir la section correspondante du README."
