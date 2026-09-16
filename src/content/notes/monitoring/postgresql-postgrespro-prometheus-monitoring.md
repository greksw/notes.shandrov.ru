---
title: "PostgreSQL / Postgres Pro monitoring with Prometheus and postgres_exporter"
description: "A production-backed monitoring pattern for PostgreSQL and Postgres Pro using postgres_exporter, Prometheus and Grafana, with database-native metrics separated from generic Linux monitoring."
category: "Monitoring & Security"
tags: ["postgresql", "postgres-pro", "prometheus", "postgres-exporter", "grafana", "monitoring"]
published: 2026-09-16
updated: 2026-09-16
status: current
testedOn: ["AlmaLinux 9.8", "Postgres Pro 1C 17.10", "postgres_exporter systemd deployment", "Prometheus", "Grafana"]
featured: true
translationKey: "monitoring/postgresql-postgrespro-prometheus-monitoring"
---

## Context

Generic Linux monitoring can show CPU, memory, filesystem and network state, but it cannot explain most database-level incidents.

The production 1C database host in this environment runs Postgres Pro 1C 17.10 on AlmaLinux 9.8 and exposes database metrics through a dedicated `postgres_exporter.service` to Prometheus and Grafana.

The monitoring path is therefore split into two layers:

```text
Linux host metrics -> CPU / RAM / filesystem / network
PostgreSQL metrics -> sessions / transactions / locks / checkpoints / DB state
```

A healthy Linux host is not proof of a healthy database.

## Production baseline

Verified stack:

```text
OS: AlmaLinux 9.8
Database: Postgres Pro 1C 17.10
Database listener: loopback from exporter
Exporter service: postgres_exporter.service
Exporter port: 9187
Metrics backend: Prometheus
Visualization: Grafana
```

The exact `postgres_exporter` binary version is not claimed because the installed binary did not return a version string through the tested `--version` invocation.

## Actual systemd design

The production exporter runs as a dedicated unprivileged account:

```ini
[Service]
Type=simple
User=postgres_exporter
Group=postgres_exporter
```

The database connection is local to the host:

```ini
Environment="DATA_SOURCE_URI=127.0.0.1:5432/postgres?sslmode=disable"
Environment="DATA_SOURCE_USER=postgres_exporter"
Environment="DATA_SOURCE_PASS_FILE=/etc/postgres_exporter/password"
```

This has several useful properties:

- PostgreSQL credentials are not embedded in `ExecStart`;
- the password is read from a separate file;
- the exporter connects to PostgreSQL over loopback;
- the exporter endpoint and the PostgreSQL endpoint can be restricted independently.

Do not publish the password file contents. Keep its ownership and mode restrictive.

## Exporter command line

The production service starts:

```bash
/usr/local/bin/postgres_exporter \
  --config.file= \
  --web.listen-address=<db-host-ip>:9187 \
  --collector.database_wraparound \
  --collector.long_running_transactions \
  --collector.postmaster \
  --collector.stat_checkpointer \
  --no-collector.stat_replication
```

The internal address is intentionally omitted from the public runbook.

The unit explicitly passes an empty `--config.file=` and uses environment variables for the database connection.

The selected collectors reflect the current production requirements:

```text
database_wraparound
long_running_transactions
postmaster
stat_checkpointer
```

Replication collection is disabled because this monitored instance does not currently use that collector path:

```text
--no-collector.stat_replication
```

Do not enable collectors just because they exist. Each enabled collector should correspond to an operational question or alerting requirement.

## Listener model

The exporter is not bound to `0.0.0.0`.

It listens on one explicit internal address:

```text
<db-host-ip>:9187
```

The effective socket can be verified with:

```bash
ss -lntp | grep -E ':9187\b|postgres_exporter'
```

This is preferable to publishing the endpoint on every interface.

Firewall policy should still restrict TCP/9187 to the Prometheus collector path only.

## Service ordering

The unit starts after the database service and waits for network-online:

```ini
After=network-online.target postgrespro-1c-17.service
Wants=network-online.target
```

This gives the exporter a sensible startup order without making it part of the database service itself.

After a database restart, verify exporter collection rather than assuming the dependency ordering proves the connection is healthy.

## systemd hardening

The production unit applies several restrictions:

```ini
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
LockPersonality=true
RestrictSUIDSGID=true
RestrictRealtime=true
CapabilityBoundingSet=
AmbientCapabilities=
```

This is a good fit for an exporter process because it should not need privileged kernel access, elevated capabilities or write access across the host filesystem.

Any future change that requires broader permissions should be justified by the collector or integration that needs them rather than weakening the unit pre-emptively.

## Validate the running exporter

Check service state:

```bash
systemctl status postgres_exporter --no-pager
systemctl is-enabled postgres_exporter
```

Inspect the effective unit:

```bash
systemctl cat postgres_exporter
```

Check the listener:

```bash
ss -lntp | grep -E ':9187\b|postgres_exporter'
```

Because the exporter is bound to the internal host address rather than loopback, test the metrics endpoint using that address from an allowed monitoring path:

```bash
curl -fsS http://<db-host-ip>:9187/metrics | head
```

