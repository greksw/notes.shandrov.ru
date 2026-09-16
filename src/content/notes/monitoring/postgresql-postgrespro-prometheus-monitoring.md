---
title: "PostgreSQL / Postgres Pro monitoring with Prometheus and postgres_exporter"
description: "A production-backed monitoring pattern for PostgreSQL and Postgres Pro using postgres_exporter, Prometheus and Grafana, with database-native metrics separated from generic Linux monitoring."
category: "Monitoring & Security"
tags: ["postgresql", "postgres-pro", "prometheus", "postgres-exporter", "grafana", "monitoring"]
published: 2026-09-16
updated: 2026-09-16
status: current
testedOn: ["AlmaLinux 9.8", "Postgres Pro 1C 17.10", "postgres_exporter", "Prometheus", "Grafana"]
featured: true
translationKey: "monitoring/postgresql-postgrespro-prometheus-monitoring"
---

## Context

Generic Linux monitoring can show CPU, memory, filesystem and network state, but it cannot explain most database-level incidents.

For PostgreSQL/Postgres Pro, a useful observability model needs database-native metrics such as:

```text
connections
transaction activity
locks
cache/activity statistics
database size
background writer/checkpoint activity
replication state where used
```

The production 1C database host in this environment runs Postgres Pro 1C 17.10 on AlmaLinux 9.8 and already exposes PostgreSQL metrics through a dedicated `postgres_exporter` systemd service.

The database exporter is therefore treated as a separate signal source rather than trying to infer database health only from `postgres` process state or host metrics.

## Production baseline

Verified stack:

```text
OS: AlmaLinux 9.8
Database: Postgres Pro 1C 17.10
Exporter service: postgres_exporter.service
Metrics backend: Prometheus
Visualization: Grafana
```

The exact exporter build and current datasource configuration are intentionally not claimed here until they are captured from the running host.

## Monitoring layers

A useful database view combines several layers:

```text
Linux host metrics
       |
       +--> CPU / RAM / filesystem / network
       |
       v
PostgreSQL exporter
       |
       +--> database/session/activity metrics
       |
       v
Prometheus
       |
       v
Grafana
```

The two metric sources answer different questions.

Host monitoring can tell you that the server is under CPU pressure. PostgreSQL metrics can tell you whether the pressure correlates with connection growth, transaction activity or database workload.

## Validate the production service first

Before changing configuration, confirm the existing exporter service:

```bash
systemctl status postgres_exporter --no-pager
systemctl is-enabled postgres_exporter
```

Inspect the unit rather than assuming paths or command-line arguments:

```bash
systemctl cat postgres_exporter
```

This is important because exporter deployment methods differ. The service may use:

```text
an EnvironmentFile
a systemd drop-in
a wrapper script
direct command-line flags
```

Do not publish credentials from the unit or environment file.

## Confirm the exporter listener

Discover the actual listening socket:

```bash
ss -lntp | grep -i postgres_exporter
```

If process names are not visible to the current user, inspect the unit and process tree:

```bash
ps -ef | grep '[p]ostgres_exporter'
```

A common exporter port is `9187`, but operational documentation should use the actual configured port rather than assuming the default.

## Test the metrics endpoint locally

Once the actual listen address/port is known:

```bash
curl -fsS http://127.0.0.1:9187/metrics | head
```

Replace the port if the production unit uses another value.

A successful response proves that the exporter endpoint is reachable. It does not yet prove that database queries are succeeding.

Look for exporter/database collection errors as well as metrics:

```bash
journalctl -u postgres_exporter -n 100 --no-pager
```

## Database account model

The exporter should use a dedicated database account with only the privileges required for monitoring.

Do not reuse:

```text
application database credentials
postgres superuser credentials
1C service credentials
```

Keep the monitoring password outside public Git, shell scripts and documentation.

Depending on PostgreSQL/Postgres Pro version and required collectors, the monitoring account can use the built-in monitoring roles supported by the database plus any narrowly scoped grants needed by custom queries.

The exact grants should be validated against the exporter build and query set actually deployed.

## Keep the exporter private

There is normally no reason to expose the exporter endpoint to arbitrary networks.

Preferred pattern:

```text
Prometheus -> postgres_exporter
users      -X-> postgres_exporter
Internet   -X-> postgres_exporter
```

Restrict the listen address and/or firewall so that only the Prometheus collector path can reach it.

If Prometheus runs on the same host, loopback binding is sufficient.

If Prometheus is remote, allow only the monitoring source network or address.

## Prometheus scrape job

A minimal Prometheus target can look like:

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

Use sanitized DNS names in public documentation.

In a multi-site environment, add stable labels such as:

```text
site
role
service
environment
```

Do not place database names, SQL text, usernames or other unbounded values into target labels.

## Validate from Prometheus

First validate the Prometheus configuration:

```bash
promtool check config /etc/prometheus/prometheus.yml
```

