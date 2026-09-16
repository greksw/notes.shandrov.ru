---
title: "1C:Enterprise 8 + Postgres Pro 1C + Apache on AlmaLinux"
description: "A production-backed deployment baseline for 1C:Enterprise 8.3.27, Postgres Pro 1C 17 and Apache 2.4 on AlmaLinux 9, including service layout, web publication, monitoring and rollback boundaries."
category: "Applications & Services"
tags: ["1c", "postgresql", "postgres-pro", "apache", "almalinux", "erp"]
published: 2026-09-16
updated: 2026-09-16
status: current
testedOn: ["AlmaLinux 9.8", "1C:Enterprise 8.3.27", "Postgres Pro 1C 17.10", "Apache 2.4.62"]
featured: true
translationKey: "applications/1c8-postgres-apache-almalinux"
---

## Context

This stack is used in production as a three-layer 1C deployment:

```text
users / web clients
        |
        v
Apache 2.4
        |
        v
1C:Enterprise 8 application server
        |
        v
Postgres Pro 1C 17
```

The verified server baseline is:

```text
OS:              AlmaLinux 9.8
1C:Enterprise:   8.3.27 family
PostgreSQL:      Postgres Pro 1C 17.10
Apache:          2.4.62
```

Several 1C 8.3.27 service builds are installed side by side, while the default enabled service is based on build `8.3.27.2325`. This makes version-aware service and web-publication handling important: do not assume that the newest binary discovered on disk is always the one serving the production infobase.

## Production service layout

The host exposes separate systemd units for the 1C runtime and the database. A sanitized inventory resembles:

```text
postgrespro-1c-17.service
srv1cv8-8.3.27.1719.service
srv1cv8-8.3.27.1859.service
srv1cv8-8.3.27.2325@.service
srv1cv8-8.3.27.2325@default.service
postgres_exporter.service
fm-1c-metrics.service / fm-1c-metrics.timer
```

The production database unit is active, and PostgreSQL metrics are exported through `postgres_exporter`. A separate 1C metrics timer is also present.

This separation is useful operationally: application, database, web and monitoring failures can be diagnosed independently.

## Deployment order

Use a layered sequence:

```text
OS preparation
  -> locale / time / DNS
  -> Postgres Pro 1C
  -> 1C server packages
  -> 1C service validation
  -> infobase validation
  -> Apache
  -> web publication
  -> TLS / firewall
  -> backup / monitoring
```

Do not start with Apache. The backend should work before exposing the web layer.

## Prepare AlmaLinux

Start from a patched minimal installation:

```bash
sudo dnf update -y
sudo hostnamectl status
sudo timedatectl status
```

Confirm the required locale before initializing the database cluster:

```bash
locale -a | grep -Ei 'ru_RU.*utf'
```

For 1C/PostgreSQL deployments, Russian UTF-8 locale handling is not a cosmetic choice; it affects collation and application behavior.

Also verify forward and reverse DNS for the names actually used between the 1C server and the database.

## Install Postgres Pro 1C

The production database is not the stock AlmaLinux AppStream PostgreSQL package. It uses the 1C-specific Postgres Pro 17 build.

Installed package family:

```text
postgrespro-1c-17
postgrespro-1c-17-client
postgrespro-1c-17-contrib
postgrespro-1c-17-libs
postgrespro-1c-17-server
```

Verify the client version:

```bash
psql --version
```

Expected production baseline:

```text
psql (PostgreSQL) 17.10
```

Validate the service:

```bash
systemctl status postgrespro-1c-17 --no-pager
ss -lntp | grep 5432
```

Keep TCP/5432 private. Restrict `pg_hba.conf` to the real 1C application tier or approved administration network.

## Database initialization and tuning

Initialize the database only after locale, storage and authentication decisions are final.

Document at minimum:

```text
cluster data path
locale / collation
listen addresses
pg_hba rules
backup method
WAL/archive policy
```

Do not paste a generic `postgresql.conf` from another server. Tune for the actual workload.

Review at least:

```text
max_connections
shared_buffers
work_mem
maintenance_work_mem
effective_cache_size
checkpoint/WAL settings
temporary workload
storage latency
```

Postgres Pro publishes dedicated configuration guidance for 1C workloads; use that as the baseline and then validate under the real workload.

## Install 1C:Enterprise server packages

1C Linux packages are proprietary and should come from an authorized source.

Do not publish vendor RPMs in Git.

Inspect the package set before installation:

```bash
ls -1 *.rpm
rpm -qpi ./*.rpm | less
```

Then install only the required components:

```bash
sudo dnf install ./*.rpm
```

After installation, discover the platform layout rather than assuming one historical package or path:

```bash
find /opt/1cv8/x86_64 -maxdepth 2 -type f \
  \( -name 'webinst' -o -name 'rac' -o -name 'ras' \) \
  -print
```

## Handle multiple 1C builds explicitly

The production server contains several 8.3.27 service definitions. Therefore every operation that depends on a platform binary should be tied to the intended build.

List units:

```bash
systemctl list-unit-files | grep -Ei '1c|srv1cv8'
```

Then inspect the exact active or intended instance:

```bash
systemctl status 'srv1cv8-8.3.27.2325@default.service' --no-pager
```

The version used for `webinst` should match the 1C server version that serves the target infobase.

Do not publish a web endpoint with an arbitrary `webinst` selected only because it sorts last.

## Validate 1C listeners

Check the configured cluster ports:

```bash
ss -lntp | grep -E ':(1540|1541|156[0-9]|157[0-9]|158[0-9]|159[0-1])\b'
```

