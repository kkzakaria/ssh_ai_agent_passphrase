# SSH Broker — version bash renforcée (stockage `pass`)

Version durcie par rapport à la précédente. Objectif : réduire l'écart
avec `secret-tool`/`security`, qui offrent nativement une isolation par
application et un verrouillage lié à la session.

## Ce qui a changé par rapport à la version simple

| Mesure | Avant | Renforcé |
|---|---|---|
| Clé GPG | personnelle, potentiellement sans passphrase | **dédiée**, protégée par passphrase |
| Magasin `pass` | `~/.password-store` (partagé avec tous vos autres mots de passe) | **dédié** (`~/.ssh-broker-password-store`), isolé de vos autres secrets |
| Cache GPG | TTL par défaut (souvent longue) | **TTL court** : 5 min (300s) / 15 min max (900s) |
| Fenêtre d'exposition | dépend uniquement du TTL | **purge active** du cache possible immédiatement après chaque appel |
| Permissions | par défaut | `umask 077` dans les deux scripts, `chmod 700` sur trousseau + magasin dédiés |
| Clés d'hôte | `~/.ssh/known_hosts` partagé, modifiable par l'agent | fichier **dédié** `~/.ssh-broker-known_hosts`, rempli par un humain après vérification des empreintes |
| Journal | fichier local seul | fichier local (600) **et** syslog via `logger`, hors de portée de l'agent ; arguments échappés |
| Session distante | commande libre | commande obligatoire, `RequestTTY=no`, `ForwardAgent=no`, `ClearAllForwardings=yes` |
| PATH | hérité de l'appelant | figé en tête du broker |

## Pourquoi un trousseau et un magasin dédiés

`pass` ne fait pas de contrôle d'accès par application : tout process qui
parle au bon `gpg-agent` peut déchiffrer tout ce que ce trousseau protège.
En isolant la clé GPG et le magasin *uniquement* pour ce broker (plutôt
que de réutiliser votre `pass` personnel), on limite le rayon de
compromission : si l'agent IA est détourné, il ne peut atteindre que
**cette seule passphrase SSH**, jamais vos autres identifiants.

## Deux postures possibles pour la fenêtre d'exposition

```bash
# Posture "automatisation" (par défaut) : un humain saisit la passphrase
# GPG une fois, l'agent IA peut ensuite appeler ssh-broker.sh plusieurs
# fois sans interaction, tant que le TTL (5 min) n'est pas expiré.
./ssh-broker.sh deploy.monserveur.example "uptime"

# Posture "sécurité maximale" : purge le cache GPG immédiatement après
# CHAQUE appel. Un humain doit resaisir la passphrase à chaque invocation
# de l'agent — à réserver aux actions sensibles, pas à un usage en boucle.
SSH_BROKER_FLUSH_GPG_CACHE=1 ./ssh-broker.sh deploy.monserveur.example "uptime"
```

## Installation

```bash
chmod +x setup.sh ssh-broker.sh
sudo apt install pass gnupg   # ou : brew install pass gnupg

./setup.sh
# -> vérifie OpenSSH >= 8.4 et la présence de setsid
# -> génère une clé GPG dédiée (vous choisissez sa passphrase)
# -> initialise un magasin pass dédié
# -> génère la clé SSH et y stocke sa passphrase
# -> enregistre les clés d'hôte de vos serveurs dans ~/.ssh-broker-known_hosts
#    après affichage des empreintes : vérifiez-les par un canal indépendant

# Ajoutez la clé publique affichée dans ~/.ssh/authorized_keys du serveur,
# précédée de restrict,command="..." (voir ci-dessous)
# Éditez ALLOWED_HOSTS dans ssh-broker.sh avec vos vrais serveurs
```

Le broker refuse tout hôte absent de `~/.ssh-broker-known_hosts` et n'y
écrit jamais. Pour ajouter un serveur plus tard, relancez `setup.sh` (les
étapes déjà faites sont sautées) ou ajoutez la ligne manuellement après
vérification de l'empreinte.

## Pour aller plus loin : isolation au niveau OS

Le vrai avantage de `secret-tool`/`security` reste l'**ACL par
application**, que `pass` ne peut pas répliquer nativement (tout ce qui
tourne sous le même utilisateur système accède au même `gpg-agent`). Pour
s'en rapprocher, la mesure la plus efficace est d'isoler le broker dans
un **utilisateur système dédié**, distinct de celui qui exécute l'agent
IA, et de n'autoriser qu'un appel précis via `sudo` :

```bash
# En root, une fois :
useradd --system --home /opt/ssh-broker --shell /usr/sbin/nologin sshbroker
# Exécutez setup.sh et déplacez les fichiers sous cet utilisateur

# Dans /etc/sudoers.d/ssh-broker (via visudo -f) :
agentuser ALL=(sshbroker) NOPASSWD: /opt/ssh-broker/ssh-broker.sh
```

L'agent IA (tournant sous `agentuser`) appelle alors :
```bash
sudo -u sshbroker /opt/ssh-broker/ssh-broker.sh deploy.monserveur.example "uptime"
```
Il ne peut exécuter *que* ce script précis, avec des arguments qu'il
choisit, mais n'a physiquement aucun accès au `gpg-agent` ni au magasin
`pass` de l'utilisateur `sshbroker` — l'équivalent le plus proche, en
pur Unix, du contrôle d'accès par application des trousseaux natifs.

**Option supérieure** : héberger la clé GPG sur une **YubiKey** (applet
OpenPGP). La clé privée ne quitte alors jamais le matériel, et chaque
déchiffrement peut exiger une confirmation physique (touch) — c'est
l'équivalent du Secure Enclave côté macOS, et strictement plus fort que
n'importe quelle solution purement logicielle.

## Points d'attention généraux (inchangés)

- `~/.ssh-broker.log` trace host + commande pour audit, jamais la passphrase.
  Ce fichier appartient à l'utilisateur qui exécute le broker, donc un agent
  compromis peut le modifier : la copie envoyée à syslog (`logger -t
  ssh-broker`) est la trace de référence.
- Le broker contrôle **où** l'agent se connecte, pas **ce qu'il** exécute :
  la commande distante est entièrement choisie par l'agent. Le seul contrôle
  du « quoi » se fait côté serveur, dans `authorized_keys` :
  `restrict,command="/opt/agent/allowed-command.sh"`. `restrict` coupe pty,
  redirections, transfert d'agent et X11 ; `command=` fixe l'unique action
  possible.
- `ALLOWED_HOSTS` doit rester la seule source de vérité des destinations
  autorisées — ne laissez pas l'agent le modifier.
- Sauvegardez `~/.ssh-broker-gnupg` et `~/.ssh-broker-password-store` :
  leur perte rend la passphrase SSH irrécupérable.
