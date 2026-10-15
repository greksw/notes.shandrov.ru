---
title: "PostgreSQL 17 Maintenance for 1C: XID Age, VACUUM, and Autovacuum"
description: "Production case study: Postgres Pro 1C 17.10, XID age warnings, targeted maintenance of 18 databases, and database-level freeze statistics."
category: "Applications & Services"
tags: ["postgresql", "postgres-pro", "1c", "vacuum", "autovacuum", "xid", "monitoring"]
published: 2026-10-15
updated: 2026-10-15
status: current
testedOn: ["AlmaLinux 9", "Postgres Pro 1C 17.10", "1C:Enterprise 8.3"]
featured: true
translationKey: "applications/postgres-pro-1c-xid-vacuum-maintenance"
---

## Production incident

In October 2026, monitoring showed a growing transaction ID age on a production **Postgres Pro 1C 17.10** host serving **26 1C:Enterprise databases**. The maximum was **181,631,691 XIDs**, or **90.82% of the configured autovacuum_freeze_max_age value (200 million)**.

This percentage is measured against the anti-wraparound autovacuum trigger, **not the actual transaction-ID wraparound boundary**. Nonetheless, it justified diagnosis and carefully scheduled maintenance.

The goal was to reduce old transaction ID age while keeping the 1C application available. A total of **18 databases were maintained sequentially** with ordinary VACUUM. No VACUUM FULL or database restart was needed.

## Verified before-and-after measurements

| Metric | Before | After |
| --- | ---: | ---: |
| Total databases | 26 | 26 |
| Databases selected for maintenance | 18 | 18 processed |
| Maximum database XID age | 181,631,691 | 159,997,686 |
| Percentage of freeze threshold | 90.82% | around 80% |
| Example database XID age | 181,335,365 | 152,808,739 |
| Checked MultiXact age | — | 0 |

These are measurements at the time of the incident. XID age continues to grow as normal transactions execute.

The host ran **AlmaLinux 9**, a dedicated `postgrespro-1c-17` systemd service, and `postgres_exporter`. Approximately 53 GB was free on the inspected filesystem, which was about 83% full. Identifying hostnames and production database names are intentionally omitted.

## 1. Inspect PostgreSQL and its settings

Start with read-only checks rather than changing configuration:

~~~bash
systemctl is-active postgrespro-1c-17
df -h
sudo -u postgres psql -X -d postgres -P pager=off
~~~

Within psql:

~~~sql
SELECT version();
SHOW autovacuum;
SHOW autovacuum_freeze_max_age;
SHOW autovacuum_max_workers;
SHOW autovacuum_naptime;
SHOW maintenance_work_mem;
SHOW log_autovacuum_min_duration;
~~~

The observed configuration included autovacuum enabled, 16 autovacuum workers, a 20-second naptime, 1 GB maintenance memory, a 2 ms autovacuum cost delay, and an inherited vacuum cost limit of 1600. **These are observations, not general tuning recommendations.**

## 2. Identify databases with the oldest XIDs

~~~sql
SELECT
    datname,
    age(datfrozenxid) AS xid_age,
    round(
      100.0 * age(datfrozenxid) /
      current_setting('autovacuum_freeze_max_age')::numeric, 2
    ) AS pct_of_freeze_limit,
    mxid_age(datminmxid) AS mxid_age
FROM pg_database
ORDER BY age(datfrozenxid) DESC;
~~~

The database-level `datfrozenxid` is constrained by the oldest relevant relation-level horizon. A user table, system catalog or TOAST relation can hold it back. Connect to a problematic database and identify the oldest relations:

~~~sql
SELECT
    n.nspname AS schema_name,
    c.relname AS relation_name,
    c.relkind,
    age(c.relfrozenxid) AS xid_age,
    mxid_age(c.relminmxid) AS mxid_age
FROM pg_class AS c
JOIN pg_namespace AS n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'm', 't')
ORDER BY age(c.relfrozenxid) DESC
LIMIT 30;
~~~

The incident involved old horizons in **system catalogs, application tables and TOAST**. Checking only the public schema would have missed important objects.

~~~sql
SELECT schemaname, relname, n_live_tup, n_dead_tup,
       last_vacuum, last_autovacuum,
       vacuum_count, autovacuum_count
FROM pg_stat_all_tables
ORDER BY n_dead_tup DESC
LIMIT 25;
~~~

These are estimated statistics; a missing autovacuum timestamp on one table is not proof of a broken daemon.

## 3. Check long-lived transaction horizons

~~~sql
SELECT pid, datname, usename, state,
       now() - xact_start AS xact_duration,
       backend_xmin, wait_event_type, wait_event
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
ORDER BY xact_start;
~~~

~~~sql
SELECT gid, database, prepared FROM pg_prepared_xacts;
SELECT slot_name, slot_type, active, xmin, catalog_xmin, restart_lsn
FROM pg_replication_slots;
~~~

In this case, long-running transactions, prepared transactions and replication slots did not account for the elevated age. Do not terminate sessions or drop slots without establishing their purpose.

## 4. Autovacuum diagnostics

~~~sql
SELECT backend_type, pid, datname, state,
       wait_event_type, wait_event
FROM pg_stat_activity
WHERE backend_type LIKE 'autovacuum%'
ORDER BY backend_type, pid;
~~~

The autovacuum launcher was running. At one snapshot, no workers were visible. **That alone is expected when no autovacuum job is active**; it does not demonstrate a failure.

Review table statistics, log output and actual progress over time rather than relying on a single process snapshot.

## 5. Sequential VACUUM with low lock exposure

