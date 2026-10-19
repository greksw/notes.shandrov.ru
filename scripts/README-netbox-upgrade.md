# NetBox Git deployment: maintenance script

`netbox-upgrade.sh` is an optional Bash wrapper around the official [NetBox `upgrade.sh`](https://netboxlabs.com/docs/netbox/installation/upgrading/) for **Git installations**, tested with `bash -n` only. **It has not been executed on a production system**: the documented NetBox 4.7.1 → 4.7.3 upgrade was performed manually.

## Prerequisites

- Root (sudo), Git checkout `/opt/netbox`, NetBox services `netbox` and `netbox-rq`, Nginx.
- PostgreSQL database `netbox`, local Linux account `postgres` able to use `pg_dump`, `pg_restore`.
- Python 3.12 or later at `/usr/bin/python3.12` (override `--python` as appropriate).
- `ltree` installed in DB (NetBox 4.7+); a maintenance window and **off-host backups**.
- Review NetBox release notes, plugin and `local_requirements.txt` compatibility, PostgreSQL and Redis version requirements.
- Backups with DB credentials and TLS keys must remain private, encrypted off-host, and periodically restore-tested.

## Usage

```bash
sudo ./netbox-upgrade.sh --check --target v4.7.3
sudo ./netbox-upgrade.sh --apply --target v4.7.3 --confirm \
  --tls-cert /etc/pki/tls/certs/netbox.example.org.crt \
  --tls-key /etc/pki/tls/private/netbox.example.org.key \
  --url https://netbox.example.org/
```

If `--tls-cert`/`--tls-key` are omitted, **the TLS key is not backed up by this script**. Back up private keys separately. If `--url` is omitted, HTTPS validation is manual. The script does not validate restore capability and never does an automatic database rollback. A failed upgrade can leave NetBox services stopped; inspect the backups and logs, and recover only using a documented, tested restore plan.

`--check` does not fetch tags or stop/start services; `--apply` fetches Git tags, creates a backup, stops both NetBox services, checks out the target release, runs upstream upgrade tasks, then checks Django, pending migrations, Nginx, systemd and optionally HTTPS. Backup contents include sensitive configuration. After completion transfer the backups securely to a different host.

## Security and scope

This repository does not contain server-side `configuration.py`, private keys, passwords, real host names or site-local settings. The tool is intended as a reference for a **single-instance, local PostgreSQL** deployment, not Docker, HA clusters, or remotely hosted read-only replicas.