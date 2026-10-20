---
title: "Proxmox QEMU/LXC inventory in NetBox: vNIC import and daily drift monitoring"
description: "A production case study of QEMU/LXC discovery with Python, guarded NetBox 4.7 VMInterface/MAC import, systemd scheduling and Zabbix 7.0 guest drift monitoring."
category: "Monitoring & Security"
tags: ["proxmox", "netbox", "qemu", "lxc", "python", "virtualization", "zabbix", "systemd", "drift-detection", "automation"]
published: 2026-10-20
updated: 2026-10-20
status: current
testedOn: ["Proxmox VE", "NetBox 4.7.3", "Python 3", "PostgreSQL", "systemd", "Zabbix 7.0.31"]
featured: false
lang: en
translationKey: "monitoring/proxmox-netbox-guest-nic-drift"
---

## From physical host inventory to guest interfaces

The earlier articles cover [Proxmox host inventory in NetBox](/notes/proxmox/proxmox-netbox-hardware-inventory/) and [daily read-only host drift detection via Zabbix](/notes/monitoring/proxmox-netbox-drift-audit-zabbix/). The next operational requirement was to extend the same discipline to **QEMU VMs and LXC containers**.

A one-off VM import does not keep virtual NICs, CPU/RAM or node placement current. Blind synchronization is risky: a powered-off gold image may intentionally share a MAC with a live workload, while a Proxmox host bridge name is not necessarily a native NetBox VMInterface bridge reference.

The implemented workflow follows **discovery → preview → human review → Django dry-run → approved import → daily read-only reconciliation → Zabbix**. It detects drift; it does **not** automatically alter VM configurations.

