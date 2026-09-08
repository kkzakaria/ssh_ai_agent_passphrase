#!/usr/bin/env bash
# Exercises every path of ssh-broker.sh that must terminate before any GPG
# access. Runs without pass, gpg, or a reachable server: every case below is
# expected to fail early, in the documented order, or to answer --list-hosts.
#
# Usage: bash tests/guards.sh

set -uo pipefail

BROKER="$(cd "$(dirname "$0")/.." && pwd)/ssh-broker.sh"
PLACEHOLDER_HOST="deploy.myserver.example"

export HOME
HOME="$(mktemp -d)"
trap 'rm -rf "${HOME}"' EXIT

fail=0
check() {
  # check <label> <expected-exit> <expected-stderr-substring> -- <args...>
  local label="$1" want_exit="$2" want_err="$3"; shift 3; shift  # drop --
  local out err code
  out="$(bash "${BROKER}" "$@" 2>/tmp/guards.err.$$)"; code=$?
  err="$(cat /tmp/guards.err.$$)"; rm -f /tmp/guards.err.$$
  if [[ "${code}" -ne "${want_exit}" ]]; then
    echo "FAIL ${label}: exit ${code}, wanted ${want_exit}"; fail=1; return
  fi
  if [[ -n "${want_err}" && "${err}" != *"${want_err}"* ]]; then
    echo "FAIL ${label}: stderr lacks '${want_err}'"; echo "  got: ${err}"; fail=1; return
  fi
  echo "ok   ${label}"
  LAST_OUT="${out}"
}

check "unlisted host refused"   1 "host not allowed"   -- not.allowed.example uptime
check "missing command refused" 1 "missing command"    -- "${PLACEHOLDER_HOST}"
check "known_hosts required"    1 "is missing"         -- "${PLACEHOLDER_HOST}" uptime
[[ -e "${HOME}/.ssh-broker.log" ]] && { echo "FAIL guards must not log"; fail=1; }

check "--list-hosts exits 0"    0 ""                   -- --list-hosts
if [[ "${LAST_OUT:-}" != "${PLACEHOLDER_HOST}" ]]; then
  echo "FAIL --list-hosts output: got '${LAST_OUT:-}', wanted '${PLACEHOLDER_HOST}'"; fail=1
else
  echo "ok   --list-hosts prints allowed hosts"
fi
[[ -e "${HOME}/.ssh-broker.log" ]] && { echo "FAIL --list-hosts must not log"; fail=1; }

# Past the guards the broker logs, then asks pass. Without pass installed it
# says so; with pass installed the empty throwaway store has no entry. Either
# proves the call got past the guards and logged.
touch "${HOME}/.ssh-broker-known_hosts"
if command -v pass >/dev/null 2>&1; then
  check "logs then asks pass"   1 "is not in the password store" -- "${PLACEHOLDER_HOST}" uptime
else
  check "logs then needs pass"  1 "'pass' is not installed"       -- "${PLACEHOLDER_HOST}" uptime
fi
if [[ "$(stat -c '%a' "${HOME}/.ssh-broker.log" 2>/dev/null)" != "600" ]]; then
  echo "FAIL log file must be mode 600"; fail=1
else
  echo "ok   log file is mode 600"
fi

exit "${fail}"
