#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'HELP'
Usage: bash index.sh (--account USER ... | --all) [options]
  --folder MAILBOX    Index one literal mailbox per account (default: all folders).
  --shared            Also enumerate and index shared folders with ACL read rights.
  --min-free-gib N    Check this reserve between jobs (default: 0).
  --apply             Run indexing. By default, only print the target list.
  --help              Show this help.
MAILCOW_DIR defaults to /opt/mailcow-dockerized.
HELP
}

accounts=()
all=0
apply=0
shared=0
folder=
reserve=0
while (( $# )); do
  case $1 in
    --account|--folder|--min-free-gib)
      option=$1
      if (( $# < 2 )) || [[ -z $2 || $2 == --* ]]; then
        printf 'Missing value for %s.\n' "$option" >&2
        exit 2
      fi
      case $option in
        --account) accounts+=("$2") ;;
        --folder) folder=$2 ;;
        --min-free-gib) reserve=$2 ;;
      esac
      shift 2 ;;
    --all) all=1; shift ;;
    --shared) shared=1; shift ;;
    --apply) apply=1; shift ;;
    --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

if (( (all && ${#accounts[@]}) || (!all && !${#accounts[@]}) || (shared && ${#folder}) )) ||
   [[ ! $reserve =~ ^(0|[1-9][0-9]{0,6})$ || $folder == *[\*\?%]* || $folder == -* ]]; then
  usage >&2
  exit 2
fi

cd -- "${MAILCOW_DIR:-/opt/mailcow-dockerized}"
compose=(docker compose exec -T dovecot-mailcow)
if (( all || shared )); then
  account_list=$("${compose[@]}" doveadm user '*' |
    awk 'NF && tolower($0) !~ /@mailcow[.]local$/' | LC_ALL=C sort -u)
  mapfile -t owners <<< "${account_list:?Dovecot returned no mail users}"
  if (( all )); then accounts=("${owners[@]}"); fi
fi

for account in "${accounts[@]}"; do
  if [[ ! $account =~ ^[^[:space:]@*?%]+@[^[:space:]@*?%]+$ ]]; then
    printf 'Invalid literal address: %s\n' "$account" >&2
    exit 2
  fi
  "${compose[@]}" doveadm user -f home "$account" >/dev/null
done

patterns=()
if (( shared )); then
  for owner in "${owners[@]}"; do
    if [[ ! $owner =~ ^[^[:space:]@*?%]+@[^[:space:]@*?%]+$ ]]; then
      printf 'Unsupported shared owner name: %s\n' "$owner" >&2
      exit 2
    fi
    patterns+=("Shared/$owner/*")
  done
fi

if (( apply )); then
  if ! "${compose[@]}" cat /etc/dovecot/mail_plugins_imap |
    grep -w fts_flatcurve >/dev/null; then
    printf '%s\n' 'Flatcurve was not found in the Mailcow Dovecot 2.3 IMAP plugin list.' >&2
    exit 1
  fi
fi

index_folder() {
  local account=$1 target=$2 available_kib
  printf '%s\t%s\n' "$account" "$target"
  if (( !apply )); then return 0; fi

  available_kib=$("${compose[@]}" df -Pk /var/vmail_index /var/vmail |
    awk 'NR > 1 && $4 ~ /^[0-9]+$/ {
           if (!rows || $4+0 < min) min=$4+0
           rows++
         }
         END { if (rows != 2) exit 1; printf "%.0f\n", min }')
  if (( available_kib <= reserve * 1024 * 1024 )); then
    printf 'Free-space threshold reached before %s / %s (%s GiB reserve).\n' \
      "$account" "$target" "$reserve" >&2
    exit 1
  fi
  "${compose[@]}" doveadm -v index -u "$account" "$target" </dev/null
}

printf 'Host: %s\n' "$(hostname)"
for account in "${accounts[@]}"; do
  index_folder "$account" "${folder:-*}"
  if (( !shared )); then continue; fi

  folders=$("${compose[@]}" doveadm mailbox list -8 -u "$account" "${patterns[@]}" |
    awk -F / '$1 == "Shared" && NF >= 3 && $3 != ""' | LC_ALL=C sort -u)
  while IFS= read -r shared_folder; do
    [[ -n $shared_folder ]] || continue
    if [[ $shared_folder == *[\*\?%]* ]]; then
      printf 'Unsupported shared mailbox name: %s\n' "$shared_folder" >&2
      exit 2
    fi
    rights=$("${compose[@]}" doveadm acl rights -u "$account" "$shared_folder" </dev/null)
    if grep -w read <<< "$rights" >/dev/null; then
      index_folder "$account" "$shared_folder"
    fi
  done <<< "$folders"
done

if (( apply )); then
  "${compose[@]}" df -hT /var/vmail /var/vmail_index
fi
