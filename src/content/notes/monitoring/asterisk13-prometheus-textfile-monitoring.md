---
title: "Asterisk 13 monitoring with node_exporter textfile metrics, Prometheus and Grafana"
description: "A production-backed legacy Asterisk 13 monitoring pattern using a systemd timer, a custom CLI collector, node_exporter textfile metrics, Prometheus and Grafana."
category: "Monitoring & Security"
tags: ["asterisk", "voip", "prometheus", "node-exporter", "grafana", "systemd", "chan-sip"]
published: 2026-09-16
updated: 2026-09-16
status: legacy
testedOn: ["AlmaLinux 8.10", "Asterisk 13.38.3", "chan_sip", "node_exporter textfile collector", "Prometheus", "Grafana"]
featured: true
translationKey: "monitoring/asterisk13-prometheus-textfile-monitoring"
---

## Context

A PBX needs more than generic Linux monitoring.

CPU, memory and disk metrics can show host pressure, but they do not answer application-level questions such as:

```text
Is the Asterisk service active?
Does the Asterisk CLI respond?
Is the SIP listener present?
How many calls/channels are active?
How many chan_sip peers are online or offline?
Are the expected SIP trunks reachable?
Did the collector itself fail or stop running?
```

The production deployment described here answers those questions with a short-running collector that queries the local Asterisk CLI every 30 seconds and writes Prometheus textfile metrics for `node_exporter`.

The collection path is:

```text
Asterisk 13.38.3 / chan_sip
        |
        v
fm-asterisk-metrics.timer
        |
        v
fm-asterisk-metrics.service
        |
        v
/usr/local/sbin/fm-asterisk-metrics.sh
        |
        +--> fm_asterisk.prom
        +--> fm_asterisk_collector.prom
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

This note is marked **legacy** because the running deployment is Asterisk 13.38.3. Asterisk 13 reached upstream end-of-life in 2021, even though this monitoring implementation is still the current production model for that server.

A future Asterisk 22 deployment should receive a separate PJSIP-aware monitoring implementation rather than trying to preserve `chan_sip` parsing unchanged.

## Verified production baseline

```text
OS: AlmaLinux 8.10
Asterisk: 13.38.3
SIP stack observed by collector: chan_sip
Asterisk service: asterisk.service
collector: /usr/local/sbin/fm-asterisk-metrics.sh
collector service: fm-asterisk-metrics.service
collector timer: fm-asterisk-metrics.timer
collection interval: 30 seconds
node_exporter listener: one internal management address, TCP/9100
textfile directory: /var/lib/node_exporter/textfile_collector
```

Current output files:

```text
fm_asterisk.prom
fm_asterisk_collector.prom
```

Keeping data metrics and collector-state metrics in separate files is an important part of the design.

## Timer and oneshot service

The timer uses:

```ini
[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
AccuracySec=1s
Unit=fm-asterisk-metrics.service
```

The service is a oneshot unit:

```ini
[Service]
Type=oneshot
User=root
Group=root
ExecStart=/usr/local/sbin/fm-asterisk-metrics.sh
TimeoutStartSec=25s
Nice=10
```

Therefore `inactive (dead)` between successful runs is normal for the service. Health is determined by timer state, recent exit status and metric freshness.

The 25-second service timeout also prevents a broken collector from overlapping indefinitely with the next 30-second timer interval.

## systemd hardening

The current service adds:

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
ReadWritePaths=/var/lib/node_exporter/textfile_collector
```

The collector currently runs as root because it performs local process/socket inspection and Asterisk CLI operations. Filesystem writes are still constrained to the node_exporter textfile directory.

A dedicated collector account could be considered later, but only after verifying access to the Asterisk CLI/socket information without adding broader privileges elsewhere.

## Host guard

The script contains an explicit hostname guard before collecting data.

Conceptually:

```bash
EXPECTED_HOST="pbx01"
HOST="$(hostname -s)"
[[ "$HOST" == "$EXPECTED_HOST" ]] || fail "wrong host"
```

This prevents an environment-specific collector from being copied to another system and silently publishing plausible but incorrect metrics.

The actual production hostname is omitted from the public runbook.

The trade-off is that cloning the collector to another PBX requires an intentional configuration change.

## Bounded Asterisk CLI calls

Application metrics are collected with Asterisk CLI commands wrapped in `/usr/bin/timeout`.

The current queries are equivalent to:

```bash
timeout 10 asterisk -rx 'core show uptime'
timeout 10 asterisk -rx 'core show channels count'
timeout 10 asterisk -rx 'sip show peers'
```

This is a useful failure boundary. A stuck CLI command cannot block the timer-driven collector forever.

The collector marks the run failed if an expected CLI command does not complete or its output cannot be parsed.

## Service and process health

The collector exports:

```text
fm_asterisk_service_up
fm_asterisk_processes
fm_asterisk_cli_up
```

These metrics cover different failure modes.

For example:

- `systemd` can report the service active while the CLI is unhealthy;
- a process can exist while the expected service unit is not healthy;
- CLI availability proves more than checking only a PID.

A useful dashboard should keep all three visible rather than collapsing them into one synthetic state.

## SIP listener check

The production collector verifies the expected UDP/5060 socket and confirms that it belongs to the Asterisk process.

Publicly, the logic is best represented as:

```bash
ss -H -lunp |
  grep -F '<pbx-management-ip>:5060' |
  grep -F 'asterisk'
```

and publishes:

```text
fm_asterisk_sip_listener_up{transport="udp",port="5060"} 1
```

The internal production IP is deliberately omitted.

This is stronger than a generic `ss | grep 5060` check because it validates both the expected bind and process ownership.

## Uptime and reload age

The collector parses `core show uptime` and exports:

```text
fm_asterisk_uptime_seconds
fm_asterisk_reload_age_seconds
```

The shell helper converts textual durations containing weeks, days, hours, minutes and seconds into integer seconds.

`fm_asterisk_reload_age_seconds` is useful when investigating whether symptoms started after a configuration reload.

This parser depends on the CLI output format used by Asterisk 13. It should be regression-tested during any platform upgrade rather than assumed to remain compatible.

## Channels and calls

`core show channels count` is parsed into:

```text
fm_asterisk_active_channels
fm_asterisk_active_calls
fm_asterisk_calls_processed_total
```

`fm_asterisk_calls_processed_total` is exposed as a Prometheus counter because it represents calls processed since Asterisk startup.

For rates, use Prometheus functions such as:

```promql
rate(fm_asterisk_calls_processed_total[5m])
```

or:

```promql
increase(fm_asterisk_calls_processed_total[1h])
```

Do not alert on the raw cumulative value. It naturally resets after an Asterisk restart, and Prometheus counter functions are designed to account for such resets.

## chan_sip peer state

The production Asterisk 13 collector runs:

```text
sip show peers
```

and parses its summary into:

```text
fm_asterisk_sip_peers_total
fm_asterisk_sip_monitored_online
fm_asterisk_sip_monitored_offline
fm_asterisk_sip_unmonitored_online
fm_asterisk_sip_unmonitored_offline
```

A real production snapshot contained dozens of monitored peers, including a non-zero offline count.

That is important operationally: **offline peer count must not automatically be treated as a failure**. Desk phones, remote endpoints or intentionally powered-off devices may legitimately be offline.

Alerting should use the expected endpoint population or a more targeted set of critical peers rather than `offline > 0` as a universal condition.

The parser is specific to the `chan_sip` summary format and is not suitable for a PJSIP-based Asterisk 22 deployment.

## SIP trunk monitoring

The current collector filters a defined prefix of provider SIP peers from `sip show peers` and publishes both aggregate and per-trunk state.

Current metric families include:

```text
fm_asterisk_multifon_peers
fm_asterisk_multifon_ok
fm_asterisk_multifon_problem
fm_asterisk_trunk_up{trunk="<sanitized-trunk-name>"}
```

Individual production trunk names should be sanitized before publication.

The collector considers a peer healthy when its `sip show peers` row contains an `OK (...)` status.

That should be interpreted correctly: it is a **peer reachability/qualify-style signal**, not proof that a real inbound or outbound call can be completed.

A trunk can answer SIP OPTIONS and still fail a business call path because of authentication, routing, dialplan, provider or RTP problems.

Synthetic call testing belongs in a higher-level monitoring layer.

## Collector/data split

The strongest part of this implementation is the separation between:

```text
fm_asterisk.prom
fm_asterisk_collector.prom
```

The main data file contains the latest valid Asterisk application snapshot.

The state file contains:

```text
fm_asterisk_collector_success
fm_asterisk_collector_timestamp_seconds
```

On any failure, the collector calls its failure handler and writes:

```text
fm_asterisk_collector_success 0
```

with a fresh collector timestamp.

The old application data file is left untouched.

This makes three states distinguishable:

```text
collector stopped running
collector is running but failing
collector is healthy and application data is fresh
```

## Data freshness

The successful application snapshot also contains:

```text
fm_asterisk_data_timestamp_seconds
```

This gives the monitoring system a second clock.

The difference between the timestamps is operationally valuable:

- `collector_timestamp` tells when the script last ran, including failed runs;
- `data_timestamp` tells when valid Asterisk application data was last published.

Recommended checks:

```promql
time() - fm_asterisk_collector_timestamp_seconds > 120
```

means the collector/timer itself is stale.

```promql
fm_asterisk_collector_success == 0
```

means the most recent collector execution failed.

```promql
time() - fm_asterisk_data_timestamp_seconds > 120
```

means valid Asterisk application data has stopped updating.

This is more robust than a single `success` gauge.

## Atomic file publication

Both output files are created with `mktemp` inside the target directory and then published with `mv -f`.

Conceptually:

```bash
TMP="$(mktemp /var/lib/node_exporter/textfile_collector/.fm_asterisk.XXXXXX)"
# write complete content
mv -f "$TMP" /var/lib/node_exporter/textfile_collector/fm_asterisk.prom
```

The temporary names do not end in `.prom`, so node_exporter does not parse them as metric files while they are being written.

This matches the atomic-write pattern recommended for the node_exporter textfile collector.

## node_exporter integration

The production node_exporter runs under a dedicated user and explicitly enables the textfile directory:

```bash
/usr/local/bin/node_exporter \
  --web.listen-address=<pbx-management-ip>:9100 \
  --collector.textfile.directory=/var/lib/node_exporter/textfile_collector
```

Unlike the 1C host described in another runbook, this deployment binds node_exporter to a single internal management address rather than `0.0.0.0`.

Firewall/routing policy should still allow TCP/9100 only from the monitoring path.

## Validate the collection path

Check the timer:

```bash
systemctl status fm-asterisk-metrics.timer --no-pager
systemctl list-timers fm-asterisk-metrics.timer --all
```

Run one collection manually:

```bash
systemctl start fm-asterisk-metrics.service
systemctl status fm-asterisk-metrics.service --no-pager
```

For a successful oneshot run, the service should finish with exit status 0 and then return to `inactive (dead)`.

Inspect the files:

```bash
cat /var/lib/node_exporter/textfile_collector/fm_asterisk_collector.prom
cat /var/lib/node_exporter/textfile_collector/fm_asterisk.prom
```

Validate exposition syntax when `promtool` is available:

```bash
cat /var/lib/node_exporter/textfile_collector/fm_asterisk.prom |
  promtool check metrics
```

Finally confirm node_exporter exposure:

```bash
curl -fsS http://<pbx-management-ip>:9100/metrics |
  grep '^fm_asterisk_'
```

## Useful alerting rules

The exact durations and endpoint expectations depend on the PBX role, but the following conditions are structurally useful.

### Collector stopped

```promql
time() - fm_asterisk_collector_timestamp_seconds > 120
```

### Latest collection failed

```promql
fm_asterisk_collector_success == 0
```

### Application data stale

```promql
time() - fm_asterisk_data_timestamp_seconds > 120
```

### Asterisk service or CLI unavailable

```promql
fm_asterisk_service_up == 0
```

```promql
fm_asterisk_cli_up == 0
```

### SIP listener missing

```promql
fm_asterisk_sip_listener_up{transport="udp",port="5060"} == 0
```

### Expected provider trunk unavailable

```promql
fm_asterisk_trunk_up{trunk="<critical-trunk>"} == 0
```

Do not use a generic rule such as:

```promql
fm_asterisk_sip_monitored_offline > 0
```

unless every monitored endpoint is contractually expected to remain online at all times.

## Grafana dashboard structure

A practical dashboard can be layered as follows:

```text
PBX overview
  -> service / process / CLI state
  -> collector status and data freshness
  -> uptime / last reload age
  -> active calls / channels
  -> call processing rate

SIP
  -> listener state
  -> peer totals and online/offline split
  -> provider trunk aggregate state
  -> critical per-trunk state

Host
  -> CPU / RAM / filesystem / network
  -> node_exporter availability
```

This keeps application signals close to the Linux resources underneath them without mixing them into one metric family.

## What this monitoring does not prove

The collector gives useful PBX state, but it does not prove end-to-end telephony service.

It does not prove that:

```text
an inbound DID reaches the intended extension
an outbound call completes through the provider
RTP audio works in both directions
the dialplan routes every call correctly
DTMF works
an IVR/application flow completes successfully
```

Those require synthetic calls, provider-side monitoring, RTP/media checks or application-specific tests.

## Migration boundary: Asterisk 13 to Asterisk 22

This collector must not simply be copied unchanged to Asterisk 22.

The current parser depends on:

```text
chan_sip
sip show peers
Asterisk 13 CLI output formatting
provider peer rows containing OK (...)
```

Asterisk 22 is an LTS release, while Asterisk 13 is upstream EOL. The Asterisk 22 monitoring implementation should be designed around the PJSIP objects actually used after migration.

During migration, preserve the monitoring intent rather than the exact command syntax:

```text
service health
CLI health
SIP/PJSIP transport state
endpoint/AOR/contact state
trunk state
active channels/calls
call throughput
collector freshness
```

The new implementation should be validated against actual Asterisk 22 CLI output before replacing the legacy metrics source.

## Rollback and maintenance

Before modifying this collector preserve:

```text
/etc/systemd/system/fm-asterisk-metrics.service
/etc/systemd/system/fm-asterisk-metrics.timer
/usr/local/sbin/fm-asterisk-metrics.sh
node_exporter unit / drop-ins
Prometheus rules
Grafana dashboards/provisioning
```

A collector change should not require changing the Asterisk configuration itself.

After any Asterisk update or reload-related CLI behavior change, validate:

```text
core show uptime parser
core show channels count parser
sip show peers summary parser
provider-trunk row parser
metric exposition syntax
collector/data timestamps
```

## Validation checklist

```text
[ ] fm-asterisk-metrics.timer active
[ ] latest oneshot run exited 0
[ ] collector success = 1
[ ] collector timestamp is fresh
[ ] data timestamp is fresh
[ ] Asterisk service / process / CLI metrics match reality
[ ] SIP listener state matches the actual socket
[ ] channel/call counters change during real calls
[ ] peer summary matches Asterisk CLI output
[ ] critical trunk states match the intended monitored peers
[ ] node_exporter exposes fm_asterisk_* only on the monitoring path
[ ] alert rules distinguish collector failure from PBX failure
```

## References

- Asterisk release lifecycle: <https://docs.asterisk.org/About-the-Project/Asterisk-Versions/>
- Asterisk CLI syntax and `sip show peers`: <https://docs.asterisk.org/Operation/Asterisk-Command-Line-Interface/CLI-Syntax-and-Help-Commands/>
- node_exporter textfile collector: <https://github.com/prometheus/node_exporter#textfile-collector>
- Prometheus text exposition format: <https://prometheus.io/docs/instrumenting/exposition_formats/>
- Prometheus documentation: <https://prometheus.io/docs/>
- Grafana documentation: <https://grafana.com/docs/grafana/latest/>