Then inspect recent exporter logs:

```bash
journalctl -u postgres_exporter -n 100 --no-pager
```

A reachable `/metrics` endpoint proves only that the exporter HTTP server is up. Repeated database collection errors still indicate an unhealthy monitoring path.

## Database monitoring account

The exporter uses a dedicated database account:

```text
postgres_exporter
```

That account should have only the permissions required by the enabled collectors.

Do not reuse:

```text
application database credentials
postgres superuser credentials
1C service credentials
```

Where possible, use PostgreSQL/Postgres Pro predefined monitoring roles plus only the additional grants required by actual custom queries.

## Prometheus scrape model

A sanitized scrape target can look like:

```yaml
scrape_configs:
  - job_name: postgresql
    static_configs:
      - targets:
          - db01.example.net:9187
        labels:
          service: postgresql
          role: database
```

Before applying a Prometheus change:

```bash
promtool check config /etc/prometheus/prometheus.yml
```

Then verify that the target is `UP` and that PostgreSQL metrics are actually changing over time.

## What to monitor

### Connections and long-running activity

Track session count against the real `max_connections` value and watch for abnormal growth.

The enabled `long_running_transactions` collector is useful because long transactions can contribute to lock retention, table bloat and delayed cleanup.

### Transaction activity and locks

Monitor transaction rates and contention together with host CPU/I/O and application errors.

A slow application may be caused by the database, but it may also be caused by storage pressure, network issues or the application tier.

### Checkpoints

The enabled `stat_checkpointer` collector provides checkpoint-related visibility.

Correlate checkpoint behavior with storage latency and write pressure rather than evaluating it in isolation.

### Postmaster state

The `postmaster` collector gives process-level database server state that is more useful than checking only whether a TCP port is open.

### Transaction ID wraparound

The `database_wraparound` collector exists for an important PostgreSQL failure mode: transaction ID exhaustion/wraparound risk.

This is exactly the type of condition that belongs in database-native monitoring rather than a generic Linux dashboard.

### Replication

Replication collection is intentionally disabled in the current service.

If replication is introduced later, enable and validate the relevant collector only after defining what lag/slot/replay state should be considered healthy.

## Grafana dashboard structure

A useful database dashboard should answer operational questions instead of showing every exported metric:

```text
Overview
  -> exporter / DB availability
  -> connections
  -> long-running transactions
  -> transaction activity
  -> locks / contention
  -> checkpoint activity
  -> wraparound risk
  -> host CPU / RAM / storage
```

Keep host panels close to database panels so that DB symptoms can be correlated with the resources underneath them.

## Alerting

Prefer actionable conditions:

```text
exporter unavailable
PostgreSQL unavailable
connections approaching limit
long-running transactions beyond accepted duration
persistent lock/contention condition
checkpoint/write pressure outside baseline
transaction ID wraparound risk
filesystem/storage approaching capacity
```

Thresholds must come from the actual 1C workload and maintenance model rather than from a generic imported dashboard.

## 1C monitoring boundary

PostgreSQL monitoring does not prove that the 1C application tier is healthy.

It cannot by itself prove that:

```text
the expected 1C server instance is active
the infobase is available to users
1C application operations complete successfully
cluster-level 1C state is normal
```

The production host already has a separate 1C metrics service/timer. Those signals belong in a dedicated 1C monitoring runbook.

## Security considerations

Keep the monitoring path constrained:

- dedicated `postgres_exporter` OS user;
- dedicated PostgreSQL monitoring account;
- password in `/etc/postgres_exporter/password`, not command-line arguments;
- PostgreSQL connection over loopback;
- exporter bound to one internal address;
- TCP/9187 reachable only from Prometheus;
- TCP/5432 restricted independently;
- systemd hardening retained unless a specific requirement justifies a change.

Monitoring should not create a second administrative path into the database.

## Backup and rollback

Before modifying the exporter path preserve:

```text
/etc/systemd/system/postgres_exporter.service
/etc/postgres_exporter/password metadata/permissions
Prometheus scrape configuration
Grafana dashboards/provisioning
alert rules
```

Do not copy the password itself into Git or documentation.

Rollback should mean restoring the previous exporter and monitoring configuration, not changing the application database.

## Validation checklist

```text
[ ] postgres_exporter.service active
[ ] exporter runs as postgres_exporter user/group
[ ] PostgreSQL connection remains on loopback
[ ] password is file-backed, not present in ExecStart
[ ] exporter listens only on the intended internal address:9187
[ ] firewall restricts 9187 to the monitoring path
[ ] journal has no repeating collection errors
[ ] Prometheus target = UP
[ ] database metrics are changing
[ ] Grafana displays current data
```

## References

- postgres_exporter project: <https://github.com/prometheus-community/postgres_exporter>
- Prometheus configuration: <https://prometheus.io/docs/prometheus/latest/configuration/configuration/>
- PostgreSQL monitoring statistics: <https://www.postgresql.org/docs/current/monitoring-stats.html>
- PostgreSQL predefined roles: <https://www.postgresql.org/docs/current/predefined-roles.html>
- Grafana documentation: <https://grafana.com/docs/grafana/latest/>
