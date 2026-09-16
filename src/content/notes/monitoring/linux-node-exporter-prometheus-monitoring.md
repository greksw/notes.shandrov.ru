---
title: "Linux host monitoring with node_exporter, Prometheus file_sd and alert rules"
description: "A production-backed Linux monitoring pattern using node_exporter 1.12.1, Prometheus file-based service discovery, recording rules and layered host alerts."
category: "Monitoring & Security"
tags: ["linux", "prometheus", "node-exporter", "file-sd", "alerting", "monitoring"]
published: 2026-09-16
updated: 2026-09-16
status: current
testedOn: ["AlmaLinux 9.8", "node_exporter 1.12.1", "Prometheus file_sd", "Prometheus recording and alerting rules"]
featured: true
translationKey: "monitoring/linux-node-exporter-prometheus-monitoring"
---

## Context

Linux host monitoring becomes useful when it is treated as an infrastructure contract rather than a collection of default dashboards.

The production model described here has four distinct layers:

```text
Linux hosts
    |
    v
node_exporter
    |
    v
Prometheus file_sd target inventory
    |
    v
recording rules
    |
    v
alert rules / dashboards
```

The current environment monitors a mixed Linux fleet that includes mail, monitoring, observability, security, 1C and telephony roles. Some hosts also expose service-specific textfile metrics, but the Linux layer remains independent from those application checks.

This note focuses on the host-level contract.

## Verified production baseline

A representative production host was verified with:

```text
OS: AlmaLinux 9.8
node_exporter: 1.12.1
architecture: linux/amd64
service account: node_exporter
listener: one internal management address on TCP/9100
textfile collector: enabled
service state: enabled + active
```

The central Prometheus runtime was also verified with:

```text
node job scrape interval: 30s
node job scrape timeout: 10s
target discovery: file_sd
file_sd refresh interval: 30s
Prometheus config validation: successful
rule files loaded: 12
Linux rule file: fm-linux.yml
Linux rules: 22
```

The live target used for validation reported:

```text
job: node
health: up
scrape interval: 30s
scrape timeout: 10s
```

## node_exporter systemd unit

The production pattern runs node_exporter under a dedicated account and binds it to a management address rather than all interfaces:

```ini
[Service]
Type=simple
User=node_exporter
Group=node_exporter

ExecStart=/usr/local/bin/node_exporter \
  --web.listen-address=<node-management-ip>:9100 \
  --collector.textfile.directory=/var/lib/node_exporter/textfile_collector

Restart=on-failure
RestartSec=5s
```

The unit is hardened with directives such as:

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

Binding to an internal address reduces exposure, but routing and firewall policy still need to restrict TCP/9100 to the monitoring path.

## Version validation

Verify the binary directly rather than inferring its version from a package name:

```bash
/usr/local/bin/node_exporter --version
```

The verified production binary reports:

```text
node_exporter 1.12.1
```

The matching build metric is also exposed through `/metrics`:

```text
node_exporter_build_info{version="1.12.1",...} 1
```

This is useful for detecting inconsistent rollout across the fleet.

## Default collectors

The representative host exposes the normal Linux collector set including:

```text
cpu
filesystem
loadavg
meminfo
netclass
netdev
netstat
pressure
sockstat
stat
textfile
time
timex
uname
vmstat
xfs
```

and other hardware/filesystem collectors enabled by node_exporter defaults.

There is no production requirement to disable every collector that has no matching hardware on a specific host. Keeping the standard collector set reduces configuration drift between systems.

Collector success can be inspected with:

```promql
node_scrape_collector_success
```

## File-based target discovery

Prometheus does not hard-code Linux nodes directly in the main configuration.

The `node` job uses file-based service discovery:

```yaml
- job_name: node
  scrape_interval: 30s
  scrape_timeout: 10s

  file_sd_configs:
    - files:
        - /etc/prometheus/targets/node/*.yml
      refresh_interval: 30s
```

Target files group systems by operational role while preserving common labels.

A sanitized target entry looks like:

```yaml
- targets:
    - "<node-ip>:9100"
  labels:
    instance: "<node-name>"
    site: "fm"
    role: "mail"
    os: "linux"
```

