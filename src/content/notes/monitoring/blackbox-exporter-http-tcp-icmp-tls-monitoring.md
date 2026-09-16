---
title: "Blackbox monitoring with HTTP, TCP, ICMP and TLS probes"
description: "A production-backed Blackbox Exporter pattern for endpoint readiness, TCP reachability, ICMP canaries, TLS verification and certificate-expiry alerting."
category: "Monitoring & Security"
tags: ["prometheus", "blackbox-exporter", "http", "tcp", "icmp", "tls", "monitoring"]
published: 2026-09-16
updated: 2026-09-16
status: current
testedOn: ["blackbox_exporter 0.28.0", "Prometheus", "HTTP", "TCP", "ICMP", "TLS 1.2+"]
featured: true
translationKey: "monitoring/blackbox-exporter-http-tcp-icmp-tls-monitoring"
---

## Context

Host metrics show whether a server is alive and under resource pressure. They do not prove that a network endpoint can actually be reached or that a TLS handshake still validates.

The production monitoring path described here adds active probes from the Prometheus monitoring host:

```text
Prometheus
    |
    +--> HTTP probe --> readiness / health endpoint
    |
    +--> TCP probe  --> service port reachability
    |
    +--> ICMP probe --> network canary
    |
    +--> TLS probe  --> verified handshake + certificate lifetime
                 
blackbox_exporter 0.28.0
```

The design is intentionally small. Blackbox Exporter runs on the Prometheus host, listens only on loopback and receives target/module parameters through Prometheus relabeling.

## Verified production baseline

The active exporter is:

```text
blackbox_exporter 0.28.0
platform: linux/amd64
service account: blackbox_exporter
listener: 127.0.0.1:9115
configuration: /etc/blackbox_exporter/blackbox.yml
```

The service is hardened with systemd and keeps only the capability needed for ICMP:

```ini
CapabilityBoundingSet=CAP_NET_RAW
AmbientCapabilities=CAP_NET_RAW
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ProtectControlGroups=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectKernelLogs=true
LockPersonality=true
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
```

Keeping the exporter on `127.0.0.1:9115` means its probe API is not exposed as a general network service.

## Probe modules

Four production modules are configured.

### HTTP readiness

```yaml
http_2xx_ipv4:
  prober: http
  timeout: 10s
  http:
    method: GET
    preferred_ip_protocol: ip4
    follow_redirects: true
```

This is used for service readiness/health endpoints.

### TCP connect

```yaml
tcp_connect_ipv4:
  prober: tcp
  timeout: 5s
  tcp:
    preferred_ip_protocol: ip4
```

This answers a narrow question: can the monitoring host complete a TCP connection to the configured endpoint?

A successful TCP probe does not prove that the application protocol itself is healthy.

### ICMP

```yaml
icmp_ipv4:
  prober: icmp
  timeout: 5s
  icmp:
    preferred_ip_protocol: ip4
```

The exporter needs `CAP_NET_RAW` for this probe without running the whole service as root.

### SMTP TLS

```yaml
smtp_tls_ipv4:
  prober: tcp
  timeout: 10s
  tcp:
    preferred_ip_protocol: ip4
    tls: true
    tls_config:
      server_name: <smtp-hostname>
      min_version: TLS12
      insecure_skip_verify: false
```

This module performs a verified TLS handshake and enforces both hostname verification and a TLS 1.2 minimum.

The production module is deliberately tied to one SMTP hostname through `server_name`. It should not be reused for unrelated TLS endpoints without changing that value or defining another module.

## Prometheus jobs

Blackbox Exporter itself is monitored as a normal local target.

The actual probe jobs use `/probe`, pass the original discovery target through `__param_target`, and rewrite `__address__` to the loopback exporter.

### HTTP

```yaml
- job_name: blackbox_http
  scrape_interval: 15s
  scrape_timeout: 12s
  metrics_path: /probe
  params:
    module: [http_2xx_ipv4]
```

### TCP

```yaml
- job_name: blackbox_tcp
  scrape_interval: 15s
  scrape_timeout: 12s
  metrics_path: /probe
  params:
    module: [tcp_connect_ipv4]
```

### ICMP

```yaml
- job_name: blackbox_icmp
  scrape_interval: 15s
  scrape_timeout: 12s
  metrics_path: /probe
  params:
    module: [icmp_ipv4]
```

### TLS

The TLS job chooses its module from a discovery label:

```yaml
- source_labels: [blackbox_module]
  target_label: __param_module
```

This is useful when different TLS endpoints need different protocol-specific modules.

## File-based target inventory

Targets are stored outside the main Prometheus configuration under:

```text
/etc/prometheus/targets/blackbox/
```

The verified inventory includes:

```text
HTTP
  - Prometheus readiness endpoint
  - local notification bridge health endpoint

TCP
  - security-event listener
  - SMTP submission/transport endpoint
  - XMPP client-to-server endpoint

ICMP
  - monitoring-host canary

TLS
  - SMTP TLS endpoint
```

Targets carry labels such as:

```text
site
target_name
service
probe_type
criticality
```

