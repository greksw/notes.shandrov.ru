---
title: "Network monitoring with SNMP Exporter and Prometheus"
description: "Production-backed SNMP monitoring architecture for MikroTik and Zyxel devices using snmp_exporter 0.30.1 and Prometheus file-based discovery."
category: "Monitoring & Security"
tags: ["snmp", "prometheus", "snmp-exporter", "mikrotik", "zyxel", "networking"]
published: 2026-09-16
updated: 2026-09-16
status: current
testedOn: ["snmp_exporter 0.30.1", "Prometheus file_sd"]
featured: true
translationKey: "monitoring/snmp-exporter-network-monitoring"
---

## Context

The production network-monitoring layer uses one local SNMP Exporter instance and a file-based inventory. Prometheus passes the target and module selection to the exporter for each network device.

```text
Prometheus file_sd
    -> SNMP Exporter on 127.0.0.1:9116
    -> routers / switches / access points
```

The verified production inventory contains 19 SNMP device targets across several sites. At validation time all 19 device targets and the exporter self-target were `UP`.

## Verified baseline

```text
snmp_exporter: 0.30.1
platform: linux/amd64
service account: snmp_exporter
listener: 127.0.0.1:9116
```

The exporter runs as a dedicated systemd service and is reachable only over loopback from the Prometheus host.

## Prometheus job

The shared device job uses:

```yaml
- job_name: snmp
  scrape_interval: 60s
  scrape_timeout: 50s
  metrics_path: /snmp

  file_sd_configs:
    - files:
        - /etc/prometheus/targets/snmp/*.yml
      refresh_interval: 30s
```

Relabeling sends the device target and selected module set to the local exporter and then records the real device address as the Prometheus `instance` label.

## Inventory contract

Each device is described by labels such as:

```text
site
vendor
model
role
module set
```

A sanitized example:

```yaml
- targets:
    - <management-ip>
  labels:
    site: <site>
    vendor: mikrotik
    model: RB5009UG+S+
    role: gateway
    snmp_module: if_mib,mikrotik
```

The inventory is intentionally split into one file per device or device contract so model-specific exceptions remain explicit.

## Verified device classes

Current RouterOS gateways and access points use:

```text
if_mib,mikrotik
```

A RouterOS device used as a switch uses:

```text
if_mib,hrDevice,hrStorage,mikrotik_switch_system
```

A verified SwOS target uses only:

```text
if_mib
```

Several Zyxel GS1920-family switches use:

```text
if_mib,zyxel_gs1920_system
```

Some GS1900-family switches currently use only `if_mib`.

The module set is therefore device- and role-specific rather than a global vendor default.

## Common interface layer

`if_mib` is the portable baseline across vendors. It supplies the common interface signals used for:

```text
administrative state
operational state
speed
traffic counters
errors
discards
interface identity
```

Vendor modules extend that baseline with device-specific system data where supported.

## Higher-level monitoring layers

The production rule set separates transport collection from domain logic.

Switch alerts cover availability, trunk state and speed, CPU, memory, temperature, voltage, system storage, port errors/discards and VLAN-contract checks.

Access-point rules cover uplink status and traffic, WLAN state, radio metrics and selected RouterOS wireless data. CAPsMAN and MikroTik IPsec have their own rule groups.

This separation keeps the generic SNMP transport layer reusable while allowing role-specific policies to evolve independently.

## Runtime verification

The verified runtime state was:

```text
19 job="snmp" targets: UP
1 job="snmp_exporter" target: UP
```

This confirms the complete path from Prometheus discovery through the exporter to the network devices.

## Troubleshooting model

When a target fails, separate the likely failure domains:

```text
exporter unavailable
network reachability to the device
polling profile mismatch
unsupported or slow module set
device response time near the scrape timeout
```

A healthy exporter self-target does not prove every device poll is healthy, and a single failed device target does not imply the exporter process is down.

## Adding a device

A safe onboarding sequence is:

1. identify vendor, model and operational role;
2. choose the smallest module set that covers the required metrics;
3. add the target with standard inventory labels;
4. wait for file-based discovery refresh;
5. confirm the runtime target becomes `UP`;
6. inspect returned metrics;
7. add role-specific recording and alert rules only after the metric contract is verified.

A target-file-only change does not require a Prometheus restart because discovery refresh is periodic.

## Backup and rollback

Preserve the exporter unit, SNMP module configuration, Prometheus target inventory and related rule files before changes.

After rollback, verify both the exporter self-target and affected device targets return to `UP`.

## Validation checklist

```text
[ ] exporter version is known
[ ] exporter runs as dedicated account
[ ] exporter listens on the intended address
[ ] target has site/vendor/model/role metadata
[ ] module set matches the actual device model and role
[ ] Prometheus discovers the target
[ ] runtime target is UP
[ ] exporter self-target is UP
[ ] actual metrics are inspected before alerts are added
```

## References

- SNMP Exporter: <https://github.com/prometheus/snmp_exporter>
- Prometheus file-based service discovery: <https://prometheus.io/docs/prometheus/latest/configuration/configuration/#file_sd_config>
- Prometheus relabeling: <https://prometheus.io/docs/prometheus/latest/configuration/configuration/#relabel_config>
