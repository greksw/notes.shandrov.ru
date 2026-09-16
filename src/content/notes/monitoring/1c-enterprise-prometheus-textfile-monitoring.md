---
title: "1C:Enterprise monitoring with node_exporter textfile collector, Prometheus and Grafana"
description: "A production-backed 1C:Enterprise 8 monitoring pattern using a systemd timer, a custom shell collector, node_exporter textfile metrics, Prometheus and Grafana."
category: "Monitoring & Security"
tags: ["1c", "prometheus", "node-exporter", "grafana", "systemd", "monitoring"]
published: 2026-09-16
updated: 2026-09-16
status: current
testedOn: ["AlmaLinux 9.8", "1C:Enterprise 8.3.27.2325", "node_exporter textfile collector", "Prometheus", "Grafana"]
featured: true
translationKey: "monitoring/1c-enterprise-prometheus-textfile-monitoring"
---

## Context

Generic Linux monitoring is useful for CPU, memory, filesystem and network state, but it does not answer basic 1C:Enterprise service questions:

```text
Is the expected 1C service active?
Are ragent/rmngr/rphost processes present?
Are the expected cluster listeners open?
Did the custom collector itself stop updating?
```

The production monitoring path described here adds a small host-local collector for those signals and exports them through the existing `node_exporter` textfile collector.

The result is intentionally simple:

```text
1C:Enterprise 8.3.27.2325
        |
        v
custom shell collector
        |
        v
Prometheus text-format file
        |
        v
node_exporter textfile collector
        |
        v
Prometheus
        |
        v
Grafana / alerting
```

This is a good fit for state that belongs to one machine and can be sampled cheaply without introducing a separate long-running exporter.

## Verified production baseline

The current implementation uses:

```text
OS: AlmaLinux 9.8
1C platform: 8.3.27.2325
1C systemd instance: srv1cv8-8.3.27.2325@default.service
collector service: fm-1c-metrics.service
collector timer: fm-1c-metrics.timer
collector script: /usr/local/sbin/fm-1c-metrics.sh
output file: /var/lib/node_exporter/textfile_collector/fm_1c.prom
collection interval: 30 seconds
```

The service is a `Type=oneshot` unit. Therefore an `inactive (dead)` state between runs is expected and is not a failure by itself.

The health of this pattern is determined by:

- successful recent executions;
- an active timer;
- fresh metrics output;
- successful Prometheus scrapes.

## Why use the node_exporter textfile collector

The official node_exporter textfile collector reads `*.prom` files from a configured directory and exposes their contents together with normal host metrics.

That makes it suitable for machine-local state produced by short-running jobs.

The current node_exporter unit explicitly enables:

```bash
--collector.textfile.directory=/var/lib/node_exporter/textfile_collector
```

No separate TCP service is required for the custom 1C collector itself.

## systemd timer design

The collector is launched by a timer:

```ini
[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
AccuracySec=5s
Unit=fm-1c-metrics.service
```

This gives a roughly 30-second sampling cadence after boot and after each successful activation.

For this type of lightweight local check, systemd timers have several advantages over embedding an infinite loop in the collector:

- every run has its own exit status;
- failures appear in the journal;
- the process does not remain resident;
- restart/reload behavior stays simple;
- timer state can be inspected independently.

Validate the timer with:

```bash
systemctl status fm-1c-metrics.timer --no-pager
systemctl list-timers fm-1c-metrics.timer --all
```

## Collector service

The oneshot unit is intentionally small:

```ini
[Unit]
Description=1C metrics collector for node_exporter
After=srv1cv8-8.3.27.2325@default.service node_exporter.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/fm-1c-metrics.sh
User=root
Group=root

NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/var/lib/node_exporter/textfile_collector
```

The production implementation currently runs as root, but filesystem writes are constrained to the textfile collector directory by systemd hardening.

Root is not inherently required by the monitoring model itself. A future refactor could use a dedicated collector account and group-writable output directory if all required `systemctl`, `pgrep`, `ss` and file-ownership operations remain available without privilege escalation.

Do not weaken the unit pre-emptively. Change privileges only when an actual collector requirement needs it.

## Metrics collected

The collector currently publishes the following metric families:

```text
fm_1c_info
fm_1c_service_up
fm_1c_ragent_processes
fm_1c_rmngr_processes
fm_1c_rphost_processes
fm_1c_ras_processes
fm_1c_listener_up
fm_1c_collector_timestamp_seconds
fm_1c_collector_success
```

### Platform version

A static info metric records the monitored platform version:

```text
fm_1c_info{version="8.3.27.2325"} 1
```

This is useful when the same dashboard covers several 1C servers during a staged upgrade.

### systemd service state

The collector checks the exact production service instance:

