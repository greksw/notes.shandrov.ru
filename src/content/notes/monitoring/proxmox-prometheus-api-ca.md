---
title: "Monitoring Proxmox VE with Prometheus using API tokens and a trusted CA"
description: "A production-oriented pattern for collecting Proxmox metrics without disabling TLS verification or using a full administrator account."
category: "Monitoring & Security"
tags: ["proxmox", "prometheus", "tls", "api", "monitoring"]
published: 2026-09-15
updated: 2026-09-15
status: current
testedOn: ["Proxmox VE 9.x", "Prometheus 3.x", "AlmaLinux 9"]
featured: true
---

## Context

A Prometheus exporter needs access to the Proxmox API, but monitoring should not require a reusable administrator password and TLS verification should not be disabled simply to make HTTPS requests work.

The deployment pattern used here separates three concerns:

1. a dedicated Proxmox account with read-only permissions;
2. an API token scoped to that account;
3. explicit trust of the Proxmox cluster CA on the monitoring host.

## Access model

Create a monitoring identity in Proxmox and grant only the permissions required for inventory and metrics collection. For a read-only exporter, `PVEAuditor` is the appropriate baseline rather than `Administrator`.

Use a separate API token for the exporter. Token separation makes revocation and rotation independent from the user account itself and avoids placing an interactive password in exporter configuration.

## TLS trust

Do not set `verify_ssl: false` as the permanent solution.

Export the relevant Proxmox root CA, transfer it to the monitoring system through a trusted administrative channel and install it as a root-owned certificate file. Configure the exporter process to use that CA bundle when establishing HTTPS sessions to the Proxmox API.

For Python-based exporters this can be done through the process environment, for example by setting `REQUESTS_CA_BUNDLE` to the installed CA file.

## Prometheus layout

Keep cluster-level and node-level collection logically separate when that makes alerting and dashboards clearer. A typical deployment exposes the exporter on its own local service port and defines explicit Prometheus jobs for the Proxmox API as well as normal `node_exporter` targets on each hypervisor.

This makes failures distinguishable:

- host metrics missing while the API is healthy;
- API metrics missing while the nodes remain reachable;
- one failed node versus a cluster-wide collection problem.

## Validation

Validation should cover more than an HTTP 200 response.

- confirm the exporter service is running under the intended account;
- verify the CA bundle is actually used and that certificate errors are not suppressed;
- query the exporter endpoint directly;
- run `promtool check config` before reloading Prometheus;
- confirm every expected Proxmox and node-exporter target is `UP`;
- compare returned node and VM inventory with the actual cluster.

## Security notes

Treat the API token as a secret even though its permissions are read-only. Keep it outside the repository, restrict configuration file permissions and rotate it if it is ever exposed.

A read-only token plus validated TLS provides a substantially better failure boundary than an administrator credential combined with disabled certificate verification.
