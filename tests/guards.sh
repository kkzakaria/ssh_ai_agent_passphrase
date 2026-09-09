#!/usr/bin/env bash
# Exercises ssh-broker.sh without a server, a key, or a passphrase. Covers the
# hosts file checks, the guards that stop the broker before any GPG access
# (in their documented order), --list-hosts, and one call that gets past the
# guards to check the log file and the stop at pass on an empty throwaway
# store.
#
# Usage: bash tests/guards.sh

set -uo pipefail

BROKER="$(cd "$(dirname "$0")/.." && pwd)/ssh-broker.sh"
HOST_A="deploy.myserver.example"
HOST_B="backup.myserver.example"

export HOME
HOME="$(mktemp -d)"
trap 'rm -rf "${HOME}"' EXIT
HOSTS_FILE="${HOME}/.ssh-broker-hosts"

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
no_log() {
  [[ -e "${HOME}/.ssh-broker.log" ]] && { echo "FAIL $1: must not log"; fail=1; } || echo "ok   $1: no log"
}
write_hosts() { printf '%s\n' "$@" > "${HOSTS_FILE}"; chmod 600 "${HOSTS_FILE}"; }

# --- hosts file checks: all refuse before the allowlist is even consulted
check "hosts file required"         1 "hosts file"      -- --list-hosts
write_hosts "${HOST_A} deploy 22"; chmod 666 "${HOSTS_FILE}"
check "world-writable hosts file"   1 "writable"        -- --list-hosts
chmod 620 "${HOSTS_FILE}"
check "group-writable hosts file"   1 "writable"        -- --list-hosts
rm -f "${HOSTS_FILE}"; printf '%s deploy 22\n' "${HOST_A}" > "${HOME}/real"; chmod 600 "${HOME}/real"
ln -s "${HOME}/real" "${HOSTS_FILE}"
check "symlinked hosts file"        1 "symlink"         -- --list-hosts
rm -f "${HOSTS_FILE}" "${HOME}/real"
# Owner mismatch: needs a regular file owned by someone else at a fixed path.
# A user namespace plus a bind mount of a root-owned file gives exactly that
# without root. Skipped, not failed, where user namespaces are unavailable.
if unshare -Urm true 2>/dev/null; then
  touch "${HOSTS_FILE}"
  err=$(unshare -Urm bash -c "mount --bind /etc/hostname '${HOSTS_FILE}' && bash '${BROKER}' --list-hosts" 2>&1 >/dev/null); code=$?
  if [[ "${code}" -eq 1 && "${err}" == *"owned by the current user"* ]]; then
    echo "ok   foreign-owned hosts file"
  else
    echo "FAIL foreign-owned hosts file: exit ${code}"; echo "  got: ${err}"; fail=1
  fi
  rm -f "${HOSTS_FILE}"
else
  echo "skip foreign-owned hosts file (needs unshare -Urm)"
fi
write_hosts "${HOST_A} deploy"
check "malformed line refused"      1 "line 1"          -- --list-hosts
write_hosts "${HOST_A} deploy abc"
check "non-numeric port refused"    1 "line 1"          -- --list-hosts
write_hosts "# only a comment" ""
check "empty allowlist refused"     1 "no host"         -- --list-hosts
no_log "hosts file checks"

# --- valid file: comments and blank lines ignored, hosts listed sorted
write_hosts "# comment" "" "${HOST_B} backup 2222" "  ${HOST_A}   deploy 22  "
check "--list-hosts exits 0"        0 ""                -- --list-hosts
if [[ "${LAST_OUT:-}" != "${HOST_B}"$'\n'"${HOST_A}" ]]; then
  echo "FAIL --list-hosts output: got '${LAST_OUT:-}'"; fail=1
else
  echo "ok   --list-hosts prints sorted hosts, skips comments"
fi

# --- guards, in order
check "unlisted host refused"       1 "host not allowed" -- not.allowed.example uptime
check "missing command refused"     1 "missing command"  -- "${HOST_A}"
check "known_hosts required"        1 "is missing"       -- "${HOST_A}" uptime
no_log "guards"

# Past the guards the broker logs, then asks pass. Without pass installed it
# says so; with pass installed the empty throwaway store has no entry. Either
# proves the call got past the guards and logged.
touch "${HOME}/.ssh-broker-known_hosts"
if command -v pass >/dev/null 2>&1; then
  check "logs then asks pass"       1 "is not in the password store" -- "${HOST_A}" uptime
else
  check "logs then needs pass"      1 "'pass' is not installed"       -- "${HOST_A}" uptime
fi
if [[ "$(stat -c '%a' "${HOME}/.ssh-broker.log" 2>/dev/null)" != "600" ]]; then
  echo "FAIL log file must be mode 600"; fail=1
else
  echo "ok   log file is mode 600"
fi

# --- exit status contract: the EXIT trap must not clobber the remote
# command's status. The trap runs after ssh, under set -e, so a failing
# conditional at the end of cleanup() would turn every exit into 1. Exercise
# cleanup() as defined in the broker, with the flush disabled and enabled.
CLEANUP_SRC="$(awk '/^flush_gpg_cache\(\) \{/,/^\}/; /^cleanup\(\) \{/,/^\}/' "${BROKER}")"
for flush in 0 1; do
  code=$(bash -c "set -euo pipefail; FLUSH_AFTER_USE=${flush}; ASKPASS_SCRIPT=''; ASKPASS_DIR=''
    ssh-agent() { :; }; gpg() { :; }; gpg-connect-agent() { :; }
    ${CLEANUP_SRC}
    trap cleanup EXIT; exit 7" 2>/dev/null; echo $?)
  if [[ "${code}" == "7" ]]; then
    echo "ok   cleanup trap preserves exit status (flush=${flush})"
  else
    echo "FAIL cleanup trap changed exit 7 into ${code} (flush=${flush})"; fail=1
  fi
done
# The flush is best-effort: a failing gpg inside it must not abort cleanup.
code=$(bash -c "set -euo pipefail; FLUSH_AFTER_USE=1; ASKPASS_SCRIPT=''; ASKPASS_DIR=''
  ssh-agent() { :; }; gpg() { return 1; }; gpg-connect-agent() { :; }
  ${CLEANUP_SRC}
  trap cleanup EXIT; exit 7" 2>/dev/null; echo $?)
if [[ "${code}" == "7" ]]; then
  echo "ok   cleanup trap survives a failing gpg during flush"
else
  echo "FAIL cleanup trap with failing gpg changed exit 7 into ${code}"; fail=1
fi

exit "${fail}"
