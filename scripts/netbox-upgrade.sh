#!/usr/bin/env bash
# NetBox release-archive/Git installation maintenance helper.
# Uses upstream /opt/netbox/upgrade.sh; NEVER attempts an automatic DB rollback.
set -Eeuo pipefail

MODE=''
TARGET=''
ROOT='/opt/netbox'
PYTHON='/usr/bin/python3.12'
BACKUP_BASE='/root/netbox-backups'
DB='netbox'
TLS_CERT=''
TLS_KEY=''
URL=''
CONFIRM='false'

usage() {
  cat <<'EOF'
Usage:
  sudo ./netbox-upgrade.sh --check --target v4.7.3 [options]
  sudo ./netbox-upgrade.sh --apply --target v4.7.3 --confirm [options]

Options:
  --check              Read-only local preflight (does not fetch or alter services)
  --apply              Backup, fetch tags, stop services and upgrade
  --target TAG         Explicit release tag, e.g. v4.7.3
  --confirm            Required with --apply
  --root DIR           Git checkout (default: /opt/netbox)
  --python PATH        Python executable (default: /usr/bin/python3.12)
  --backup-dir DIR     Root-owned backup directory (default: /root/netbox-backups)
  --database NAME      PostgreSQL database (default: netbox)
  --tls-cert PATH      Optional TLS certificate to include in secured archive
  --tls-key PATH       Optional TLS private key to include in secured archive
  --url URL            Optional HTTPS probe after upgrade; uses host CA trust, no -k
  --help               Show help

Before running --apply, inspect release notes and confirm plugin compatibility,
maintenance window and OFF-HOST backups. This script does not schedule upgrades.
EOF
}

while (($#)); do
  case "$1" in
    --check) MODE='check'; shift ;;
    --apply) MODE='apply'; shift ;;
    --target|--root|--python|--backup-dir|--database|--tls-cert|--tls-key|--url)
      (($# >= 2)) || { echo "Missing value for $1" >&2; exit 2; }
      key="$1"; val="$2"; shift 2
      case "$key" in
        --target) TARGET="$val" ;;
        --root) ROOT="$val" ;;
        --python) PYTHON="$val" ;;
        --backup-dir) BACKUP_BASE="$val" ;;
        --database) DB="$val" ;;
        --tls-cert) TLS_CERT="$val" ;;
        --tls-key) TLS_KEY="$val" ;;
        --url) URL="$val" ;;
      esac ;;
    --confirm) CONFIRM='true'; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unsupported argument: $1" >&2; usage; exit 2 ;;
  esac
done