Those labels are then reused by alert rules.

## Runtime verification

At the time of validation every configured production probe returned:

```text
probe_success = 1
```

across all four jobs:

```text
blackbox_http
blackbox_tcp
blackbox_icmp
blackbox_tls
```

This matters because YAML validation alone cannot prove that DNS, routing, firewall policy, the remote listener or TLS verification work from the monitoring host.

## Notification-pipeline monitoring

One practical use of the blackbox layer is monitoring the notification path itself.

The current rules independently check:

```text
local XMPP bridge health
SMTP TCP reachability
XMPP TCP reachability
SMTP verified TLS handshake
```

Alertmanager's own failure counters are monitored separately, so transport reachability and actual notification-send failures are not collapsed into one signal.

That distinction helps isolate failures:

```text
TCP probe failed
  -> network/listener path problem

TCP works, TLS probe failed
  -> TLS/certificate/hostname problem

probes work, Alertmanager reports failures
  -> notification integration/application problem
```

## TLS certificate expiry

The TLS job exports:

```text
probe_ssl_earliest_cert_expiry
```

The production rules use two windows:

```text
warning:  less than 30 days but at least 14 days remaining
critical: less than 14 days remaining
```

The verified certificate had approximately 80 days remaining when this runbook was prepared.

A typical remaining-life query is:

```promql
(
  probe_ssl_earliest_cert_expiry{job="blackbox_tls"}
  - time()
) / 86400
```

The expiry alerts are gated by `probe_success == 1`. This prevents a failed TLS handshake from being misreported merely as an expiry warning.

## Probe-success alerts

The production notification-path alerts use `probe_success == 0` with a delay rather than firing on one missed probe.

Examples use a two-minute hold for critical SMTP/XMPP/bridge reachability failures.

The ICMP canary is currently present in discovery and returns success, but the captured active rule section does not establish a dedicated ICMP alert. This runbook therefore does not invent one.

## HTTP probe semantics

An HTTP `2xx` probe verifies that the configured endpoint responds successfully from the monitoring host.

It does not automatically prove application correctness beyond that endpoint.

A readiness endpoint is stronger than checking that TCP/9090 accepts a connection, but weaker than a business-level synthetic transaction.

## TCP probe semantics

A successful TCP connection proves only that:

```text
DNS resolution succeeded when a hostname was used
routing reached the destination
a TCP handshake completed
a listener accepted the connection
```

It does not prove authentication, SMTP delivery, XMPP session establishment or application response semantics.

That is why SMTP has a separate TLS probe and notification-send failures are monitored through Alertmanager itself.

## ICMP canary

The ICMP target acts as a simple probe-path canary.

Because it is intentionally minimal, it should not be interpreted as broad network monitoring. For routers, switches and WAN paths, device-specific SNMP and routing telemetry remain separate layers.

## Validation commands

Validate the exporter version and service:

```bash
/usr/local/bin/blackbox_exporter --version
systemctl status blackbox_exporter --no-pager
ss -lntp | grep ':9115'
```

Validate the configuration before restart/reload using the exporter tooling available for the installed version, then confirm runtime probes through Prometheus.

Check all probe outcomes:

```promql
probe_success{job=~"blackbox_http|blackbox_tcp|blackbox_icmp|blackbox_tls"}
```

Check certificate lifetime:

```promql
(probe_ssl_earliest_cert_expiry{job="blackbox_tls"} - time()) / 86400
```

## Change procedure

When adding another probe:

1. decide whether the required check is HTTP, TCP, ICMP or TLS;
2. reuse an existing module only when its semantics match;
3. create a new TLS module when hostname/protocol policy differs;
4. add the target to the correct file_sd file;
5. preserve consistent labels such as `target_name`, `service`, `probe_type` and `criticality`;
6. validate Prometheus configuration;
7. reload Prometheus;
8. confirm the runtime target exists;
9. confirm `probe_success` and any expected protocol metrics;
10. add an alert only when there is an operational response for that failure.

## Rollback

Preserve the previous:

```text
/etc/blackbox_exporter/blackbox.yml
/etc/prometheus/prometheus.yml
/etc/prometheus/targets/blackbox/*.yml
relevant Prometheus rule file
```

Rollback the module/target/rule change, validate configuration again and confirm that the previous probe series returns to its known state.

## Known caveats

- A TCP check is not an application transaction.
- An HTTP health endpoint only proves what that endpoint implements.
- ICMP may be filtered even when application traffic works.
- A TLS module with a fixed `server_name` is endpoint-specific.
- Certificate-expiry metrics require a successful TLS probe.
- Monitoring only from the Prometheus host describes reachability from that vantage point, not from every user network.

## References

- Blackbox Exporter: <https://github.com/prometheus/blackbox_exporter>
- Prometheus relabel configuration: <https://prometheus.io/docs/prometheus/latest/configuration/configuration/#relabel_config>
- Prometheus file-based service discovery: <https://prometheus.io/docs/prometheus/latest/configuration/configuration/#file_sd_config>
- Prometheus alerting rules: <https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/>
