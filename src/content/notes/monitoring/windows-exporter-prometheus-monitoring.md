---
title: "Windows Server monitoring with windows_exporter and Prometheus"
description: "A production-backed Windows Server monitoring pattern using windows_exporter 0.31.8, Prometheus file-based discovery, recording rules and alerting."
category: "Monitoring & Security"
tags: ["windows", "windows-exporter", "prometheus", "monitoring", "alerting"]
published: 2026-09-16
updated: 2026-09-16
status: current
testedOn: ["Windows Server 2022 Standard build 20348", "windows_exporter 0.31.8", "Prometheus file_sd"]
featured: true
translationKey: "monitoring/windows-exporter-prometheus-monitoring"
---

## Context

The production Windows monitoring path is intentionally simple:

```text
Windows Server
    -> windows_exporter
    -> Prometheus file_sd
    -> recording rules
    -> alerting / Grafana
```

A representative Windows Server 2022 host was verified end to end together with the active Prometheus target and the shared Windows rule file.

## Verified baseline

Representative host:

```text
Windows Server 2022 Standard
build 20348
windows_exporter 0.31.8
service state: Running
start mode: Automatic
service account: LocalSystem
listener: TCP/9182
```

The exporter service starts with:

```text
--config.file="C:\Program Files\windows_exporter\config.yaml"
--collectors.enabled cpu,logical_disk,memory,net,os,physical_disk,service,system,pagefile,time
```

The referenced YAML file is currently empty; collector selection is therefore defined explicitly on the service command line.

All enabled collectors reported success in the verified snapshot.

## Exporter exposure

The exporter listens on the wildcard listener for TCP/9182. Access is constrained by Windows Firewall rather than by binding the exporter to one host address.

The active inbound firewall rule allows TCP/9182 only from the Prometheus server address.

This is an important distinction:

```text
wildcard listener != unrestricted network access
```

The actual exposure is determined by both the listener and firewall scope.

## Prometheus discovery

The central Prometheus job uses file-based service discovery:

```yaml
- job_name: windows
  scrape_interval: 30s
  scrape_timeout: 10s

  file_sd_configs:
    - files:
        - /etc/prometheus/targets/windows/servers.yml
      refresh_interval: 30s
```

The current inventory contains seven Windows Server targets.

Each target carries labels such as:

```text
instance
site
role
platform
```

One legacy terminal server is additionally labeled as legacy.

A sanitized target entry looks like:

```yaml
- targets:
    - <windows-host>:9182
  labels:
    instance: <server-name>
    site: fm
    role: windows-server
    platform: windows
```

## Runtime validation

Do not stop at configuration syntax. Confirm what Prometheus actually loaded.

The representative production target reported:

```text
scrape pool: windows
job: windows
health: up
last error: empty
scrape interval: 30s
scrape timeout: 10s
```

This verifies the full path from Prometheus to windows_exporter.

## Recording rules

The production Windows rule file normalizes the main host metrics into:

```text
fm:windows:up
fm:windows:cpu_usage_percent
fm:windows:memory_usage_percent
fm:windows:disk_usage_percent
fm:windows:uptime_seconds
```

### CPU

CPU usage is derived from the idle mode of `windows_cpu_time_total` over five minutes.

Alert policy:

```text
warning:  90-97% for 15m
critical: >=97% for 5m
```

### Memory

Current windows_exporter 0.31.8 exposes:

```text
windows_memory_available_bytes
windows_memory_physical_total_bytes
```

The shared recording rule also keeps a compatibility fallback for an older physical-memory metric name. On the verified host, the current metric is `windows_memory_physical_total_bytes`.

Alert policy:

```text
warning:  >85% used and <=92% for 15m
critical: >92% used for 5m
```

### Logical disks

Only drive-letter volumes are included:

```promql
volume=~"[A-Z]:"
```

This intentionally excludes system partitions exposed as names such as `HarddiskVolume*`.

Alert policy:

```text
warning:  >85% used and <=93% for 15m
critical: >93% used for 5m
```

### Uptime

The verified exporter exposes:

```text
windows_system_boot_time_timestamp
```

The rule file keeps a compatibility fallback for an older system-uptime metric. The current production path uses the boot-time timestamp.

## Exporter integrity

Three checks protect the monitoring path itself.

The target-count contract expects exactly seven Windows targets. A mismatch lasting two minutes is critical.

`WindowsExporterDown` fires when Prometheus cannot scrape a Windows target for three minutes.

`WindowsCollectorFailed` watches:

```promql
windows_exporter_collector_success == 0
```

for five minutes and reports the failed collector.

## Enabled collectors versus active alert policy

The exporter currently enables:

```text
cpu
logical_disk
memory
net
os
physical_disk
service
system
pagefile
time
```

The generic Windows rule file currently uses CPU, memory, logical-disk, system/uptime and exporter-integrity metrics.

It does not currently define generic fleet-wide alerts for network, physical-disk latency, pagefile usage, Windows services or time drift. Those collectors remain available for dashboards and future role-specific policy, but this note does not invent alerts that are not present in production.

## Validation

On Windows:

```powershell
& "C:\Program Files\windows_exporter\windows_exporter.exe" --version
Get-CimInstance Win32_Service -Filter "Name='windows_exporter'"
Get-NetTCPConnection -State Listen -LocalPort 9182
```

Check collector health:

```powershell
$Metrics = (Invoke-WebRequest -UseBasicParsing http://127.0.0.1:9182/metrics).Content -split "`r?`n"
$Metrics | Where-Object { $_ -match '^windows_exporter_collector_success' }
```

On Prometheus, validate configuration and runtime target health separately.

## Change procedure

When onboarding another Windows Server:

1. install the approved windows_exporter build;
2. configure the required collector set;
3. confirm the service is automatic and running;
4. allow TCP/9182 only from the Prometheus source through Windows Firewall;
5. add the host to the file_sd inventory with the standard labels;
6. update the expected target count;
7. validate Prometheus configuration;
8. reload Prometheus;
9. confirm the runtime target is UP;
10. verify recording rules return data for the new instance.

## Rollback

Preserve the previous exporter service configuration, firewall rule, target inventory and alert-rule version before changes.

Rollback consists of restoring those files/settings, validating Prometheus configuration again and confirming that the target and recording rules return to the previous state.

## What this layer does not prove

Healthy Windows host metrics do not prove that Active Directory, RDP sessions, application services or business workloads are healthy.

Host monitoring is the common machine-level layer. Service-specific checks should be added separately where they reflect real operational requirements.

## References

- windows_exporter: <https://github.com/prometheus-community/windows_exporter>
- Prometheus file-based service discovery: <https://prometheus.io/docs/prometheus/latest/configuration/configuration/#file_sd_config>
- Prometheus recording rules: <https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/>
- Prometheus alerting rules: <https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/>
