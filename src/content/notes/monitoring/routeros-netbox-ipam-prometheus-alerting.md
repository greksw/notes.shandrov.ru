---
title: "Monitoring a RouterOS–NetBox IPAM audit with systemd and Prometheus"
description: "A production-focused pattern for IPAM drift monitoring: atomic Node Exporter textfile metrics, systemd timers, PromQL alerts and Alertmanager routing verification."
category: "Monitoring & Security"
tags: ["netbox", "mikrotik", "routeros", "ipam", "prometheus", "node-exporter", "alertmanager", "systemd", "selinux", "observability"]
published: 2026-10-21
updated: 2026-10-21
status: current
testedOn: ["AlmaLinux 9", "Python 3.11", "Prometheus", "Node Exporter Textfile Collector", "Alertmanager 0.34", "systemd", "SELinux Enforcing"]
featured: false
lang: en
translationKey: "monitoring/routeros-netbox-ipam-prometheus-alerting"
---

## From a manual audit to reliable daily monitoring

A one-time `CLEAN` comparison is useful, but not sufficient. Tomorrow, RouterOS might receive a new address, NetBox data might change, or one of the APIs might become unavailable. The next operating requirement is **regular execution and explicit detection of failed checks**, not merely counting mismatches.

The [previous article](/notes/monitoring/routeros-netbox-ipam-drift-ssh-readonly/) explains read-only SSH and HTTPS collection from MikroTik RouterOS and NetBox. This article covers the local deployment of **Python audit → atomic `.prom` writer → Node Exporter → Prometheus → Alertmanager**.

Infrastructure names and addresses are anonymized. Code fragments illustrate the implementation and may require adaptation; the production-specific wrapper is not yet a generic public installer.

## 01 / Architecture

```text
systemd timer
     |
     v
read-only audit service: RouterOS SSH + NetBox HTTPS GET
     |
     +--- status: CLEAN=0 | DRIFT=1 | ERROR=2
     v
atomic textfile writer
     |
     v
/var/lib/node_exporter/textfile_collector/routeros-netbox-ipam.prom
     |
     v
Node Exporter /metrics → Prometheus → alert rules → Alertmanager
```

This deployment reused an existing Node Exporter Textfile Collector. It required neither a new TCP listener nor a continuously running Python HTTP service, and left other `.prom` files untouched.

## 02 / Check the Textfile Collector first

```bash
systemctl is-active node_exporter
PID=$(systemctl show node_exporter -p MainPID --value)
tr '\0' '\n' < "/proc/$PID/cmdline" | grep collector.textfile

curl -fsS http://127.0.0.1:9100/metrics | grep -E \
  '^(node_textfile_scrape_error|node_scrape_collector_success\{collector="textfile")'
```

Expected values include `node_scrape_collector_success{collector="textfile"} 1` and `node_textfile_scrape_error 0`. In an SELinux Enforcing environment, also verify the textfile directory and context of newly written metrics. Do not modify metrics owned by unrelated services.

## 03 / Metrics contract: ERROR must not look like CLEAN

Illustrative exposition:

```prometheus
# TYPE netbox_routeros_ipam_audit_status gauge
netbox_routeros_ipam_audit_status 0
# TYPE netbox_routeros_ipam_audit_differences gauge
netbox_routeros_ipam_audit_differences 0
# TYPE netbox_routeros_ipam_audit_timestamp_seconds gauge
netbox_routeros_ipam_audit_timestamp_seconds 1790000000
# TYPE netbox_routeros_ipam_routeros_vlans gauge
netbox_routeros_ipam_routeros_vlans 8
# TYPE netbox_routeros_ipam_netbox_vlans gauge
netbox_routeros_ipam_netbox_vlans 8
```

Numbers are fictional. Three statuses carry separate meanings:

| Value | State | Meaning |
|---|---|---|
| `0` | CLEAN | Comparison completed and checked invariants match |
| `1` | DRIFT | A concrete difference was detected |
| `2` | ERROR | Comparison result is not trustworthy |