```text
srv1cv8-8.3.27.2325@default.service
```

and exports:

```text
fm_1c_service_up 1
```

This avoids an ambiguous process-only check when several 1C versions are installed on the same host.

### Process counts

The script uses exact-name `pgrep` checks for:

```text
ragent
rmngr
rphost
ras
```

and exports their counts as gauges.

Example production snapshot:

```text
fm_1c_ragent_processes 1
fm_1c_rmngr_processes 1
fm_1c_rphost_processes 2
fm_1c_ras_processes 0
```

Do not interpret every zero as a failure.

For example, `ras` is only required if the Remote Administration Server is part of the intended design. An alert should encode the expected architecture rather than assume every optional process must always be running.

## Listener checks

The collector checks expected TCP listeners with `ss` and exports one labeled metric family:

```text
fm_1c_listener_up{port="1540",component="ragent"} 1
fm_1c_listener_up{port="1541",component="rmngr"} 1
fm_1c_listener_up{port="1576",component="fts"} 1
```

The current environment expects these three listeners.

The 1C platform documentation identifies the standard cluster model as:

```text
1540       server agent
1541       cluster manager
1560-1591  working-process range
```

The specific `1576` label is therefore an environment-specific check inside the configured working-process range, not a universal requirement for every 1C deployment.

When this monitoring pattern is reused elsewhere, derive the expected listener set from the actual 1C service arguments and cluster design.

## Collector freshness

The script publishes the completion timestamp:

```text
fm_1c_collector_timestamp_seconds <unix-time>
```

This metric is more important than it may first appear.

The collector writes the new file only after a successful run. If a future execution fails, the previous `fm_1c.prom` remains in place. Therefore this metric:

```text
fm_1c_collector_success 1
```

can remain visible from the last successful run even though newer runs are failing.

For failure detection, alert on **age**, not only on the success gauge.

Example PromQL:

```promql
time() - fm_1c_collector_timestamp_seconds > 120
```

With a 30-second timer this gives several missed executions before alerting. Choose the threshold according to the intended sampling interval and alert tolerance.

`fm_1c_collector_success` is still useful as a format/status marker for successfully generated files, but it is not sufficient as the only collector-health alert.

## Atomic metric-file updates

The script uses a temporary file:

```bash
TMP="${OUT}.tmp.$$"
```

writes the complete metric set there, validates it, applies permissions, and only then performs:

```bash
mv -f "$TMP" "$OUT"
```

This pattern is important.

node_exporter parses files matching `*.prom`. The temporary filename does not match that suffix, so node_exporter does not see a half-written exposition. The final rename replaces the old file only after the new payload is complete.

This follows the same atomic-write model recommended by the node_exporter project for the textfile collector.

## Metric validation

Before the file is published, the script performs two useful guardrails.

First, every generated value is checked as numeric:

```bash
[[ "$VALUE" =~ ^[0-9]+$ ]]
```

Second, an `awk` check rejects accidental bare lines containing fewer than two fields.

This protects against a previous failure mode where a metric line was followed by an orphan value such as:

```text
fm_1c_ras_processes 0
0
```

The check is intentionally lightweight; it is not a complete Prometheus exposition parser.

For manual validation or CI around future collector changes, the generated file can also be linted with `promtool`:

```bash
cat /var/lib/node_exporter/textfile_collector/fm_1c.prom |
  promtool check metrics
```

## Ownership and permissions

The final file is normalized to:

```text
owner: node_exporter
mode: 0644
```

The observed directory is owned by `node_exporter` and contains only the generated `fm_1c.prom` file in the current implementation.

The collector itself is the writer; node_exporter only needs to read the resulting file.

## node_exporter service

The verified unit includes:

```bash
/usr/local/bin/node_exporter \
  --web.listen-address=0.0.0.0:9100 \
  --collector.textfile.directory=/var/lib/node_exporter/textfile_collector
```

and runs under a dedicated account with systemd hardening such as:

```ini
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
CapabilityBoundingSet=
AmbientCapabilities=
```

One operational point needs separate validation: the verified service binds node_exporter to all interfaces on TCP/9100.

That does not automatically mean the endpoint is publicly reachable; firewall and routing policy determine actual exposure. However, the monitoring network should be the only path allowed to reach TCP/9100.

Where the design permits it, binding node_exporter to a specific management address is narrower than `0.0.0.0`.

## Validate the complete path

### 1. Run the collector manually

```bash
systemctl start fm-1c-metrics.service
systemctl status fm-1c-metrics.service --no-pager
```

For a oneshot service, successful completion should end in `inactive (dead)` with exit status 0.

### 2. Validate the generated file

```bash
cat /var/lib/node_exporter/textfile_collector/fm_1c.prom
```

