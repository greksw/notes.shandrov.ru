#!/usr/bin/env bash
set -euo pipefail

if [[ ${1:-} == --help ]]; then
  printf '%s\n' 'Usage: MAILCOW_DIR=/opt/mailcow-dockerized bash status.sh'
  exit 0
fi
if (( $# != 0 )); then
  printf '%s\n' 'Unexpected arguments. See --help.' >&2
  exit 2
fi

cd -- "${MAILCOW_DIR:-/opt/mailcow-dockerized}"
compose=(docker compose exec -T dovecot-mailcow)
printf 'Host: %s\n' "$(hostname)"
free -h
printf '\nEffective Dovecot settings\n'
"${compose[@]}" dovecot --version
"${compose[@]}" sh -c '
  for key in SKIP_FTS SKIP_SOLR FTS_HEAP FTS_PROCS; do
    if value=$(printenv "$key"); then printf "%s=%s\n" "$key" "$value"; fi
  done
  if [ -r /etc/dovecot/mail_plugins_imap ]; then
    printf "IMAP plugins: "
    cat /etc/dovecot/mail_plugins_imap
    printf "\n"
  fi
'
"${compose[@]}" doveconf -n |
  sed -n -e '/^[[:space:]]*fts[[:space:]_]/p' -e '/^service indexer-worker {/,/^}/p'
printf '\nMail and index filesystems\n'
"${compose[@]}" df -hT /var/vmail /var/vmail_index