Source code and implementation guidance: [NetBox Inventory Toolkit](https://github.com/greksw/netbox-inventory-toolkit). See the [portfolio case study](https://shandrov.ru/en/projects/proxmox-netbox-inventory/) for a shorter architecture-focused overview.

## 01 / Architecture and trust boundaries

```text
Proxmox VE cluster: pvesh GET
          |
          v
  Python guest collector → private JSON (0600)
          |
          +----- HTTPS GET, CA validation, read-only token ----> NetBox API
          |                                                      |
          v                                                      v
  reviewed vNIC preview                               existing VM / VMID index
          |
          +---- explicit one-time Django transaction → VMInterface / MAC
          |
          +---- daily guest drift audit -- HTTPS GET --+
                                                        |
  root-owned private audit report                       |
          |                                             |
  systemd ExecStopPost → sanitized numeric metrics      |
          |                                             |
  Zabbix Agent → Zabbix Server: items and triggers <-----+
```

The collector and scheduled auditor use only Proxmox `pvesh GET` and NetBox HTTPS `GET`, with a view-only API token. The **one-time approved importer** is different: it runs locally in NetBox Django with service-account permissions following a verified backup and explicit authorization.

Raw inventories contain identifiers and are stored with `0600` permissions. The Zabbix Agent only reads three sanitized numeric values from a separate `root:zabbix 0640` file, never the private source report or API credentials.

## 02 / Collecting QEMU/LXC configuration

`collectors/proxmox_guests.py` enumerates guest identities and configuration using a restricted field list: VMID, type, node, power state, configured vCPU/RAM, `netN`, MAC, host bridge and an explicit VLAN tag where available. It does not persist full guest configs, disks, passwords or SSH keys.

```bash
cd /root/netbox-inventory-toolkit

python3 collectors/proxmox_guests.py \
  --expected-guests YOUR_APPROVED_GUEST_COUNT \
  --cluster-label example-pve \
  --output output/proxmox-guests.json
```

Replace the expected count with your reviewed baseline. Unexpectedly adding or removing a guest must not be silently interpreted as a complete inventory. The `output/` directory is gitignored; resulting snapshots are private.

For QEMU, configured vCPUs represent the configured maximum topology, **not CPU usage**. `vmbr*` is a **Proxmox host bridge name** and must not be blindly assigned to the NetBox `VMInterface.bridge` relationship.

## 03 / Reviewable NetBox vNIC preview

Existing NetBox VMs are matched using the `proxmox_vmid` custom field, then checked for type, node, power state, configured CPU and RAM. The preview also evaluates NIC names, MACs and host bridges.

```bash
set -a
. /etc/netbox-inventory/drift.env
set +a

python3 netbox/preview_guest_nics.py \
  --inventory output/proxmox-guests.json \
  --cluster example-pve \
  --expected-guests YOUR_APPROVED_GUEST_COUNT \
  --output output/guest-nics-preview.json

unset NETBOX_TOKEN
```

The root-only environment contains `NETBOX_URL`, `NETBOX_TOKEN` and `NETBOX_CA_FILE`. TLS verification remains enabled.

Two real operational edge cases were explicitly reviewed:

- **Duplicate MAC shared by a stopped template and running guest:** both interfaces are inventoried, but the template interface keeps its primary MAC unassigned in NetBox while the running workload has the MAC.
- **Host bridge referenced by a stopped template is absent:** record a warning, preserve the bridge name as textual VMInterface description metadata, and avoid inventing a VLAN or creating bridge objects.

An exception must be documented and approved rather than silently ignored.

## 04 / Guarded initial VMInterface import

`netbox/import_guest_nics.py` is invoked in the NetBox 4.7 `manage.py shell`. Before the approved write, a PostgreSQL custom-format backup is created and verified, the preview is transferred privately with `0600` permissions, and a Django dry-run checks identities, counts and report freshness.

```python
# Illustrative fragment inside the NetBox Django shell.
from import_guest_nics import run

run(
    "/path/to/private/guest-nics-preview.json",
    cluster="example-pve",
    expected_vms=YOUR_VM_COUNT,
    expected_nics=YOUR_NIC_COUNT,
    expected_macs=YOUR_ASSIGNABLE_MAC_COUNT,
    held_vmids=(YOUR_STOPPED_TEMPLATE_VMID,),
    apply=False,
)
```

The `YOUR_*` names are **placeholders**, and the module must already be on Python's import path. The default dry-run makes no writes. Applying requires a separate `apply=True` and the exact confirmation `APPLY_REVIEWED_GUEST_INTERFACES`, after human approval. Validated changes run in one Django `transaction.atomic()` transaction.

The deployment verified that VM interfaces and nonconflicting MACs had been created while the intentional held-MAC exception remained intact. Guest settings, VLAN and IPAM objects were not modified.

**Scope limitation:** the initial importer assumes one vNIC per VM and an empty VMInterface baseline. It is not a generic always-on reconciler for arbitrary future multi-NIC layouts.

## 05 / Daily GET-only guest drift audit

The separate `netbox/audit_guest_nics.py` always reads Proxmox and NetBox without writing to either. It compares VM identities, node/state, vCPU/RAM, virtual interface names, primary MACs and saved bridge descriptions.

```bash
cd /root/netbox-inventory-toolkit

set -a
. /etc/netbox-inventory/drift.env
set +a

python3 netbox/audit_guest_nics.py \
  --cluster example-pve \
  --expected-guests YOUR_APPROVED_GUEST_COUNT \
  --held-vmid YOUR_STOPPED_TEMPLATE_VMID \
  --output-dir /var/lib/netbox-guest-audit

unset NETBOX_TOKEN
```

Exit codes: `0` means `CLEAN`, `1` means `DRIFT`, and `2` means `ERROR` (collection/API/data failure). An incomplete snapshot or unrecognized API response must **never** be reported as clean.

During acceptance testing, guest identities, NICs, assignable MACs and the approved exception all matched; the difference count was zero. The first subsequent scheduled execution and deliberate trigger-firing tests were left as separate operational checks.

## 06 / Separate systemd timer and Zabbix items

Guest drift runs under separate `netbox-guest-drift.service` and `netbox-guest-drift.timer` units, without modifying the existing physical-host audit. Host-specific values reside in a local `root:root 0600` environment:

```ini
# /etc/netbox-inventory/guest-audit.env
GUEST_CLUSTER=example-pve
GUEST_EXPECTED_GUESTS=YOUR_APPROVED_GUEST_COUNT
GUEST_HELD_VMID=YOUR_STOPPED_TEMPLATE_VMID
```

After installing the repository's sample unit files and validating a manual audit:

```bash
systemctl daemon-reload
systemd-analyze verify /etc/systemd/system/netbox-guest-drift.service
systemctl start netbox-guest-drift.service
journalctl -u netbox-guest-drift.service -n 30 --no-pager

systemctl enable --now netbox-guest-drift.timer
systemctl list-timers --all netbox-guest-drift.timer
```

The sample schedule runs daily at approximately 05:45 plus 0–15 minutes of randomized delay, after the physical audit. `SuccessExitStatus=1` means drift is an **audit result** rather than a failed execution. Therefore a successful `systemctl` run cannot substitute for reading the report status.

An independent `netbox/zabbix_guest_bridge.py` exporter in `ExecStopPost` publishes only:

| Zabbix key | Meaning |
| --- | --- |
| `netbox.guest.audit.status` | `0` CLEAN, `1` DRIFT, `2` ERROR |
| `netbox.guest.audit.differences` | Difference count; unknown when status=ERROR |
| `netbox.guest.audit.timestamp` | Unix time of the latest audit attempt |

```bash
zabbix_agentd -t netbox.guest.audit.status
zabbix_agentd -t netbox.guest.audit.differences
zabbix_agentd -t netbox.guest.audit.timestamp
```

The Zabbix 7.0 setup utility `zabbix/configure_guest_template_api.py` previews changes first, then requires `--apply` and can re-check existing objects idempotently. The independent template contains three passive unsigned numeric items and four triggers: drift, error, age over 26 hours and no monitoring data for 15 minutes.

Finally, **Monitoring → Latest data** confirmed Zabbix Server actually polled guest status `0`, differences `0` and the audit timestamp. The existing physical-host template was unchanged.

## 07 / What this system does not do

- **No automatic remediation.** An engineer decides whether NetBox or the live Proxmox configuration should change when drift appears.
- **No claim of delivered alerts.** Items and triggers exist, but actual trigger firing and notification routing require separate testing. No Zabbix notification actions were created.
- **Approved count is enforced.** A newly added guest initially causes a control-count error until reviewed and added to the inventory baseline.
- **Not a complete network model.** In-guest IP reachability, VLAN connectivity, all VM configuration fields, physical cabling and full IPAM lifecycle are outside this audit.

Operational follow-up includes reviewing exceptions, testing alarms, validating NetBox backups, and reviewing changes via GitHub Actions.

### Related resources

- [Portfolio: Proxmox, NetBox and Zabbix](https://shandrov.ru/en/projects/proxmox-netbox-inventory/)
- [NetBox Inventory Toolkit source and tests](https://github.com/greksw/netbox-inventory-toolkit)
- [Proxmox host inventory in NetBox](/notes/proxmox/proxmox-netbox-hardware-inventory/)
- [Daily host drift detection and Zabbix](/notes/monitoring/proxmox-netbox-drift-audit-zabbix/)