The exact allowed range should match the cluster configuration and firewall policy.

Do not open the full range to every network by default.

## Create or attach the infobase

Before Apache enters the picture, confirm that the infobase works through a normal 1C client connection.

Record:

```text
1C cluster/server
infobase logical name
database host
database name
database account
locale/encoding
new database or attached existing database
```

Never place the database password in public documentation, shell history or Git.

## Install Apache 2.4

The production baseline uses Apache 2.4.62 from AlmaLinux.

Install and enable:

```bash
sudo dnf install -y httpd
sudo systemctl enable --now httpd
```

Validate:

```bash
httpd -v
apachectl configtest
systemctl status httpd --no-pager
ss -lntp | grep -E ':(80|443)\b'
```

## Publish the infobase with `webinst`

1C provides `webinst` for web publication. For Apache 2.4 use `-apache24`.

First identify the intended platform build explicitly.

Example:

```bash
WEBINST='/opt/1cv8/x86_64/8.3.27.2325/webinst'
```

Verify it exists before use:

```bash
test -x "$WEBINST"
```

Create a dedicated publication directory:

```bash
sudo install -d -o root -g apache -m 0750 /var/www/1c/demo
```

Publish with sanitized placeholders:

```bash
sudo "$WEBINST" \
  -publish \
  -apache24 \
  -wsdir demo \
  -dir /var/www/1c/demo \
  -connstr 'Srvr=1c-app.example.net:1541;Ref=demo;' \
  -confpath /etc/httpd/conf/httpd.conf
```

Then validate and reload Apache:

```bash
sudo apachectl configtest
sudo systemctl reload httpd
```

The Apache account must be able to read/execute the web extension files for the selected 1C build.

## Validate generated Apache configuration

Inspect what was added:

```bash
grep -RniE '1cv8|wsap|demo' /etc/httpd /var/www/1c 2>/dev/null
```

Check that the referenced 1C web-server extension exists and that its architecture matches Apache.

## SELinux

Do not permanently disable SELinux to make 1C web publication work.

Check mode:

```bash
getenforce
```

If Apache starts but the 1C publication fails, inspect AVC denials:

```bash
sudo ausearch -m AVC,USER_AVC -ts recent
```

Fix contexts, permissions or create a narrowly scoped local policy based on the actual denial.

`setenforce 0` is acceptable only as a temporary diagnostic comparison.

## Firewall model

Use least privilege between layers:

```text
web clients              -> Apache: 443
1C client/admin networks -> required 1C cluster ports
1C application tier      -> Postgres Pro: 5432
Internet                 -> PostgreSQL: never
```

If the web client is exposed externally, use HTTPS and the normal certificate lifecycle for the site.

## Monitoring

The production host already includes PostgreSQL metrics collection:

```text
postgres_exporter.service
```

It also has a dedicated 1C metrics timer/service pair.

For a mature deployment, monitor at least:

```text
PostgreSQL availability
connections
transactions / locks
WAL / checkpoint pressure
database size
1C server process availability
1C cluster ports
Apache availability
HTTP response from the publication endpoint
host CPU / RAM / storage latency
```

Monitoring should detect backend degradation, not just whether Apache still returns an HTTP response.

## Validation sequence

Validate every layer separately.

Postgres Pro:

```bash
systemctl is-active postgrespro-1c-17
psql --version
ss -lntp | grep 5432
```

1C server:

```bash
systemctl status 'srv1cv8-8.3.27.2325@default.service' --no-pager
ss -lntp | grep -E ':(1540|1541)\b'
```

Apache:

```bash
apachectl configtest
systemctl is-active httpd
curl -I http://127.0.0.1/
```

Finally, test the actual publication URI and perform a real 1C application login. HTTP 200/302 alone is not sufficient validation.

## Backup and rollback

Treat all three layers independently.

Database recovery may use:

```text
logical dump for small/simple cases
physical/base backup for larger production databases
WAL/archive when point-in-time recovery is required
```

Also preserve:

```text
1C platform build/package information
1C service overrides
cluster administration settings
infobase registration details
Apache configuration
web publication directories
custom monitoring scripts
```

Do not combine a 1C platform upgrade, Postgres Pro major upgrade and Apache redesign into one rollback unit.

## Common mistakes

Avoid:

- using stock PostgreSQL without checking 1C compatibility;
- initializing the database under the wrong locale;
- exposing 5432 broadly;
- using `webinst` from the wrong installed 1C build;
- disabling SELinux instead of fixing policy;
- opening the entire 1C port range to every network;
- treating a working Apache page as proof that the infobase is healthy;
- changing 1C, Postgres Pro and Apache simultaneously without independent rollback points.

## References

- 1C:Enterprise web publication on Linux / Apache 2.4: <https://kb.1ci.com/1C_Enterprise_Platform/Guides/Administrator_Guides/1C_Enterprise_8.3.27_Administrator_Guide/Chapter_8.Setting_up_web_services_for_1C_Enterprise/8.4._Setting_up_client_application_support/8.4.2._On_Linux/>
- 1C `webinst` utility: <https://kb.1ci.com/1C_Enterprise_Platform/Guides/Administrator_Guides/1C_Enterprise_8.3.27_Administrator_Guide/Chapter_8.Setting_up_web_services_for_1C_Enterprise/8.3._Publication_types/8.3.3._Webinst_utility/>
- Postgres Pro configuration for 1C: <https://postgrespro.ru/docs/enterprise/17/config-one-c>
- Postgres Pro Linux installation/support matrix: <https://postgrespro.ru/docs/enterprise/17/binary-installation-on-linux>