The key contract labels are:

```text
instance
site
role
os
```

Recording and alert rules rely on those labels, so a target added without them is not equivalent to a correctly onboarded host.

## Why file_sd is useful here

For a small or medium static fleet, `file_sd` gives several advantages over a large `static_configs` block:

- target inventory can be split by role;
- the main Prometheus configuration stays small;
- target changes do not require editing the scrape-job definition;
- labels are explicit and reviewable;
- inventory drift can be checked independently.

The current Linux monitoring contract expects exactly **9** FM Linux targets.

That count is intentionally monitored. Adding or removing a Linux target therefore requires updating both discovery inventory and the target-count contract.

## Runtime target validation

Do not rely only on configuration files. Confirm what Prometheus actually loaded:

```bash
curl -fsS "http://<prometheus-ip>:9090/api/v1/targets?state=active" |
  jq '.data.activeTargets[] | select(.labels.job == "node")'
```

For a healthy target, confirm:

```text
job=node
health=up
lastError=""
scrapeInterval=30s
scrapeTimeout=10s
```

This catches discovery, relabeling and connectivity problems that a YAML syntax check cannot detect.

## Recording-rule layer

The production `fm-linux.yml` creates normalized recording rules before alerts are evaluated.

The current recording metrics are:

```text
fm:linux:up
fm:linux:cpu_usage_percent
fm:linux:memory_usage_percent
fm:linux:swap_usage_percent
fm:linux:filesystem_usage_percent
fm:linux:inode_usage_percent
fm:linux:uptime_seconds
fm:linux:load1_per_cpu
```

This keeps dashboard and alert expressions smaller and makes fleet-level behavior consistent.

## Availability

The base availability rule is:

```promql
up{job="node",site="fm",os="linux"}
```

recorded as:

```text
fm:linux:up
```

Most Linux nodes use a common exporter-down alert with a two-minute delay.

Some infrastructure hosts are intentionally excluded because dedicated availability alerts already exist in other rule files. This avoids duplicate notifications for the same underlying failure.

## Target-count contract

The current rule checks that the production inventory contains exactly nine matching targets:

```promql
(
  count(up{job="node",site="fm",os="linux"})
  or vector(0)
) != 9
```

and holds for two minutes before firing.

This is not a capacity metric. It is an inventory-drift detector.

The rule is deliberately strict, so a planned host addition must update the expected count as part of the same change.

## CPU usage

CPU usage is derived from idle CPU time over five minutes:

```promql
100 * (
  1 - avg without (cpu, mode) (
    rate(node_cpu_seconds_total{
      job="node",
      site="fm",
      os="linux",
      mode="idle"
    }[5m])
  )
)
```

The production thresholds are layered:

```text
warning:  > 90% and < 97% for 15m
critical: >= 97% for 5m
```

This avoids alerting on short CPU bursts while still escalating sustained saturation quickly.

A security-monitoring host is excluded because it has dedicated CPU policy elsewhere.

## Memory usage

Memory usage is calculated from `MemAvailable`, not merely `MemFree`:

```promql
100 * (
  1 -
  node_memory_MemAvailable_bytes
  /
  node_memory_MemTotal_bytes
)
```

Production thresholds:

```text
warning:  > 85% and <= 92% for 15m
critical: > 92% for 5m
```

Using `MemAvailable` is important on Linux because filesystem cache is reclaimable and should not automatically be interpreted as application memory pressure.

## Swap usage

Swap percentage is recorded only on systems where total swap is greater than zero.

Conceptually:

```promql
100 * (1 - node_memory_SwapFree_bytes / node_memory_SwapTotal_bytes)
```

combined with a guard:

```promql
node_memory_SwapTotal_bytes > 0
```

This avoids invalid division and avoids manufacturing a swap-usage series on hosts with no configured swap.

The current Linux rule file records swap usage but does not define a generic fleet-wide swap alert. That distinction is intentional and should not be hidden by a generic tutorial.

## Filesystem usage

Filesystem utilization is based on available bytes:

