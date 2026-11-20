# Mailcow Flatcurve utilities

Bash utilities for a Mailcow Dockerized deployment with Dovecot 2.3 and the Flatcurve plugin. Run them on the Mailcow host with Bash 4.4+, Docker Compose v2, and permissions to run `docker compose exec`. The default checkout directory for Mailcow is `/opt/mailcow-dockerized`. To select another deployment, set `MAILCOW_DIR`.

- `status.sh` reports effective FTS configuration, the IMAP plugin list, memory, and free space.
- `index.sh` can show the index targets or populate missing entries. It uses one foreground `doveadm index` call at a time.
- `benchmark.sh` counts matches and times a Dovecot `BODY` query, including the Compose command overhead. It prompts for the search word and prints the count rather than subject lines or message contents. Dovecot may fill missing FTS entries during a search.

## Check configuration and run one folder

```bash
bash status.sh
bash index.sh --account user@example.com --folder INBOX
bash index.sh --account user@example.com --folder INBOX --apply
bash benchmark.sh user@example.com INBOX
```

For the benchmark, enter a word from the body of a known message. Check end-to-end latency in the user's mail client separately.

## Index existing accounts

```bash
bash index.sh --all --shared
bash index.sh --all --shared --min-free-gib 50 --apply
```

Use a reserve that matches the server's storage and mail growth. The example uses 50 GiB. The script checks free space on the mail and index filesystems between jobs. A single large job can use space below the threshold before the next check.

`--all` enumerates the Dovecot user database and excludes internal `@mailcow.local` identities. Use repeated `--account` to select a subset. By default, each account is passed to Dovecot with mailbox mask `*`. The `--shared` option also enumerates explicit `Shared/<owner>/*` paths and indexes each readable shared folder under the receiving account. This is intended for Mailcow's default `Shared/` namespace layout. A repeated visit to an indexed folder only fills missing entries. An error stops the apply pass.

```bash
bash benchmark.sh delegate@example.com 'Shared/owner@example.com/INBOX'
```

The apply pass expects Flatcurve to be enabled in the Mailcow Dovecot 2.3 IMAP plugin list. Mailbox enumeration uses Dovecot's listed users and namespaces. Run the plan to inspect those targets before broad indexing. The scripts write index files through Dovecot. Configuration changes, index resets, and retention are administered separately.

For details and measured results, see the [technical note](https://notes.shandrov.ru/ru/notes/mail/mailcow-flatcurve-full-text-search/).
