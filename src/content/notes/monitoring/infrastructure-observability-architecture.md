---
title: "Infrastructure observability architecture: Prometheus, Grafana, Loki, Zabbix and Wazuh"
description: "A production-backed operating model for combining metrics, availability checks, logs and security telemetry across Linux, Windows, virtualization, storage, databases, telephony and network infrastructure."
category: "Monitoring & Security"
tags: ["prometheus", "grafana", "loki", "zabbix", "wazuh", "rsyslog", "observability"]
published: 2026-09-16
updated: 2026-09-16
status: current
testedOn: ["Prometheus", "Grafana", "Loki", "Zabbix", "Wazuh", "rsyslog"]
featured: true
translationKey: "monitoring/infrastructure-observability-architecture"
---

## Context

A production monitoring platform becomes difficult long before the first monitoring server runs out of CPU.

The real complexity comes from the number of signal types and target classes:

- Linux and Windows servers;
- Proxmox VE, backup and storage systems;
- PostgreSQL/Postgres Pro and application-specific metrics;
- 1C:Enterprise services;
- Asterisk and VoIP services;
- mail infrastructure;
- MikroTik RouterOS and SwOS devices;
- Zyxel switches and access infrastructure;
- centralized logs;
- security events.

No single collection method is ideal for every one of these systems. The practical architecture is therefore not "Prometheus instead of Zabbix" or "Grafana instead of everything else". It is a signal model in which each component has a clear job.

This note documents the architecture used as the basis for a multi-site infrastructure observability platform. Product-specific implementation details are kept in separate runbooks.

## Operating model

The platform follows a simple chain:

```text
observe -> detect -> correlate -> diagnose -> act
```

The important part is correlation. A useful incident view may require all of the following at the same time:

```text
host metrics
network state
service availability
application metrics
logs
security events
```

A CPU graph alone rarely explains an infrastructure incident.

## High-level architecture

```text
                    infrastructure and services
                               |
          +--------------------+--------------------+
          |                    |                    |
          v                    v                    v
       metrics              checks               logs
          |                    |                    |
          v                    v                    v
     Prometheus             Zabbix          Loki / rsyslog
          |                    |                    |
          +--------------------+--------------------+
                               |
                               v
                            Grafana
                               |
                               v
                     dashboards / diagnosis

security telemetry --------------------------------> Wazuh
                                                        |
                                                        v
                                             investigation context
```

The diagram is intentionally functional rather than host-specific. In production, collectors and storage components can live on separate systems and different sites can have different collection paths.

## Why keep several monitoring systems

### Prometheus: time-series metrics

Prometheus is strongest when the target exposes numerical metrics that should be evaluated over time:

```text
CPU
memory
filesystem usage
interface counters
latency
queue depth
PostgreSQL statistics
application counters
virtualization state
```

Exporters and API integrations normalize these signals into a common time-series model.

### Grafana: visualization and investigation

Grafana is the operator-facing layer for dashboards and correlation. It should not be treated as the source of truth by itself.

A dashboard is useful when it helps answer an operational question such as:

- is the problem limited to one host or site?
- did the change begin before or after an application event?
- is storage latency correlated with VM degradation?
- did network errors rise before packet loss became visible?

### Zabbix: infrastructure checks and mature host/service monitoring

Zabbix remains useful for traditional infrastructure monitoring, availability checks, network equipment and environments where an agent/SNMP/template model is already established.

Running Prometheus beside Zabbix is not inherently duplication. The two systems can cover different signal types while still describing the same infrastructure.

### Loki and rsyslog: log context

Metrics answer "what changed?" more easily than "why did it change?".

Centralized logs make it possible to correlate service failures with:

```text
systemd/service events
kernel/storage messages
network events
application errors
mail delivery events
authentication events
```

rsyslog can act as a collection/forwarding layer while Loki provides indexed log access from the observability workflow.

### Wazuh: security telemetry

Security events are kept as a separate signal class.

