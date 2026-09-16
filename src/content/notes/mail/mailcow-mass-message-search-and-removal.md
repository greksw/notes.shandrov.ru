---
title: "Mailcow: safely finding and removing a malicious message from all mailboxes"
description: "An incident-response runbook for identifying a suspicious message across Mailcow/Dovecot mailboxes, validating the exact match, expunging it safely and verifying the result."
category: "Mail & Services"
tags: ["mailcow", "dovecot", "incident-response", "email", "security", "expunge"]
published: 2026-09-16
updated: 2026-09-16
status: current
testedOn: ["Mailcow dockerized", "Dovecot", "docker compose"]
featured: true
translationKey: "mail/mailcow-mass-message-search-and-removal"
---

## Context

A phishing, spam or otherwise dangerous message can reach many local mailboxes before it is reported. Once the message is confirmed as malicious, the operational task is to answer four questions quickly:

1. which users received it;
2. which folders still contain it;
3. whether the match is specific enough to avoid deleting legitimate mail;
4. whether the message is really gone after remediation.

Mailcow exposes Dovecot's `doveadm` tooling inside the `dovecot-mailcow` container, which makes fleet-wide search and expunge possible without iterating through users manually.

The destructive step must come last. Build and validate the search query first, then reuse the same query for `expunge`.

## Work from the Mailcow directory

```bash
cd /opt/mailcow-dockerized/
```

The examples use `docker compose`. Add `-T` when the command is run non-interactively from a script or cron job.

## Do not delete by sender alone unless that is truly sufficient

A visible `From:` address is easy to spoof and one sender may also have legitimate messages in user mailboxes.

Prefer the strongest available identifier:

1. unique `Message-ID`;
2. `Message-ID` plus sender/subject/date if additional confirmation is useful;
3. sender + subject + narrow time window;
4. sender alone only when the incident scope is already verified.

Dovecot's `FROM` search key matches the From field in the message's IMAP envelope. Multiple search expressions are combined with logical AND by default.

## First pass: find which users have messages from a sender

A quick inventory search:

```bash
docker compose exec -T dovecot-mailcow \
  doveadm search -A FROM "sender@example.com"
```

With `-A`, `doveadm search` outputs the username, mailbox GUID and UID for each match. That is useful for counting affected users, but it is not very readable for incident review.

Count matches per user:

```bash
docker compose exec -T dovecot-mailcow \
  doveadm search -A FROM "sender@example.com" |
awk '{count[$1]++} END {
  for (user in count)
    print count[user], user
}' |
sort -nr
```

Get the total number of matches:

```bash
docker compose exec -T dovecot-mailcow \
  doveadm search -A FROM "sender@example.com" |
wc -l
```

Do not expunge yet. A sender-only result set is still too broad for many incidents.

## Fetch readable metadata before deletion

Use `doveadm fetch` to see who owns each message, where it is stored and which headers identify it:

```bash
docker compose exec -T dovecot-mailcow \
  doveadm fetch -A \
  "user mailbox uid date.received hdr.from hdr.to hdr.subject hdr.message-id" \
  FROM "sender@example.com"
```

Useful fields include:

- `user` — mailbox owner;
- `mailbox` — folder containing the message;
- `uid` — IMAP UID inside that mailbox;
- `date.received` — IMAP INTERNALDATE;
- `hdr.from`;
- `hdr.to`;
- `hdr.subject`;
- `hdr.message-id`.

If the message is known to be in `INBOX`, restrict the query:

```bash
docker compose exec -T dovecot-mailcow \
  doveadm fetch -A \
  "user mailbox uid date.received hdr.from hdr.subject hdr.message-id" \
  mailbox INBOX FROM "sender@example.com"
```

Folder restriction is useful for investigation, but it should not be assumed for remediation: users or filters may already have moved copies elsewhere.

## Prefer Message-ID for a specific malicious message

After inspecting one confirmed malicious copy, capture its `Message-ID`.

Example:

```text
<20260916.123456.abcdef@example.net>
```

Search all users for that identifier:

```bash
docker compose exec -T dovecot-mailcow \
  doveadm fetch -A \
  "user mailbox uid date.received hdr.from hdr.subject hdr.message-id" \
  HEADER Message-ID "<20260916.123456.abcdef@example.net>"
```

Dovecot's `HEADER field string` query matches messages whose named header contains the supplied string. Including the complete Message-ID, including angle brackets, makes the match much narrower than a sender-only query.

Count the exact candidates before deletion:

```bash
docker compose exec -T dovecot-mailcow \
  doveadm search -A \
  HEADER Message-ID "<20260916.123456.abcdef@example.net>" |
wc -l
```

## When Message-ID is not enough

Some campaigns reuse malformed identifiers or generate different Message-IDs for each recipient. In that case combine several criteria.

Example:

```bash
docker compose exec -T dovecot-mailcow \
  doveadm fetch -A \
  "user mailbox uid date.received hdr.from hdr.subject hdr.message-id" \
  FROM "sender@example.com" \
  SUBJECT "Urgent payment request" \
  SINCE 2026-09-15 BEFORE 2026-09-17
```