```promql
100 * (
  1 - node_filesystem_avail_bytes / node_filesystem_size_bytes
)
```

Pseudo and transient filesystem types are excluded:

```text
tmpfs
devtmpfs
overlay
squashfs
nsfs
tracefs
debugfs
securityfs
proc
sysfs
cgroup / cgroup2
```

Production thresholds are:

```text
warning:  > 85% and < 93% for 15m
critical: >= 93% for 5m
```

One observability datastore mount is excluded because it has a dedicated storage alert in its own rule set. Again, the goal is to avoid duplicate alerts rather than force every mount into one global policy.

## Read-only filesystems

A separate critical rule checks:

```promql
node_filesystem_readonly == 1
```

for real filesystem types and holds for one minute.

This catches a different failure class from low free space. A filesystem can remount read-only because of storage or filesystem errors while still having plenty of free capacity.

## Inode utilization

Inode percentage is normalized as:

```promql
100 * (
  1 - node_filesystem_files_free / node_filesystem_files
)
```

with the same pseudo-filesystem exclusions used for byte capacity.

Production thresholds are:

```text
warning:  > 90% and < 97% for 15m
critical: >= 97% for 5m
```

Tracking inodes separately is important for mail, logging and other workloads that can create many small files.

## OOM killer activity

The fleet has a critical alert on OOM activity:

```promql
increase(
  node_vmstat_oom_kill{
    job="node",
    site="fm",
    os="linux"
  }[10m]
) > 0
```

This is stronger evidence of memory exhaustion than a single high-memory snapshot because it detects an actual kernel OOM kill event.

## Time synchronization

Kernel synchronization state is checked with:

```promql
node_timex_sync_status == 0
```

for five minutes.

This matters for log correlation, TLS, authentication, distributed systems and incident timelines. The metric represents kernel time synchronization state; it is not a replacement for separately diagnosing the active NTP/chrony service when an alert fires.

## Textfile collector integrity

Several application runbooks use node_exporter's textfile collector for local service metrics.

The Linux layer therefore includes:

```promql
node_textfile_scrape_error > 0
```

for five minutes.

This catches malformed `.prom` files independently of the application-specific metrics they contain.

Dedicated observability/security hosts are excluded where equivalent textfile checks already exist elsewhere.

## Docker hosts

The validated mail host runs its application stack in Docker.

That does not prevent node_exporter from being used for host monitoring. The exporter still reports the host kernel, CPU, memory, filesystem and network namespaces visible to the host process.

On the validated host, filesystem metric types were only:

```text
xfs
tmpfs
```

so Docker did not create problematic `overlay` filesystem series in the observed `node_filesystem_*` output.

Network metrics were noisier and included:

```text
physical/VM NIC
docker0
application bridge
veth* interfaces
loopback
```

For host-level Grafana panels, a practical network filter is:

```promql
node_network_receive_bytes_total{
  device!~"lo|docker0|br-.*|veth.*"
}
```

and the equivalent filter for transmit, errors and drops.

Do not disable these devices at exporter level merely to make a dashboard cleaner. Container interfaces can still be useful during incident analysis.

The current `fm-linux.yml` does **not** define generic network saturation/error alerts, so this note does not invent production network thresholds that do not exist.

## Load normalized per CPU

The rule set records one-minute load divided by CPU count:

```promql
node_load1
/
count by (instance, site, role, os) (
  node_cpu_seconds_total{mode="idle"}
)
```

as:

```text
fm:linux:load1_per_cpu
```

Normalizing by CPU count makes the metric comparable between differently sized systems.

It is currently a recording metric, not a generic fleet-wide alert condition.

## Uptime

Host uptime is recorded from boot time:

```promql
time() - node_boot_time_seconds
```

This is useful for dashboard context and post-maintenance validation.

A low uptime is not inherently a failure, so the production rule file does not treat reboot itself as a generic alert.

## Prometheus-side validation

The central configuration is checked with:

```bash
/usr/local/bin/promtool check config /etc/prometheus/prometheus.yml
```

The verified run successfully validated the main configuration and all 12 rule files, including the 22-rule Linux file.