Wazuh adds host security events, agent telemetry and SCA results without forcing security data into ordinary performance dashboards.

During an incident, however, operational and security signals may still be correlated.

## Target classes

The platform is easier to operate when targets are grouped by what must be observed rather than only by operating system.

### Linux servers

Typical baseline:

```text
CPU / load
memory / swap
filesystem capacity
inode usage
network interfaces
systemd services
kernel/storage signals
availability
```

Prometheus/node exporter is a natural metrics source, while Zabbix can continue to handle availability and existing templates.

### Windows Server

Windows needs its own collection model rather than being treated as "Linux with different labels".

Useful areas include:

```text
CPU and memory
logical disks
network interfaces
Windows services
system uptime
selected performance counters
role-specific service state
```

The detailed Windows exporter and service-monitoring model belongs in a separate runbook.

### Proxmox VE, backup and storage

Hypervisors need both host-level and platform-level signals.

Host metrics alone do not describe:

```text
cluster state
node state
VM / CT state
storage state
backup platform health
API-level resource information
```

For Proxmox VE, an API exporter can complement node exporter metrics. API access should use a read-only account/token and normal TLS verification rather than administrator credentials or disabled certificate checks.

Storage and backup platforms such as PBS and TrueNAS should be modeled as separate service classes even when they run on Linux.

## Application-specific monitoring

A general Linux dashboard should not be expected to explain a database, PBX or mail incident.

### PostgreSQL / Postgres Pro

Database monitoring needs database-native signals such as:

```text
connections
transactions
locks
cache/activity statistics
database size
replication state where used
query/workload indicators
```

`postgres_exporter` provides a dedicated Prometheus collection path in the current environment. On the 1C stack, it is complemented by separate 1C-specific metrics rather than trying to infer application health only from PostgreSQL process state.

### 1C:Enterprise

The useful questions are different from ordinary host monitoring:

```text
is the 1C service available?
is the expected platform instance running?
is the application responding?
are application-specific counters behaving normally?
```

The current production 1C server also has a dedicated metrics service/timer, which keeps application-specific collection separate from generic OS monitoring.

### Asterisk

A PBX requires service-level and telephony-level signals.

A future Asterisk-specific runbook should separate at least:

```text
process/service health
channels/calls
trunks/registrations
endpoint state
call-path failures
system resource usage
logs
```

A running `asterisk` process is not sufficient proof that inbound and outbound call flows work.

### Mail infrastructure

Mail monitoring should combine infrastructure state with application behavior:

```text
SMTP reachability
queue/deferred growth
container/service health where applicable
disk capacity
TLS/certificate state
delivery errors
mail logs
```

Delivery incidents often require both metrics and log evidence.

## Network monitoring

Network equipment is not one homogeneous target type.

### MikroTik RouterOS

RouterOS devices can expose a richer set of operational state than simple ICMP availability:

```text
interface state and counters
errors and drops
CPU / memory
board temperature where supported
uplink state
routing/VPN-related state where required
```

The exact collection method should be chosen per device class and firmware rather than forcing one mechanism onto every RouterOS system.

### MikroTik SwOS / RB260-class devices

SwOS devices require a separate runbook because they do not provide the RouterOS management model.

For lightweight switches such as RB260-class devices, SNMP-oriented monitoring is the natural common denominator. The useful baseline is typically:

```text
port link state
traffic counters
errors
switch health values exposed by the model
```

The available metrics depend on SwOS version and hardware, so dashboards should not assume that every RouterOS metric exists on SwOS.

### Zyxel

Zyxel switches and access infrastructure should also be modeled around the metrics actually exposed by the specific model and firmware.

A practical SNMP baseline is:

```text
interface state
traffic
errors/discards
CPU / memory when exposed
temperature/PoE state when exposed
uptime and device availability
```

Model-specific OIDs should be kept in dedicated notes/templates rather than buried in the high-level architecture document.

## Identity and labels

A multi-site platform becomes difficult to use when the same system is named differently in Prometheus, Grafana, Zabbix and logs.

