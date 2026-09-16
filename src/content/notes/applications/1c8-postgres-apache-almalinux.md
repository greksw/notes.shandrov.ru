---
title: "1C:Enterprise 8 + PostgreSQL + Apache on AlmaLinux"
description: "A deployment baseline for a 1C:Enterprise 8 application server, PostgreSQL-compatible database and Apache 2.4 web publication on AlmaLinux, with explicit support-matrix and rollback boundaries."
category: "Applications & Services"
tags: ["1c", "postgresql", "postgres-pro", "apache", "almalinux", "erp"]
published: 2026-09-16
updated: 2026-09-16
status: lab
testedOn: []
featured: true
translationKey: "applications/1c8-postgres-apache-almalinux"
---

## Context

A typical Linux-based 1C:Enterprise deployment has three distinct layers:

```text
users / web clients
        |
        v
Apache 2.4
        |
        v
1C:Enterprise 8 application server cluster
        |
        v
PostgreSQL-compatible database server
```

These layers should be treated separately during deployment and troubleshooting. A working Apache page does not prove that the 1C cluster can reach the database, and a running PostgreSQL process does not prove that the infobase is healthy.

This runbook is deliberately marked **lab** until the exact 1C platform build, database distribution/version and AlmaLinux release used in the target environment are confirmed end-to-end.

## Verify the support matrix first

Do not begin with package installation. First confirm that the exact combination is supported by the vendors:

```text
1C:Enterprise platform version
Linux distribution and major version
PostgreSQL/Postgres Pro version
Apache version and architecture
```

The 1C administrator documentation publishes supported Linux distributions by platform release. AlmaLinux is RHEL-compatible, but a compatible distribution is not automatically the same thing as a formally supported one for every 1C release. Treat vendor support status as a release-specific decision.

For the database layer, use a PostgreSQL build explicitly supported for the selected 1C platform. Do not assume the stock AlmaLinux AppStream PostgreSQL package is automatically suitable.

Postgres Pro documents dedicated 1C configuration guidance and current Postgres Pro releases support AlmaLinux 9/10. If Postgres Pro is selected, use the exact edition/version approved for the application and licensing model.

## Suggested deployment order

A safe order is:

```text
OS preparation
  -> locale/time/DNS
  -> database server
  -> 1C server packages
  -> 1C cluster validation
  -> test infobase
  -> Apache
  -> web publication
  -> TLS/firewall
  -> backup and monitoring
```

Do not expose the web endpoint before the backend layers are validated.

## Prepare AlmaLinux

Start from a minimal, patched host.

```bash
sudo dnf update -y
sudo hostnamectl status
sudo timedatectl status
```

1C/PostgreSQL deployments commonly require a Russian UTF-8 locale. Confirm what is available:

```bash
locale -a | grep -Ei 'ru_RU.*utf'
```

If it is missing, install/generate the locale using the method appropriate for the AlmaLinux release before initializing the database cluster.

Also verify DNS resolution in both directions for the names that the 1C server and database will actually use.

## Database layer

### Use a 1C-supported PostgreSQL distribution

The database package source should be part of the design decision, not an afterthought.

Possible choices include a Postgres Pro edition or another PostgreSQL build explicitly supported for the selected 1C release.

Keep these values documented:

```text
database product
major/minor version
package repository/source
cluster data path
locale used at initdb
authentication method
backup method
```

### Initialize with the intended locale

The locale used when the database cluster is created matters. Postgres Pro's 1C guidance explicitly calls out use of a Russian UTF-8 locale.

Check before initialization:

```bash
locale
```

Do not initialize the cluster under an accidental `C`/`POSIX` locale and try to fix it later in production.

### Keep PostgreSQL private

The database should normally listen only on addresses needed by the 1C application tier.

Validate listening sockets:

```bash
ss -lntp | grep 5432
```

Then restrict host authentication in `pg_hba.conf` to the actual 1C server network or address range.

Do not expose TCP/5432 to the Internet.

### Tune for 1C deliberately

Do not paste a generic `postgresql.conf` from another server.

1C workloads can require many connections and have specific temporary-table and planner behavior. Postgres Pro publishes a dedicated 1C tuning section and provides tooling such as `pgpro_tune` in current releases.

At minimum review:

```text
max_connections
shared_buffers
work_mem
maintenance_work_mem
effective_cache_size
checkpoint/WAL settings
locale/collation
storage latency
```

The correct values depend on RAM, CPU, database size and user concurrency.

## Install 1C:Enterprise 8 server packages

1C Linux packages are proprietary software. Obtain the exact server distribution from the authorized 1C source and transfer it to the host through an approved channel.

Do not publish vendor RPM files in a public repository.

Before installation, inspect the package set:

```bash
ls -1 *.rpm
rpm -qpi ./*.rpm | less
```

Install only the components required by the design:

```bash
sudo dnf install ./*.rpm
```

Package names vary between 1C platform releases, so avoid hard-coding one historical RPM filename into automation unless that exact build is pinned intentionally.

After installation, inventory the resulting packages:

```bash
rpm -qa | grep -Ei '1c|1cv8' | sort
```

## Locate the installed 1C version

On Linux, 1C platform binaries are commonly installed under a versioned path below `/opt/1cv8/x86_64/`.

Inspect rather than guessing:

```bash
find /opt/1cv8/x86_64 -maxdepth 2 -type f \
  \( -name 'webinst' -o -name 'rac' -o -name 'ras' \) \
  -print
```

The exact same platform version that serves the infobase should be used when publishing it through `webinst`.

## Validate the 1C server service

Service-unit names can differ between platform releases/package layouts. Discover them first:

```bash
systemctl list-unit-files | grep -Ei '1c|srv1cv8'
```

Then inspect the actual unit:

```bash
systemctl status '<detected-unit>' --no-pager
```

Do not enable a guessed unit name in automation.

Also inspect listening sockets:

```bash
ss -lntp | grep -E ':(1540|1541|156[0-9]|157[0-9]|158[0-9]|159[0-1])\b'
```

The exact cluster port design should match the environment and firewall policy.

## Create or attach the infobase

The database itself should be created through the supported 1C administration workflow for the selected platform version.

Record at least:

```text
1C cluster/server name
infobase logical name
database host
database name
database account
locale/encoding
whether the database was newly created or attached
```

Do not store the database password in public shell history, documentation or Git.

Before adding Apache, confirm that the infobase works through a normal 1C client connection.

## Install Apache 2.4

On AlmaLinux:

```bash
sudo dnf install -y httpd
sudo systemctl enable --now httpd
```

Validate the base service:

```bash
apachectl configtest
systemctl status httpd --no-pager
ss -lntp | grep -E ':(80|443)\b'
```

Keep the initial test local or on the internal network until the 1C publication is ready.

## Publish the infobase with `webinst`

1C provides the `webinst` utility for configuring a web publication. For Apache 2.4 the documented mode is `-apache24`.

First identify the exact binary for the installed platform version:

```bash
WEBINST=$(find /opt/1cv8/x86_64 -type f -name webinst | sort -V | tail -1)
printf '%s\n' "$WEBINST"
```

For production, do not blindly take the newest binary if multiple platform versions are installed. Select the version that exactly matches the infobase server version.

Create a dedicated publication directory:

```bash
sudo install -d -o root -g apache -m 0750 /var/www/1c/demo
```

Example publication:

```bash
sudo "$WEBINST" \
  -publish \
  -apache24 \
  -wsdir demo \
  -dir /var/www/1c/demo \
  -connstr 'Srvr=1c-app.example.net:1541;Ref=demo;' \
  -confpath /etc/httpd/conf/httpd.conf
```

Use sanitized placeholders in documentation; the real server name and infobase name are environment-specific.

After publication:

```bash
sudo apachectl configtest
sudo systemctl reload httpd
```

1C documentation also notes that the Apache user must have read/execute access to the executable directory of the corresponding 1C platform version.

## Validate the generated Apache configuration

Search what changed:

```bash
grep -RniE '1cv8|wsap|demo' /etc/httpd /var/www/1c 2>/dev/null
```

Confirm the 1C Apache extension path exists and matches Apache bitness.

The 1C documentation explicitly requires matching web-server-extension and web-server architecture.

## SELinux

Do not solve a publication problem by permanently disabling SELinux.

Check current mode:

```bash
getenforce
```

If Apache starts but the 1C web publication fails, inspect denials:

```bash
sudo ausearch -m AVC,USER_AVC -ts recent
```