Optionally lint it:

```bash
cat /var/lib/node_exporter/textfile_collector/fm_1c.prom |
  promtool check metrics
```

### 3. Validate node_exporter exposure

```bash
curl -fsS http://127.0.0.1:9100/metrics |
  grep '^fm_1c_'
```

If node_exporter is intentionally not reachable on loopback in another design, query the configured management address instead.

### 4. Validate Prometheus

Confirm the node target is `UP`, then query:

```promql
fm_1c_service_up
```

and:

```promql
time() - fm_1c_collector_timestamp_seconds
```

The second query should remain close to the timer interval rather than continuously increasing.

## Useful alerting rules

The exact thresholds should match the production cluster design, but the following conditions are structurally useful.

### Main 1C service down

```promql
fm_1c_service_up == 0
```

### Collector stale

```promql
time() - fm_1c_collector_timestamp_seconds > 120
```

### Required agent or manager process missing

```promql
fm_1c_ragent_processes < 1
```

```promql
fm_1c_rmngr_processes < 1
```

### Required listener missing

```promql
fm_1c_listener_up{port="1540"} == 0
```

```promql
fm_1c_listener_up{port="1541"} == 0
```

Do not create a generic `rphost == 2` alert just because the current snapshot contains two workers. Worker counts can legitimately vary with cluster configuration and load.

## Grafana dashboard structure

A compact 1C dashboard can use the custom metrics as the application header above the generic Linux and PostgreSQL panels:

```text
1C service
  -> service state
  -> collector freshness
  -> ragent/rmngr/rphost process counts
  -> expected listeners

Linux host
  -> CPU
  -> memory
  -> filesystem
  -> network

PostgreSQL / Postgres Pro
  -> connections
  -> long-running transactions
  -> locks/activity
  -> checkpoints
```

This produces a useful vertical view from operating system through application server to database.

## What this collector does not prove

These metrics intentionally cover local infrastructure state. They do not prove that:

```text
a specific infobase can be opened by a user
a business transaction completes successfully
an external web publication works
all 1C cluster sessions are healthy
application response time is acceptable
```

Those require higher-level checks using 1C administration interfaces, synthetic transactions or application-specific telemetry.

Do not turn a lightweight textfile collector into a full 1C observability protocol without a clear requirement.

## Failure modes

### Timer stopped

The `.prom` file remains on disk, so Prometheus can continue scraping old values.

Detect this with the collector timestamp age.

### Collector script exits before rename

The old output remains intact because the new temporary file is never moved into place.

This prevents partial data but again makes freshness alerting mandatory.

### node_exporter down

All host and custom textfile metrics disappear together. Alert on normal Prometheus target availability independently of `fm_1c_*` rules.

### 1C service changes version

The script currently pins both:

```text
VERSION=8.3.27.2325
UNIT=srv1cv8-8.3.27.2325@default.service
```

A platform upgrade must therefore update and validate the collector at the same time. This is intentional: monitoring should follow the actual active 1C instance instead of silently checking an obsolete service.

## Backup and rollback

Before changing the collector preserve:

```text
/etc/systemd/system/fm-1c-metrics.service
/etc/systemd/system/fm-1c-metrics.timer
/usr/local/sbin/fm-1c-metrics.sh
node_exporter unit / drop-ins
Prometheus rules
Grafana dashboard/provisioning
```

Rollback is straightforward: restore the previous script/unit files, run `systemctl daemon-reload`, restart the timer if required, and confirm that the output file timestamp starts advancing again.

The monitoring collector does not need to modify the 1C configuration itself.

## Validation checklist

```text
[ ] 1C service instance is the intended version
[ ] fm-1c-metrics.timer active
[ ] last oneshot execution exited 0
[ ] fm_1c.prom updated within the expected interval
[ ] promtool check metrics succeeds when available
[ ] node_exporter exposes fm_1c_* metrics
[ ] Prometheus target is UP
[ ] collector freshness query remains below alert threshold
[ ] required service/process/listener alerts match the real cluster design
[ ] TCP/9100 exposure is limited by bind/firewall/routing policy
```

## References

- node_exporter textfile collector: <https://github.com/prometheus/node_exporter#textfile-collector>
- Prometheus text exposition format: <https://prometheus.io/docs/instrumenting/exposition_formats/>
- `promtool check metrics`: <https://github.com/prometheus/prometheus/blob/main/docs/command-line/promtool.md>
- 1C:Enterprise server ports: <https://kb.1ci.com/1C_Enterprise_Platform/FAQ/Administration/Server/Ports_setup_for_1C_Enterprise_server/>
- Prometheus documentation: <https://prometheus.io/docs/>
- Grafana documentation: <https://grafana.com/docs/grafana/latest/>
