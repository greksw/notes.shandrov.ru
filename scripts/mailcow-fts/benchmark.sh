#!/usr/bin/env bash
set -euo pipefail

if [[ ${1:-} == --help || $# -lt 1 || $# -gt 2 ]]; then
  printf '%s\n' 'Usage: bash benchmark.sh USER [MAILBOX]' 'Enter an IMAP BODY search term when prompted.'
  if [[ ${1:-} == --help ]]; then exit 0; fi
  exit 2
fi

account=$1
folder=${2:-INBOX}
if [[ ! $account =~ ^[^[:space:]@*?%]+@[^[:space:]@*?%]+$ ||
      $folder == *[\*\?%]* || $folder == -* ]]; then
  printf '%s\n' 'Specify a full address and one literal mailbox name.' >&2
  exit 2
fi
read -r -p 'Word from the body of a known message: ' search_word
if [[ -z ${search_word//[[:space:]]/} ]]; then
  printf '%s\n' 'The search term is empty.' >&2
  exit 2
fi

cd -- "${MAILCOW_DIR:-/opt/mailcow-dockerized}"
TIMEFORMAT='Elapsed: %3R seconds'
if time matches=$(docker compose exec -T dovecot-mailcow \
  doveadm search -u "$account" MAILBOX "$folder" BODY "$search_word" |
  awk 'NF >= 2 && $NF ~ /^[0-9]+$/ { count++ } END { print count+0 }'); then
  printf 'Matches: %s\n' "$matches"
else
  printf '%s\n' 'Dovecot search failed. The match count is unavailable.' >&2
  exit 1
fi