First verify backups, free space, I/O latency, 1C workloads and the maintenance window. Ordinary VACUUM generally supports concurrent DML, but still adds significant I/O load and may conflict with DDL.

For one anonymized database:

~~~bash
DB='accounting_demo'

sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d "$DB" \
  -c "VACUUM (TRUNCATE FALSE, SKIP_DATABASE_STATS, PARALLEL 0);"

sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d "$DB" \
  -c "VACUUM (ONLY_DATABASE_STATS);"
~~~

- `TRUNCATE FALSE` avoids trying to truncate empty pages at the relation end, limiting associated exclusive-lock exposure.
- `PARALLEL 0` disables parallel index-processing workers for this VACUUM.
- `SKIP_DATABASE_STATS` postpones recalculation of the database-wide oldest frozen transaction ID.
- `ONLY_DATABASE_STATS` updates that summary after relation vacuuming without vacuuming every table again.

Run VACUUM outside an explicit transaction block. The options do not eliminate disk pressure. Stop scheduling additional databases if latency or application lock waits worsen.

## 6. The important database-statistics pitfall

After VACUUM with `SKIP_DATABASE_STATS`, a relation's `relfrozenxid` may advance while the database's `datfrozenxid` still reports the old value. This is **not automatically evidence that VACUUM failed**.

Run the following in every database maintained using the skip option:

~~~sql
VACUUM (ONLY_DATABASE_STATS);
~~~

This step **does not perform more tuple freezing**. It updates the database-level frozen-XID metadata; if the age remains high, inspect the oldest relations again. Do not combine ONLY_DATABASE_STATS with ANALYZE or other enabled VACUUM options apart from VERBOSE.

## 7. Observe vacuum progress

~~~sql
SELECT pid, datname, relid::regclass AS relation_name,
       phase, heap_blks_total, heap_blks_scanned,
       round(100.0 * heap_blks_scanned /
             NULLIF(heap_blks_total, 0), 1) AS scan_pct
FROM pg_stat_progress_vacuum
ORDER BY datname, pid;
~~~

The percentage describes heap blocks scanned, **not the completion percentage of the entire VACUUM**. Index and cleanup phases may still be pending.

## 8. Temporary autovacuum logging

The initial `log_autovacuum_min_duration` was 600000 ms (10 minutes). For diagnosis it was set to 60 seconds, making long automatic vacuum operations easier to observe.

~~~sql
SELECT name, setting, unit, source, sourcefile
FROM pg_settings
WHERE name = 'log_autovacuum_min_duration';

ALTER SYSTEM SET log_autovacuum_min_duration = '60s';
SELECT pg_reload_conf();
SHOW log_autovacuum_min_duration;
~~~

Only modify settings this way if they are not exclusively managed by configuration automation and you have approval. On the investigated server logging used `logging_collector = on`, `log_destination = stderr`, and a log directory under the data directory.

~~~bash
PGDATA=$(sudo -u postgres psql -XAt -d postgres \
  -c 'SHOW data_directory;')
grep -Ei 'autovacuum|automatic vacuum' \
  "$PGDATA"/log/postgresql-*.log | tail -n 80
~~~

A log entry indicating that the parameter changed **does not prove a vacuum succeeded**. Correlate actual maintenance records with relation statistics.

Restore the documented original 10-minute setting once sufficient evidence has been collected and the operational decision is approved:

~~~sql
ALTER SYSTEM SET log_autovacuum_min_duration = '600000ms';
SELECT pg_reload_conf();
~~~

This is a **rollback example, not confirmation that the rollback happened**. Preserve the real original value and configuration source in each environment.

## 9. Verify the outcome and set up monitoring

Repeat the cluster-wide XID-age query and relation-level checks. Following maintenance of 18 databases, the highest observed database XID age was **159,997,686** and MultiXact age was 0 in the checked databases. One database decreased from 181,335,365 to 152,808,739.

A successful shell exit code is not sufficient. Verify database statistics, server logs and working 1C sessions.

For future monitoring, collect per-database XID/MultiXact ages relative to their configured freeze thresholds, oldest relation horizons, long transactions, autovacuum duration, dead-tuple estimates, free disk space, I/O latency and backup outcomes.

~~~sql
SELECT datname, age(datfrozenxid) AS xid_age,
       current_setting('autovacuum_freeze_max_age')::bigint
           AS xid_freeze_limit
FROM pg_database
WHERE datallowconn;
~~~

This is an **example monitoring query**, not a claim that specific alerts are already deployed. Tune warning levels using the actual XID growth rate and response time.

## Lessons learned

This incident required **careful measurement rather than an emergency restart**. Relation-level analysis and the separate ONLY_DATABASE_STATS step made the database-level result interpretable. We intentionally avoided VACUUM FULL, broad parallel operations, disabling autovacuum and manually deleting PostgreSQL transaction/WAL files.

The remaining follow-up is to assess long-running autovacuum logs, confirm the final logging configuration, and establish trend-based alerts.

Related: [1C:Enterprise 8 + Postgres Pro 1C + Apache on AlmaLinux](/notes/applications/1c8-postgres-apache-almalinux/).

## References

- [PostgreSQL 17: Routine Vacuuming](https://www.postgresql.org/docs/17/routine-vacuuming.html)
- [PostgreSQL 17: VACUUM](https://www.postgresql.org/docs/17/sql-vacuum.html)
- [PostgreSQL 17: Autovacuum Configuration](https://www.postgresql.org/docs/17/runtime-config-autovacuum.html)
- [PostgreSQL 17: Progress Reporting](https://www.postgresql.org/docs/17/progress-reporting.html)