[[ $MODE == 'check' || $MODE == 'apply' ]] || { usage; exit 2; }
[[ $TARGET =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Target must be exact vX.Y.Z tag' >&2; exit 2; }
[[ $DB =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || { echo 'Invalid database name' >&2; exit 2; }
[[ $EUID -eq 0 ]] || { echo 'Run as root with sudo' >&2; exit 1; }
[[ $ROOT == /* && $BACKUP_BASE == /* && $PYTHON == /* ]] || { echo 'Absolute paths required' >&2; exit 2; }
[[ -z $URL || $URL =~ ^https://[^[:space:]]+$ ]] || { echo 'Only HTTPS URLs supported' >&2; exit 2; }
[[ -z $TLS_CERT || $TLS_CERT == /* ]] && [[ -z $TLS_KEY || $TLS_KEY == /* ]] || { echo 'TLS paths must be absolute' >&2; exit 2; }
[[ -z $TLS_CERT && -z $TLS_KEY ]] || [[ -n $TLS_CERT && -n $TLS_KEY ]] || { echo 'Provide both --tls-cert and --tls-key' >&2; exit 2; }

for exe in git runuser pg_dump pg_restore tar systemctl nginx df; do
  command -v "$exe" >/dev/null || { echo "Missing executable: $exe" >&2; exit 1; }
done
[[ -x $PYTHON ]] || { echo "Python not executable: $PYTHON" >&2; exit 1; }
[[ -d $ROOT/.git && -x $ROOT/upgrade.sh ]] || { echo "Not a supported Git NetBox install: $ROOT" >&2; exit 1; }
[[ -f $ROOT/netbox/netbox/configuration.py ]] || { echo 'NetBox configuration.py missing' >&2; exit 1; }
[[ -z $TLS_CERT ]] || { [[ -f $TLS_CERT && -f $TLS_KEY ]] || { echo 'TLS files missing' >&2; exit 1; }; }

if ! git -C "$ROOT" diff --quiet || ! git -C "$ROOT" diff --cached --quiet; then
  echo 'Tracked Git files were modified. Resolve changes before upgrading.' >&2; exit 1
fi
CURRENT=$(git -C "$ROOT" describe --tags --exact-match 2>/dev/null) || {
  echo 'Checkout is not at an exact NetBox release tag' >&2; exit 1;
}
[[ $CURRENT =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid current tag: $CURRENT" >&2; exit 1; }
[[ $CURRENT != "$TARGET" ]] || { echo "Already at $TARGET; no changes required."; exit 0; }
if [[ $(printf '%s\n' "$CURRENT" "$TARGET" | sort -V | head -n1) != "$CURRENT" ]]; then
  echo "Downgrade not allowed: $CURRENT -> $TARGET" >&2; exit 1
fi

printf 'Current: %s | target: %s\n' "$CURRENT" "$TARGET"
"$PYTHON" --version
systemctl is-active netbox netbox-rq nginx
runuser -u postgres -- psql -d "$DB" -Atqc 'SELECT current_database();'
runuser -u postgres -- psql -d "$DB" -Atqc "SELECT extname FROM pg_extension WHERE extname='ltree';" | grep -Fx ltree
if [[ -s $ROOT/local_requirements.txt ]]; then
  echo 'NOTE: Local Python requirements present; verify plugins against target.'
fi
if [[ $MODE == 'check' ]]; then
  if git -C "$ROOT" show-ref --verify --quiet "refs/tags/$TARGET"; then
    echo 'Target tag already available locally.'
  else
    echo 'Target tag not cached; --apply will fetch origin tags.'
  fi
  echo 'Preflight complete: NO writes performed. Verify compatibility and off-host backup.'
  exit 0
fi
[[ $CONFIRM == true ]] || { echo 'Apply requires --confirm' >&2; exit 2; }

# Allow secure archive creation regardless of current interactive umask.
umask 077
install -d -m 0700 "$BACKUP_BASE"
BACKUP="$BACKUP_BASE/$(date -u +%Y%m%dT%H%M%SZ)-${CURRENT}-to-${TARGET}"
[[ ! -e $BACKUP ]] || { echo "Backup exists: $BACKUP" >&2; exit 1; }
install -d -m 0700 "$BACKUP"
# Keep stopped services stopped on error; NEVER silently restart after partial DB migrations.
on_failure() {
  local code=$?
  echo "ERROR: upgrade failed (exit $code). Inspect $BACKUP, Git tag, migrations and logs." >&2
  echo 'DO NOT downgrade the Git checkout alone after migrations.' >&2
  exit "$code"
}
trap on_failure ERR
printf '%s\n' "$CURRENT" > "$BACKUP/from-tag.txt"
printf '%s\n' "$TARGET" > "$BACKUP/to-tag.txt"

# Only back up paths that actually exist. Private key backups stay mode 0600
# inside a root-owned mode 0700 directory. Store an encrypted off-host copy.
paths=("${ROOT#/}/netbox/netbox/configuration.py")
for p in "$ROOT/gunicorn.py" "$ROOT/local_requirements.txt" \
  /etc/systemd/system/netbox.service /etc/systemd/system/netbox-rq.service \
  /etc/nginx; do [[ ! -e $p ]] || paths+=("${p#/}"); done
if [[ -n $TLS_CERT ]]; then paths+=("${TLS_CERT#/}" "${TLS_KEY#/}"); fi
printf '%s\n' "${paths[@]}" > "$BACKUP/archive-paths.txt"
tar -C / -czf "$BACKUP/configuration.tar.gz" "${paths[@]}"
if [[ -d $ROOT/netbox/media ]]; then
  tar -C "$ROOT/netbox" -czf "$BACKUP/media.tar.gz" media
fi
runuser -u postgres -- pg_dump -Fc --dbname="$DB" > "$BACKUP/netbox.dump"
test -s "$BACKUP/netbox.dump"
pg_restore --list "$BACKUP/netbox.dump" > "$BACKUP/database-contents.txt"
sha256sum "$BACKUP"/*.gz "$BACKUP/netbox.dump" > "$BACKUP/SHA256SUMS"
chmod 0600 "$BACKUP"/*
echo "Verified backups at $BACKUP. Preserve a separate off-host backup."

# Fetch exact signed/release tag metadata and refuse attempts to target a missing tag.
git -C "$ROOT" fetch origin --tags
git -C "$ROOT" rev-parse --verify "refs/tags/${TARGET}^{commit}" >/dev/null

echo 'Stopping NetBox web and RQ worker services...'
systemctl stop netbox netbox-rq

git -C "$ROOT" checkout --detach "$TARGET"
# Upstream upgrade script collects static files; avoid umask 077 on generated assets.
umask 022
(cd "$ROOT" && PYTHON="$PYTHON" ./upgrade.sh)

runuser -u netbox -- "$ROOT/venv/bin/python" "$ROOT/netbox/manage.py" check
runuser -u netbox -- "$ROOT/venv/bin/python" "$ROOT/netbox/manage.py" migrate --check
nginx -t
systemctl start netbox netbox-rq
systemctl is-active --quiet netbox
systemctl is-active --quiet netbox-rq
systemctl is-active --quiet nginx
[[ $(git -C "$ROOT" describe --tags --exact-match) == "$TARGET" ]]
if [[ -n $URL ]]; then
  command -v curl >/dev/null || { echo 'curl is required for --url' >&2; exit 1; }
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$URL")
  [[ $code =~ ^(200|301|302|303|307|308)$ ]] || { echo "Unexpected HTTPS status: $code" >&2; exit 1; }
  echo "HTTPS response: $code; TLS verified by curl."
fi
trap - ERR
echo "SUCCESS: NetBox $CURRENT -> $TARGET | backup $BACKUP"
echo 'Check UI login, Redis jobs, CA certificate and scheduler; copy backup off host.'