`SINCE` and `BEFORE` use the message's internal received date. If the incident requires the sender-supplied `Date:` header instead, use `SENTSINCE` / `SENTBEFORE` and document that distinction.

The final deletion query should be the same query that was reviewed during the dry run.

## Expunge the confirmed malicious message

Dovecot requires an explicit mailbox expression for `expunge`. To cover all user mailboxes, use a mailbox wildcard together with the validated message selector.

For a unique Message-ID:

```bash
docker compose exec -T dovecot-mailcow \
  doveadm expunge -A \
  mailbox '*' \
  HEADER Message-ID "<20260916.123456.abcdef@example.net>"
```

For a sender-only emergency removal, when the scope has been independently confirmed:

```bash
docker compose exec -T dovecot-mailcow \
  doveadm expunge -A \
  mailbox '*' \
  FROM "sender@example.com"
```

The second command is much broader. Use it only when every message matching that sender is intended to be removed.

## Verification after expunge

Immediately rerun the exact search query used for deletion.

For Message-ID:

```bash
docker compose exec -T dovecot-mailcow \
  doveadm search -A \
  HEADER Message-ID "<20260916.123456.abcdef@example.net>" |
wc -l
```

Expected result:

```text
0
```

If matches remain, inspect them with `doveadm fetch` before issuing another destructive command. The reason may be a different mailbox namespace, a query mismatch or a duplicate message with different identifying headers.

## Record the incident evidence

Before and after deletion, retain enough information to reconstruct what happened:

- incident ticket or timestamp;
- malicious sender address;
- exact subject;
- Message-ID when available;
- number of affected mailboxes/messages;
- search query used for validation;
- expunge query used for remediation;
- post-expunge match count;
- whether users were warned or credentials were reset separately.

Do not store entire message bodies or attachments in an incident record unless they are actually needed for analysis and the storage location is appropriate for potentially malicious content.

## Separate message removal from account compromise response

Deleting the message does not reverse actions already taken by users.

If the message contained a credential-phishing link, malicious attachment or OAuth lure, the response may also require:

- identifying users who opened the message;
- resetting credentials;
- revoking sessions or application tokens;
- endpoint investigation;
- blocking sender/domain/URL indicators;
- reviewing mail logs for additional variants of the campaign.

Mailbox cleanup is containment, not the complete incident response.

## Related maintenance: purge old Trash messages

The same `doveadm` tooling is useful for controlled Trash retention.

First confirm the actual Trash mailbox name in the environment if there is any doubt:

```bash
docker compose exec -T dovecot-mailcow \
  doveadm mailbox list -A | sort -u | grep -Ei '(^|/)(Trash|Deleted)($|/)'
```

For the standard `Trash` mailbox, count messages saved there more than 14 days ago:

```bash
echo "=== Trash messages saved more than 14 days ago ==="

docker compose exec -T dovecot-mailcow \
  doveadm search -A mailbox Trash savedbefore 14d |
awk '{count[$1]++} END {
  for (user in count)
    print count[user], user
}' |
sort -nr

echo "=== Total ==="

docker compose exec -T dovecot-mailcow \
  doveadm search -A mailbox Trash savedbefore 14d |
wc -l
```

This is a dry run only.

`SAVEDBEFORE` is based on Dovecot's save/copy date for the message in that mailbox, not the original `Date:` header. For Trash cleanup, that distinction is usually what is wanted: the retention period follows when the message was saved/copied into the mailbox rather than when the message was originally authored.

After reviewing the count:

```bash
echo "=== Expunge Trash older than 14 days ==="

docker compose exec -T dovecot-mailcow \
  doveadm expunge -A mailbox Trash savedbefore 14d

echo "expunge_rc=$?"

echo "=== Remaining matches ==="

docker compose exec -T dovecot-mailcow \
  doveadm search -A mailbox Trash savedbefore 14d |
wc -l
```

Mailcow documents the same `doveadm expunge -A mailbox 'Junk' savedbefore ...` pattern for retention cleanup.

## Stop conditions

Stop before `expunge` if:

- the match criteria include legitimate messages;
- the sender is not a sufficiently unique indicator;
- the exact message has not been inspected with `fetch`;
- the result count is unexpectedly large;
- the incident owner cannot confirm the removal scope;
- the mailbox naming or namespace is unclear;
- a restore/recovery path is required by local policy but is unavailable.

The safest operational pattern is simple:

```text
identify -> fetch -> count -> review -> expunge -> search again -> document
```

## References

- Dovecot `doveadm search`: <https://doc.dovecot.org/main/core/man/doveadm-search.1.html>
- Dovecot search query syntax: <https://doc.dovecot.org/2.4.2/core/man/doveadm-search-query.7.html>
- Dovecot `doveadm fetch`: <https://doc.dovecot.org/2.4.1/core/man/doveadm-fetch.1.html>
- Dovecot `doveadm expunge`: <https://doc.dovecot.org/main/core/man/doveadm-expunge.1.html>
- Mailcow expunge guide: <https://docs.mailcow.email/manual-guides/Dovecot/u_e-dovecot-expunge/>