On collection failure, the writer **publishes status `2` but omits a numeric `differences=0`**. Zero differences is not a legitimate reading when the collection failed. The timestamp records the last *attempt* to publish a check, including `ERROR`; a separate age alert catches a writer that stops entirely.

## 04 / Atomic metric file replacement

Never expose a half-written `.prom` file to Node Exporter. Write in the same directory, flush and atomically rename:

```python
import os
import tempfile
from pathlib import Path

metrics_dir = Path("/var/lib/node_exporter/textfile_collector")
target = metrics_dir / "routeros-netbox-ipam.prom"
content = "netbox_routeros_ipam_audit_status 0\n"  # illustrative

fd, tmp = tempfile.mkstemp(prefix=".ipam-", suffix=".tmp", dir=metrics_dir)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        stream.write(content)
        stream.flush()
        os.fsync(stream.fileno())
    os.chmod(tmp, 0o644)
    os.replace(tmp, target)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
```

This snippet demonstrates the file-writing operation, not the entire exporter. A real wrapper must first run the audit, check its return code, validate parsed fields and publish the full metric set. A file-write failure can leave the previous successful result present, so **a stale-data alert is required**. Avoid logging secrets, raw interface addresses or full exception traces.

## 05 / systemd hardening and daily scheduling

A `Type=oneshot` service is a natural match for a short audit:

```ini
# /etc/systemd/system/routeros-netbox-ipam.service
[Unit]
Description=Read-only RouterOS and NetBox IPAM audit
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=root
Group=root
WorkingDirectory=/opt/netbox-inventory-toolkit
ExecStart=/usr/bin/python3.11 /usr/local/libexec/netbox-inventory/ipam_metrics.py
TimeoutStartSec=180
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=/var/lib/node_exporter/textfile_collector
ProtectHome=read-only
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
LockPersonality=yes
RestrictSUIDSGID=yes
```

The executable path is an **example of a private local wrapper** and is not claimed to be an installable public component of the PR. Root was used because the dedicated SSH private key and API token are root-only. The code directory and all imported modules must be root-owned and not writable by ordinary users. A dedicated nonprivileged service account is a possible follow-up improvement.

```ini
# /etc/systemd/system/routeros-netbox-ipam.timer
[Unit]
Description=Daily IPAM drift audit

[Timer]
OnCalendar=*-*-* 06:45:00
RandomizedDelaySec=5min
AccuracySec=1min
Persistent=true
Unit=routeros-netbox-ipam.service

[Install]
WantedBy=timers.target
```

The schedule uses the system's local time zone. Do **not** add `Requires=routeros-netbox-ipam.service` to the timer's `[Unit]` section: it can trigger the service when the timer is enabled, independently of its scheduled activation.

```bash
systemd-analyze verify /etc/systemd/system/routeros-netbox-ipam.service
systemd-analyze verify /etc/systemd/system/routeros-netbox-ipam.timer
systemctl daemon-reload
systemctl start routeros-netbox-ipam.service  # manual validation
systemctl show routeros-netbox-ipam.service -p Result -p ExecMainStatus
systemctl enable --now routeros-netbox-ipam.timer
systemctl list-timers --all routeros-netbox-ipam.timer
```

After a successful oneshot run, `ActiveState=inactive` with `Result=success` and `ExecMainStatus=0` is expected. `DRIFT` and `ERROR` may lead to nonzero systemd results, but the exporter must first publish the relevant status metric.

## 06 / PromQL alert rules

Use four independent checks. The example target labels `job=node`, `instance=monitor01`, `site=example` **must be replaced with values discovered from the local Prometheus API**.