Then fix file contexts, permissions or create a narrowly scoped local policy based on the actual denial.

A temporary `setenforce 0` can be useful only as a diagnostic comparison, not as the final configuration.

## Firewall

Expose only the services that are actually needed.

Typical separation:

```text
client -> Apache: 443
1C client/admin network -> 1C cluster ports
1C application tier -> PostgreSQL: 5432
Internet -> PostgreSQL: never
```

If the web client is required externally, publish HTTPS rather than plain HTTP and terminate TLS using the site's standard certificate-management process.

## Validation sequence

Validate each layer independently.

### PostgreSQL

```bash
systemctl --no-pager --type=service | grep -Ei 'postgres|pgpro'
ss -lntp | grep 5432
```

Then test authentication from the 1C server using an approved database client/account.

### 1C server

```bash
systemctl list-units --type=service | grep -Ei '1c|srv1cv8'
ss -lntp | grep -E ':(1540|1541)\b'
```

Confirm the infobase opens from a normal 1C client before testing Apache.

### Apache

```bash
apachectl configtest
systemctl is-active httpd
curl -I http://127.0.0.1/
```

### Web publication

Test the actual publication URI and perform a real application login. A successful HTTP 200/302 response alone is not enough.

## Backup and rollback

Before production cutover define independent recovery paths for all three layers.

### Database

Use a supported PostgreSQL/Postgres Pro backup method appropriate for the database size and RPO:

```text
logical dump for small/simple cases
physical/base backup for larger production databases
WAL/archive strategy when point-in-time recovery is required
```

### 1C configuration

Keep copies of:

```text
1C platform package/build information
/etc or service overrides related to 1C
cluster administration settings
infobase registration details
custom scripts
```

### Apache

Back up the Apache configuration and publication directories before rerunning `webinst` or changing versions.

Rollback should be possible without reinstalling the entire stack under time pressure.

## Common mistakes

Avoid these patterns:

- installing stock PostgreSQL without checking 1C support;
- initializing PostgreSQL with the wrong locale;
- exposing TCP/5432 broadly;
- using `webinst` from a different 1C platform version;
- copying Apache publication files between mismatched versions;
- disabling SELinux instead of fixing access policy;
- opening every 1C port to every network;
- treating a successful Apache page as proof that the infobase is healthy;
- upgrading the 1C platform, PostgreSQL and Apache simultaneously without a rollback boundary.

## What to capture from a real deployment

To promote this note from `lab` to `current`, collect the actual non-secret versions and service layout:

```bash
cat /etc/os-release | grep -E '^(PRETTY_NAME|VERSION_ID)='
httpd -v
rpm -qa | grep -Ei '1c|1cv8' | sort
systemctl list-unit-files | grep -Ei '1c|srv1cv8'
systemctl --no-pager --type=service | grep -Ei 'postgres|pgpro'
```

For the database, capture the exact product/version separately without publishing credentials.

Once those values are confirmed on the working server, the metadata and commands can be tightened to the real production implementation.

## References

- 1C:Enterprise web publication on Linux / Apache 2.4: <https://kb.1ci.com/1C_Enterprise_Platform/Guides/Administrator_Guides/1C_Enterprise_8.3.27_Administrator_Guide/Chapter_8.Setting_up_web_services_for_1C_Enterprise/8.4._Setting_up_client_application_support/8.4.2._On_Linux/>
- 1C `webinst` utility: <https://kb.1ci.com/1C_Enterprise_Platform/Guides/Administrator_Guides/1C_Enterprise_8.3.27_Administrator_Guide/Chapter_8.Setting_up_web_services_for_1C_Enterprise/8.3._Publication_types/8.3.3._Webinst_utility/>
- 1C general web publication procedure: <https://kb.1ci.com/1C_Enterprise_Platform/Guides/Administrator_Guides/1C_Enterprise_8.3.22_Administrator_Guide/Chapter_8._Setting_up_web_services_for_1C_Enterprise/8.3._Publication_types/8.3.1._General_publication_procedure/>
- Postgres Pro configuration for 1C: <https://postgrespro.ru/docs/enterprise/16/config-one-c>
- Postgres Pro Linux installation/support matrix: <https://postgrespro.ru/docs/enterprise/17/binary-installation-on-linux>