Reload or restart according to the production deployment method.

Then confirm the target is `UP` in Prometheus.

At query level, start with exporter health/availability metrics exposed by the installed exporter and confirm that real PostgreSQL metrics are present.

Do not copy dashboard queries blindly from another exporter version: metric names can differ between releases and enabled collectors.

## What to monitor

### Connections

Useful questions:

```text
How many sessions are active?
How close is the database to its connection limit?
Is connection count growing abnormally?
```

A connection graph is more useful when compared with configured `max_connections` and application behavior.

### Transaction activity

Track transaction rates and database activity to establish a normal workload baseline.

A sudden drop can be as meaningful as a spike if the application should be busy.

### Locks and contention

Lock metrics help distinguish a slow application from database contention.

For incident analysis, correlate lock growth with:

```text
application errors
query latency where collected
CPU / I/O pressure
connection growth
```

### Database size

Database growth is useful for capacity planning but should not be confused with filesystem free space.

Monitor both:

```text
logical database growth
underlying filesystem/storage capacity
```

### Cache and activity statistics

PostgreSQL exposes statistics that help show whether workload behavior changed over time.

Use them primarily as trends. A single ratio without workload context is rarely a complete performance diagnosis.

### Checkpoints and write activity

Checkpoint/background-writer metrics can help correlate write pressure with storage latency and application slowdowns.

They are most useful when host/storage metrics are visible on the same time range.

### Replication

If replication is used, monitor it explicitly:

```text
replica availability
lag
WAL/replay progress
replication slot state where applicable
```

Do not create replication alerts on systems that do not use replication.

## Grafana dashboard structure

A database dashboard should answer operational questions rather than show every exported metric.

A useful layout is:

```text
Overview
  -> exporter/DB availability
  -> connections
  -> transaction/activity rate
  -> locks
  -> database size
  -> checkpoints/write activity
  -> host CPU/RAM/storage
  -> replication, if used
```

Keep host-level panels close to PostgreSQL panels. This makes it easier to see whether a database event is caused by the database layer or by resource pressure underneath it.

## Alerting principles

Avoid alerts such as "metric changed".

Prefer actionable conditions such as:

```text
exporter unreachable
PostgreSQL unavailable
connection usage approaching configured limit
persistent lock/contention condition
database/filesystem growth approaching capacity
replication lag outside the accepted window
```

Thresholds should come from the actual application workload and maintenance model, not from a generic dashboard import.

## 1C-specific boundary

This database is part of a 1C stack, but PostgreSQL monitoring and 1C monitoring should remain separate concerns.

PostgreSQL metrics can show database behavior, but they do not prove that:

```text
1C server processes are healthy
the expected 1C platform instance is running
the infobase is available to users
1C application-level operations succeed
```

The production environment already has a separate 1C metrics service/timer. Those application-specific signals belong in a dedicated 1C monitoring runbook.

## Security considerations

For the exporter path:

- use a dedicated DB monitoring account;
- do not expose exporter credentials in Git;
- restrict the exporter listener;
- avoid putting secrets in systemd command-line arguments where possible;
- protect environment/config files with restrictive permissions;
- do not expose exporter endpoints to the Internet;
- keep database TCP/5432 independently restricted.

Monitoring access should not become an alternate administrative path into the database.

## Backup and rollback

Monitoring changes should not modify the production database schema unless a specific approved collector requires it.

Before changing an existing exporter deployment, preserve:

```text
systemd unit / drop-ins
exporter environment/config files
Prometheus scrape configuration
custom query files, if used
Grafana dashboard JSON/provisioning
alert rules
```

Rollback should mean restoring the previous exporter/configuration state, not touching the application database.

## Validation checklist

```text
[ ] postgres_exporter service active
[ ] exporter endpoint reachable only from intended monitoring path
[ ] exporter journal has no repeated DB collection errors
[ ] Prometheus target is UP
[ ] database metrics are present
[ ] host and DB labels identify the target consistently
[ ] Grafana panels show current, changing data
[ ] alert rules can be tested safely
```

## Information still worth capturing from production

To make this runbook fully implementation-specific, capture the non-secret runtime details:

```bash
postgres_exporter --version 2>/dev/null || true
systemctl cat postgres_exporter
ss -lntp | grep -E ':9187\b|postgres_exporter'
```

And from Prometheus, capture the sanitized scrape job used for this host.

Do not include database passwords or connection strings containing credentials.

## References

- postgres_exporter project: <https://github.com/prometheus-community/postgres_exporter>
- Prometheus configuration: <https://prometheus.io/docs/prometheus/latest/configuration/configuration/>
- PostgreSQL monitoring statistics: <https://www.postgresql.org/docs/current/monitoring-stats.html>
- PostgreSQL predefined roles: <https://www.postgresql.org/docs/current/predefined-roles.html>
- Grafana documentation: <https://grafana.com/docs/grafana/latest/>
