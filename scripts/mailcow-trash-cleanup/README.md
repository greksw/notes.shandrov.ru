# Mailcow Trash Cleanup

Safe bulk cleanup of old messages from the `Trash` mailbox for all Mailcow users using Dovecot `doveadm`.

The script is intentionally conservative:

- default mode is **check only**;
- it counts matching messages before deletion;
- it prints a per-user breakdown;
- deletion requires an explicit `expunge` argument;
- it verifies that no matching messages remain after the operation;
- Bash strict mode and `pipefail` are enabled.

## What it removes

The default policy is:

```text
all Mailcow users
        ↓
mailbox Trash
        ↓
savedbefore 14d
        ↓
expunge
```

The Dovecot query is:

```bash
doveadm expunge -A mailbox 'Trash' savedbefore 14d
```

Dovecot documents `savedbefore` as matching messages based on the time they were saved/copied into the mailbox. This is different from `before`, which works with the message's internal date.

Mailcow also documents the same `doveadm expunge -A ... savedbefore ...` pattern for scheduled mailbox cleanup.

## Requirements

- Mailcow Dockerized
- Docker Compose plugin
- Dovecot container named `dovecot-mailcow`
- Bash
- root or equivalent permission to execute Docker commands

The defaults assume Mailcow is installed in:

```text
/opt/mailcow-dockerized
```

## Install

Copy the script to the Mailcow host:

```bash
install -m 700 mailcow-trash-cleanup.sh /root/mailcow-trash-cleanup.sh
```

If Mailcow is installed somewhere else, edit:

```bash
MAILCOW_DIR="/opt/mailcow-dockerized"
```

## Check mode

Always start with:

```bash
/root/mailcow-trash-cleanup.sh check
```

Running it without arguments is equivalent:

```bash
/root/mailcow-trash-cleanup.sh
```

The script prints:

- total messages currently in `Trash`;
- messages matching `savedbefore 14d`;
- matching count per mailbox owner.

No messages are deleted in this mode.

Example:

```text
Total messages in Trash : 8120
Older than 14d          : 5300

Messages to be deleted by user:

1200 user1@example.org
840 user2@example.org
...
```

## Expunge mode

After reviewing the check output:

```bash
/root/mailcow-trash-cleanup.sh expunge
```

A successful run ends with:

```text
Expunge completed successfully.

=== Verification ===
Remaining messages older than 14d: 0

OK: all matching Trash messages were expunged.
```

## Changing retention

Edit:

```bash
AGE="14d"
```

For example:

```bash
AGE="30d"
```

After any policy change, run `check` before `expunge`.

## Changing the mailbox

The default is deliberately limited to:

```bash
MAILBOX="Trash"
```

Do not replace this with a broad wildcard such as `%` unless you explicitly intend to operate on every mailbox.

## Manual diagnostics

Check the Dovecot container:

```bash
cd /opt/mailcow-dockerized
docker compose ps dovecot-mailcow
```

Check Dovecot version:

```bash
docker compose exec -T dovecot-mailcow dovecot --version
```

Preview matching messages:

```bash
docker compose exec -T dovecot-mailcow \
  doveadm search -A mailbox 'Trash' savedbefore 14d |
head -30
```

Count matches:

```bash
docker compose exec -T dovecot-mailcow \
  doveadm search -A mailbox 'Trash' savedbefore 14d |
wc -l
```

Check one user:

```bash
docker compose exec -T dovecot-mailcow \
  doveadm search -u 'user@example.org' \
  mailbox 'Trash' savedbefore 14d
```

## Exit codes

- `0` — successful check/expunge or nothing to delete
- `1` — search or verification failure
- `2` — unsupported mode
- `3` — matching messages still remain after expunge
- other non-zero code — propagated from `doveadm expunge`

## Cron

Only automate the job after several successful manual runs and after confirming the retention policy.

Example:

```cron
0 4 * * * /root/mailcow-trash-cleanup.sh expunge
```

For unattended use, adding `flock`, persistent logging and alerting on non-zero exit codes is recommended.

## References

- Mailcow: Expunge a user's mails  
  https://docs.mailcow.email/manual-guides/Dovecot/u_e-dovecot-expunge/
- Mailcow: More examples with DOVEADM  
  https://docs.mailcow.email/manual-guides/Dovecot/u_e-dovecot-more/
- Dovecot: doveadm-expunge  
  https://doc.dovecot.org/main/core/man/doveadm-expunge.1.html

## Safety note

`doveadm expunge` permanently removes matching messages from Dovecot storage. Use `check` first and ensure your backup/retention policy is appropriate before enabling automatic execution.