Keep a small stable identity model. Useful dimensions include:

```text
site
host
role
platform
service
environment
```

For example, a database host can be viewed simultaneously as:

```text
site=office
platform=linux
role=database
service=postgresql
```

The exact labels depend on the environment. The important rule is consistency across dashboards and alert context.

Avoid putting rapidly changing or unbounded values into Prometheus labels. High-cardinality labels make storage and queries unnecessarily expensive.

## Metrics and logs are different signal types

Do not attempt to replace one with the other.

Metrics are best for:

```text
rates
thresholds
trends
capacity
SLO-style measurements
alert conditions
```

Logs are best for:

```text
error details
state transitions
rare events
stack traces
protocol/application context
forensic timelines
```

A useful dashboard can link the two without pretending that they have the same retention and query model.

## Alert design

The objective is not to alert on every metric.

An alert should usually answer three questions:

```text
what failed?
where did it fail?
what should the operator check next?
```

Prefer alerts for actionable states, for example:

```text
service unavailable for a meaningful interval
filesystem approaching exhaustion
persistent packet loss or link errors
database connectivity/health failure
cluster/node degradation
backup failure
mail queue growth beyond normal behavior
```

Avoid turning short-lived noise into pages. Alert fatigue eventually makes even good alerts useless.

## Dashboard design

Dashboards should be organized by operational question, not by exporter name.

A useful hierarchy is:

```text
fleet / sites
  -> platform class
     -> service class
        -> individual host/device
```

Examples:

```text
All sites
Linux servers
Windows servers
Proxmox clusters
Storage / backup
PostgreSQL / 1C
Asterisk
Mail
Network devices
```

This is easier to use during incidents than a flat collection of exporter-specific dashboards.

## Validation

Monitoring itself needs validation.

For every new target class check at least:

```text
collector/exporter is reachable
scrape/check is successful
expected labels identify the target correctly
key metrics change when the real system changes
dashboards do not silently display stale data
an alert can be tested safely
logs arrive with correct host/site identity
```

A green target endpoint proves only that collection works. It does not prove that the chosen metrics describe application health correctly.

## Failure domains

The observability stack should not create a new single blind spot.

Consider failures such as:

```text
Prometheus unavailable
Grafana unavailable
Loki unavailable
site-to-site link down
collector/exporter down
SNMP blocked
credentials/token expired
certificate validation failure
time drift
```

Where practical, one monitoring path should help reveal failure of another. For example, an availability check can detect that a Prometheus exporter stopped responding even though the target host itself remains online.

## Public bootstrap repository versus production platform

The public repository `prometheus-monitoring-stack` is a compact bootstrap/reference implementation for Prometheus, node exporter and Grafana on a small Debian/Ubuntu monitoring node:

<https://github.com/greksw/prometheus-monitoring-stack>

It is intentionally not a copy of the complete production observability topology. The production platform spans more target classes, collection methods and operational systems than a public bootstrap installer should attempt to reproduce.

## Runbook series

This architecture note is the parent document for more specific implementation notes. The useful split is:

```text
Linux server monitoring
Windows Server monitoring
PostgreSQL / Postgres Pro monitoring
1C:Enterprise monitoring
Asterisk monitoring
Proxmox VE monitoring
PBS monitoring
TrueNAS / storage monitoring
MikroTik RouterOS monitoring
MikroTik SwOS monitoring
Zyxel monitoring
mail-service monitoring
centralized logs with Loki
```

Each child runbook should document the real collection method, target configuration, validation, alerting and known limitations for that target class.

## References

- Prometheus documentation: <https://prometheus.io/docs/>
- Grafana documentation: <https://grafana.com/docs/grafana/latest/>
- Loki documentation: <https://grafana.com/docs/loki/latest/>
- Zabbix documentation: <https://www.zabbix.com/documentation/current/en/manual>
- Wazuh documentation: <https://documentation.wazuh.com/current/>
- rsyslog documentation: <https://www.rsyslog.com/doc/>
