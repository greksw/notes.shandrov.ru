---
title: "Proxmox–NetBox drift detection with systemd, HTTPS API and Zabbix 7.0"
description: "A verified daily read-only audit of Proxmox hosts against NetBox 4.7 with a trusted CA, API v2 token, systemd timer, sanitized Zabbix metrics and four triggers."
category: "Monitoring & Security"
tags: ["proxmox", "netbox", "drift-detection", "zabbix", "systemd", "tls", "python", "monitoring"]
published: 2026-10-19
updated: 2026-10-19
status: current
testedOn: ["NetBox 4.7.3", "Zabbix Server 7.0.31", "Zabbix Agent 7.0.22", "Proxmox VE", "systemd"]
featured: false
lang: en
translationKey: "monitoring/proxmox-netbox-drift-audit-zabbix"
---

## From hardware inventory to ongoing drift detection

After the [nine-node hardware inventory](/notes/proxmox/proxmox-netbox-hardware-inventory/) had been reconciled with NetBox, it became necessary to detect changes over time. Hardware and network interfaces can change, and the inventory job itself can stop running.

The resulting system runs a **daily read-only** audit of the Proxmox cluster against NetBox and exposes three sanitized numbers through Zabbix Agent. The audit never writes to NetBox. This account describes verified work completed in October 2026. Internal addresses, hostnames, domains and secrets are replaced with examples.

Source repository: [netbox-inventory-toolkit](https://github.com/greksw/netbox-inventory-toolkit).

## 01 / Architecture and trust boundaries

```text
Proxmox: pvesh + verified peer SSH
            |
            v
    daily drift_audit.py ---- HTTPS GET ----> NetBox API
            |
            v
    private report (root:root 0600)
            |
    systemd ExecStopPost exporter
            |
    sanitized metrics (root:zabbix 0640)
            |
    Zabbix Agent -- TLS PSK passive --> Zabbix Server
                                           |
                                         4 triggers
```

Root can read the sensitive source inventory and NetBox token; the `zabbix` account can read only three integers. No sudo permissions for the agent and no access to the original snapshot are required.

For NetBox API v2, use a dedicated token with **view-only Device and Interface permissions**, write access disabled and an optional source-IP restriction. A private `root:root 0600` environment file points to the HTTPS origin and trusted corporate CA:

```ini
NETBOX_URL=https://netbox.example.net
NETBOX_TOKEN=nbt_EXAMPLE_ID.EXAMPLE_SECRET
NETBOX_CA_FILE=/etc/netbox-inventory/ca.pem
```

The token is a nonfunctional placeholder. Do not disable TLS verification; transfer only the **public CA certificate**, never the CA private key.

## 02 / Validate an existing snapshot, then collect fresh data

```bash
cd /root/netbox-inventory-toolkit
set -a
. /etc/netbox-inventory/drift.env
set +a

# First isolate the NetBox API comparison:
python3 netbox/drift_audit.py \
  --inventory output/proxmox-inventory-v03.json \
  --output-dir /var/lib/netbox-inventory \
  --site-slug example-office --role-slug hypervisor \
  --expected-nodes 9

# Then omit --inventory to query the live cluster:
python3 netbox/drift_audit.py \
  --output-dir /var/lib/netbox-inventory \
  --cluster-label example-pve \
  --site-slug example-office --role-slug hypervisor \
  --expected-nodes 9

unset NETBOX_TOKEN
```

Both paths were tested successfully in the deployment:

```text
STATUS: CLEAN
devices_checked: 9
interfaces_source: 362
interfaces_netbox: 362
physical_macs_checked: 20
serials_checked: 7
differences: 0
```

Exit codes distinguish `0` (clean), `1` (drift found), and `2` (collection/API/data error). Never interpret `2` as clean. The current checker covers existing devices, interface names, available serials and physical NIC MACs, not VM configurations or physical cables.

## 03 / Schedule with systemd

Example units live in `deploy/systemd/`:

```bash
install -m 0644 deploy/systemd/netbox-inventory-drift.service \
  /etc/systemd/system/
install -m 0644 deploy/systemd/netbox-inventory-drift.timer \
  /etc/systemd/system/
systemctl daemon-reload
systemd-analyze verify /etc/systemd/system/netbox-inventory-drift.service
systemctl start netbox-inventory-drift.service
journalctl -u netbox-inventory-drift.service -n 30 --no-pager
systemctl enable --now netbox-inventory-drift.timer
systemctl list-timers --all netbox-inventory-drift.timer
```

The validated daily schedule runs at about **05:10 server local time** with up to 20 minutes of random delay. `Persistent=true` catches missed scheduled runs. Adapt hard-coded local paths and NetBox site/role slugs in the example units before installation.

The service declares `SuccessExitStatus=1`: detected drift means the audit executed and completed, even though it found a problem. Therefore service status alone cannot indicate whether the inventory is clean.

## 04 / Safe metrics export

The raw snapshot and report remain `0600 root:root`. `netbox/zabbix_bridge.py`, attached via `ExecStopPost`, writes only a sanitized `root:zabbix 0640` JSON file. Classic Zabbix Agent passive UserParameters expose:

| Item | Meaning |
| --- | --- |
| `netbox.audit.status` | 0 clean, 1 drift, 2 error |
| `netbox.audit.differences` | Number of differences; not authoritative when status=2 |
| `netbox.audit.timestamp` | Last audit-attempt completion as Unix epoch seconds |

The production check returned status=0, differences=0 and a valid timestamp; the file permissions were confirmed. A failed audit publishes status=2 instead of reusing the previous clean state.

## 05 / Passive Zabbix checks and TLS PSK

The agent was configured to accept TLS PSK connections. An unencrypted `zabbix_get` probe produced `unencrypted connections are not allowed`: that was an expected security refusal, **not** a broken UserParameter. For passive checks, set the item Type to **Zabbix agent**, not **Zabbix agent (active)**; configure matching PSK identity and secret under the monitored host's encryption settings.

Four template triggers were created and verified:

```text
last(/Template NetBox Inventory Drift/netbox.audit.status)=1
last(/Template NetBox Inventory Drift/netbox.audit.status)=2
now()-last(/Template NetBox Inventory Drift/netbox.audit.timestamp)>93600
nodata(/Template NetBox Inventory Drift/netbox.audit.status,15m)=1
```

Severities are Warning, High, Average and Average. Each trigger carries `component=netbox-drift`. The Zabbix frontend confirmed four enabled triggers in **OK** and three items with incoming values.

For command-line setup, use the toolkit's `zabbix/configure_template_api.py` tool: dry-run first; explicit `--apply` adds missing triggers. Its idempotence check uses `trigger.get` with `expandExpression=true`, because raw Zabbix API responses may encode expressions with internal function IDs (`{86279}=1`) instead of the original textual expression. This was observed and corrected during deployment.

## 06 / Alert delivery: intentionally out of scope

The four Zabbix triggers are active, but **notification Trigger actions were not enabled** in this deployment. A separate Grafana/Prometheus/Loki observability stack is already responsible for alerts; duplicating notifications in Zabbix was deliberately deferred. A direct Prometheus exporter and dedicated Grafana alert rule remain future improvements, not completed features.

### Resources

- [NetBox Inventory Toolkit and Zabbix bridge](https://github.com/greksw/netbox-inventory-toolkit)
- [Proxmox hardware inventory article](/notes/proxmox/proxmox-netbox-hardware-inventory/)
- [Monitoring Proxmox VE with Prometheus and trusted CA](/notes/monitoring/proxmox-prometheus-api-ca/)