Syntax validation is necessary but not sufficient. After changes also inspect the runtime target state and evaluate key recording rules.

Useful checks:

```promql
count(up{job="node",site="fm",os="linux"})
```

```promql
fm:linux:cpu_usage_percent
```

```promql
fm:linux:memory_usage_percent
```

```promql
fm:linux:filesystem_usage_percent
```

```promql
node_textfile_scrape_error{job="node",site="fm",os="linux"}
```

## Alert-policy summary

The production Linux layer currently covers:

```text
inventory count drift       critical after 2m
node_exporter unavailable   critical after 2m
CPU high                    warning after 15m
CPU critical                critical after 5m
memory high                 warning after 15m
memory critical             critical after 5m
filesystem high             warning after 15m
filesystem critical         critical after 5m
filesystem read-only        critical after 1m
inode high                  warning after 15m
inode critical              critical after 5m
textfile parse error        warning after 5m
OOM kill detected           critical
kernel time unsynchronized  warning after 5m
```

The exact thresholds are part of this environment's operational policy, not universal defaults for every Linux fleet.

## Avoid duplicate alerts

One notable design property is that several specialized hosts are excluded from selected generic rules when a more specific alert already exists elsewhere.

Examples include dedicated rules for:

```text
security monitoring CPU/memory/filesystems
observability datastore capacity
selected exporter availability
selected textfile collector integrity
```

This keeps the monitoring hierarchy understandable:

```text
generic Linux layer
        +
role-specific layer
        +
application-specific layer
```

A role-specific alert should replace a duplicate generic condition, not simply add another notification for the same event.

## What this layer does not cover

Host monitoring does not prove that an application is working.

A Linux node can have normal CPU, memory and filesystem metrics while:

```text
mail delivery is failing
Asterisk trunks are unavailable
PostgreSQL transactions are blocked
1C application services are unhealthy
Loki ingestion is broken
```

Those conditions belong to the corresponding application or observability runbooks.

The purpose of the Linux layer is to provide the common machine-level foundation beneath them.

## Change procedure

When onboarding another Linux host:

1. install and validate the approved node_exporter build;
2. bind TCP/9100 to the intended management address;
3. apply the hardened systemd unit;
4. add a `file_sd` target with `instance`, `site`, `role` and `os` labels;
5. update the target-count contract if the inventory changes;
6. run `promtool check config`;
7. reload Prometheus;
8. confirm the runtime target is `UP`;
9. verify recording rules exist for the new instance;
10. check for duplicate role-specific alerts before enabling generic notifications.

## Rollback

If a target change is incorrect:

- restore the previous target file;
- restore the previous expected target count if it was changed;
- validate with `promtool`;
- reload Prometheus;
- confirm runtime targets and recording rules return to the previous state.

If node_exporter itself is being changed, preserve the previous binary and systemd unit so the exporter can be rolled back independently of Prometheus configuration.

## Validation checklist

```text
[ ] node_exporter version is known
[ ] node_exporter runs as the dedicated service account
[ ] TCP/9100 is bound to the intended management address
[ ] firewall/routing restricts the scrape path
[ ] file_sd target has instance/site/role/os labels
[ ] Prometheus runtime target is UP
[ ] scrape interval is 30s and timeout is 10s
[ ] expected Linux target count is correct
[ ] CPU/memory/filesystem/inode recording rules return data
[ ] textfile scrape error is zero where textfile collector is used
[ ] OOM and time-sync metrics exist on supported hosts
[ ] Docker veth/bridge devices are filtered at dashboard/query level when needed
[ ] generic alerts do not duplicate role-specific alerts
[ ] promtool validation succeeds before reload
```

## References

- node_exporter: <https://github.com/prometheus/node_exporter>
- node_exporter textfile collector: <https://github.com/prometheus/node_exporter#textfile-collector>
- Prometheus file-based service discovery: <https://prometheus.io/docs/prometheus/latest/configuration/configuration/#file_sd_config>
- Prometheus recording rules: <https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/>
- Prometheus alerting rules: <https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/>
- promtool: <https://prometheus.io/docs/prometheus/latest/command-line/promtool/>