```yaml
groups:
  - name: example-routeros-netbox-ipam
    interval: 30s
    rules:
      - alert: RouterOSIPAMDrift
        expr: netbox_routeros_ipam_audit_status{job="node",instance="monitor01"} == 1
        for: 5m
        labels: {severity: warning, component: netbox-ipam, site: example}
        annotations: {summary: "RouterOS and NetBox IPAM drift detected"}
      - alert: RouterOSIPAMAuditError
        expr: netbox_routeros_ipam_audit_status{job="node",instance="monitor01"} == 2
        for: 5m
        labels: {severity: critical, component: netbox-ipam, site: example}
        annotations: {summary: "IPAM audit failed"}
      - alert: RouterOSIPAMAuditStale
        expr: time() - netbox_routeros_ipam_audit_timestamp_seconds{job="node",instance="monitor01"} > 93600
        for: 10m
        labels: {severity: warning, component: netbox-ipam, site: example}
        annotations: {summary: "IPAM audit older than 26 hours"}
      - alert: RouterOSIPAMAuditMissing
        expr: absent(netbox_routeros_ipam_audit_status{job="node",instance="monitor01"})
        for: 10m
        labels: {severity: critical, component: netbox-ipam, site: example}
        annotations: {summary: "IPAM audit metric missing"}
```

The `93600` threshold is 26 hours, allowing a small delay around the daily check. `Stale` detects an old data file; `Missing` catches a series that disappeared entirely. Both checks are necessary.

## 07 / Production-safe verification

The exporter was tested against mocked `CLEAN=0`, `DRIFT=1` and `ERROR=2` outputs in an isolated temporary directory. This validated the file format without forcing a real router or NetBox incident or modifying live metrics.

Next, a manual systemd start confirmed `Result=success`, `ExecMainStatus=0`, the `.prom` file, `node_textfile_scrape_error 0` and the expected series inside Prometheus. A deployment-specific detail: the Prometheus API may bind to the management-interface IP **rather than loopback**. Inspect `--web.listen-address` or `ss -ltnp` instead of assuming `127.0.0.1:9090`.

```bash
/usr/local/bin/promtool check rules /etc/prometheus/rules/example-ipam.yml
systemctl reload prometheus
curl -fsSG 'http://prometheus.example.net:9090/api/v1/query' \
  --data-urlencode 'query=netbox_routeros_ipam_audit_status'
```

Immediately after reloading Prometheus, newly loaded rules can briefly show `state=unknown`, `health=unknown` **before their first scheduled evaluation**. After a rule evaluation interval, a healthy system without active problems should show `state=inactive`, `health=ok`.

## 08 / Alertmanager routing is not delivery confirmation

`amtool` can verify the intended receiver without generating a test alert:

```bash
amtool config routes test \
  --config.file=/etc/alertmanager/alertmanager.yml \
  alertname=RouterOSIPAMDrift \
  severity=warning component=netbox-ipam site=example \
  job=node instance=monitor01
```

The config file path is illustrative; discover the real `--config.file` from the Alertmanager process. Both warning and critical IPAM routes were successfully mapped to the existing notification receiver.

Historically, Alertmanager notification counters showed email and webhook activity without recorded delivery errors over the examined interval. However, **`increase(metric[24h])` is extrapolated and can be fractional; prior notifications from unrelated alerts do not demonstrate end-to-end delivery of a new IPAM alert.** A real delivery test should be separately approved because it can send actual messages to operational recipients.

## Outcome and remaining work

The daily timer is enabled, the IPAM audit returns `CLEAN`, Node Exporter exposes its gauges, Prometheus evaluates four healthy inactive alert rules, and routing to the selected receiver is validated. Existing unrelated alert rules and monitored services were preserved.

Two future enhancements remain: automatic verification of the provenance of reviewed IPsec Mode Config addresses and publication of the sanitized, generic local wrapper as a reusable GitHub component. See [read-only RouterOS/NetBox IPAM comparison](/notes/monitoring/routeros-netbox-ipam-drift-ssh-readonly/) for the audit engine's scope and limitations.