#!/usr/bin/env bash
# Exercises install-skill.sh in a throwaway HOME: links created, rerun is a
# no-op, a foreign file at a target path is never overwritten, and the
# installed ssh-broker command actually reaches the broker.
#
# Usage: bash tests/install-skill.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="${REPO}/install-skill.sh"

export HOME
HOME="$(mktemp -d)"
trap 'rm -rf "${HOME}"' EXIT
SKILL_LINK="${HOME}/.claude/skills/ssh-broker"
BIN_LINK="${HOME}/.local/bin/ssh-broker"

fail=0
ok()   { echo "ok   $1"; }
bad()  { echo "FAIL $1"; fail=1; }
link_to() { [[ -L "$1" && "$(readlink -f "$1")" == "$2" ]]; }

# 1. fresh install creates both links
if bash "${INSTALLER}" >/dev/null 2>&1; then ok "install exits 0"; else bad "install exits non-zero"; fi
link_to "${SKILL_LINK}" "${REPO}/skills/ssh-broker" && ok "skill link points into the repo" || bad "skill link missing or wrong"
link_to "${BIN_LINK}" "${REPO}/ssh-broker.sh"          && ok "bin link points to ssh-broker.sh" || bad "bin link missing or wrong"

# 2. rerun is idempotent
if bash "${INSTALLER}" >/dev/null 2>&1; then ok "rerun exits 0"; else bad "rerun exits non-zero"; fi
link_to "${SKILL_LINK}" "${REPO}/skills/ssh-broker" && link_to "${BIN_LINK}" "${REPO}/ssh-broker.sh" \
  && ok "rerun keeps both links" || bad "rerun changed the links"

# 3. the installed command reaches the broker
printf 'deploy.myserver.example deploy 22\n' > "${HOME}/.ssh-broker-hosts"; chmod 600 "${HOME}/.ssh-broker-hosts"
out="$(PATH="${HOME}/.local/bin:${PATH}" ssh-broker --list-hosts 2>/dev/null)"
[[ "${out}" == "deploy.myserver.example" ]] && ok "ssh-broker --list-hosts works through the link" || bad "ssh-broker via link: got '${out}'"

# 4. a foreign file at a target path is refused and left alone
rm -f "${BIN_LINK}"; echo "not ours" > "${BIN_LINK}"
if bash "${INSTALLER}" >/dev/null 2>"${HOME}/err"; then bad "foreign file: installer should fail"; else ok "foreign file: installer fails"; fi
grep -q "already exists" "${HOME}/err" && ok "foreign file: explains the conflict" || bad "foreign file: no explanation"
[[ "$(cat "${BIN_LINK}")" == "not ours" ]] && ok "foreign file untouched" || bad "foreign file was overwritten"

exit "${fail}"
