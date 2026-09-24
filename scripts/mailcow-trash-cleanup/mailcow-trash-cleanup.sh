#!/usr/bin/env bash

set -Eeuo pipefail

MAILCOW_DIR="/opt/mailcow-dockerized"
MAILBOX="Trash"
AGE="14d"
MODE="${1:-check}"

cd "$MAILCOW_DIR"

tmp_all="$(mktemp)"
tmp_old="$(mktemp)"

cleanup() {
    rm -f "$tmp_all" "$tmp_old"
}
trap cleanup EXIT

echo "============================================================"
echo " Mailcow Trash cleanup"
echo " Mailbox : $MAILBOX"
echo " Age     : $AGE"
echo " Mode    : $MODE"
echo "============================================================"
echo

echo "=== Checking Dovecot container ==="
docker compose exec -T dovecot-mailcow dovecot --version
echo

echo "=== Searching ALL messages in Trash ==="
if ! docker compose exec -T dovecot-mailcow \
    doveadm search -A mailbox "$MAILBOX" >"$tmp_all"
then
    echo "ERROR: doveadm search failed"
    exit 1
fi

total_trash="$(wc -l < "$tmp_all")"
echo "Total messages in Trash: $total_trash"

echo
echo "=== Searching Trash messages saved before $AGE ==="
if ! docker compose exec -T dovecot-mailcow \
    doveadm search -A mailbox "$MAILBOX" savedbefore "$AGE" >"$tmp_old"
then
    echo "ERROR: doveadm search failed"
    exit 1
fi

total_old="$(wc -l < "$tmp_old")"

echo
echo "Messages to be deleted by user:"
echo

if (( total_old > 0 )); then
    awk '
        NF {
            count[$1]++
        }
        END {
            for (user in count)
                print count[user], user
        }
    ' "$tmp_old" | sort -nr
else
    echo "(none)"
fi

echo
echo "------------------------------------------------------------"
echo "Total messages in Trash : $total_trash"
echo "Older than $AGE          : $total_old"
echo "------------------------------------------------------------"

if [[ "$MODE" == "check" ]]; then
    echo
    echo "CHECK ONLY."
    echo "No messages were deleted."
    echo
    echo "To perform expunge:"
    echo "  $0 expunge"
    exit 0
fi

if [[ "$MODE" != "expunge" ]]; then
    echo
    echo "ERROR: unknown mode: $MODE"
    echo "Usage:"
    echo "  $0 check"
    echo "  $0 expunge"
    exit 2
fi

if (( total_old == 0 )); then
    echo
    echo "Nothing to expunge."
    exit 0
fi

echo
echo "============================================================"
echo " EXPUNGE"
echo "============================================================"
echo
echo "Deleting $total_old messages from $MAILBOX"
echo "with saved date older than $AGE..."
echo

if docker compose exec -T dovecot-mailcow \
    doveadm expunge -A mailbox "$MAILBOX" savedbefore "$AGE"
then
    echo
    echo "Expunge completed successfully."
else
    rc=$?
    echo
    echo "ERROR: doveadm expunge failed."
    echo "Return code: $rc"
    exit "$rc"
fi

echo
echo "=== Verification ==="
if ! docker compose exec -T dovecot-mailcow \
    doveadm search -A mailbox "$MAILBOX" savedbefore "$AGE" >"$tmp_old"
then
    echo "ERROR: verification search failed"
    exit 1
fi

remaining="$(wc -l < "$tmp_old")"
echo "Remaining messages older than $AGE: $remaining"

if (( remaining != 0 )); then
    echo
    echo "WARNING: $remaining matching messages remain."

    awk '
        NF {
            count[$1]++
        }
        END {
            for (user in count)
                print count[user], user
        }
    ' "$tmp_old" | sort -nr

    exit 3
fi

echo
echo "OK: all matching Trash messages were expunged."
