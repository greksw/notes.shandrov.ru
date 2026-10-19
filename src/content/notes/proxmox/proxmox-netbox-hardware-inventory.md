---
title: "Inventorying nine Proxmox VE nodes in NetBox 4.7: DMI, MAC addresses and network topology"
description: "Production case study: read-only collection of nine Proxmox hosts and 362 interfaces, safe enrichment of existing NetBox devices, and a verified idempotent dry-run."
category: "Proxmox & Virtualization"
tags: ["proxmox", "netbox", "dcim", "inventory", "dmi", "mac", "networking", "python", "automation"]
published: 2026-10-19
updated: 2026-10-19
status: current
testedOn: ["Proxmox VE", "NetBox 4.7.3", "Python 3.13", "AlmaLinux 9"]
featured: false
lang: en
translationKey: "proxmox/proxmox-netbox-hardware-inventory"
---

## Objective

NetBox already held the physical Proxmox devices and interfaces. The next step was to validate the **actual hardware inventory** against DCIM: DMI manufacturer/model, usable hardware serials, current physical NIC MAC addresses, bridges, VLAN interfaces and their parent relationships.

This case study covers a **nine-host Proxmox VE cluster** verified in October 2026. Hostnames, addresses, domains and local NetBox slugs are examples; the aggregate counts come from completed checks. The published toolkit is [greksw/netbox-inventory-toolkit](https://github.com/greksw/netbox-inventory-toolkit). This toolkit is not a two-way automatic synchronizer.

## 01 / Collection architecture

```text
Proxmox cluster (9 nodes)
  ├── pvesh GET: hosts, status, network configuration
  ├── local sysfs: DMI, physical NIC MACs
  └── optional trusted SSH to peers: DMI and NIC MACs
               |
               v
       private inventory v0.3 (0600)
               |
       topology/completeness audit
               |
       NetBox read-only preview
               |
       guarded hardware enrichment of pre-existing DCIM objects
```

The collector runs on a cluster node as root because `pvesh` needs privileged access. Remote DMI and NIC reads are opt-in; SSH is batch-only and requires previously verified host keys. Nothing in the collector writes to NetBox or changes the network configuration. VM/CT inventory, rack cabling, VLAN reachability and IPAM creation are separate concerns.

## 02 / Running a private read-only collection

```bash
git clone https://github.com/greksw/netbox-inventory-toolkit.git
cd netbox-inventory-toolkit

# Start with the local host:
python3 collectors/proxmox_inventory.py \
  --node "$(hostname -s)" --cluster-label example-pve

# After explicitly configuring trusted key-based SSH:
python3 collectors/proxmox_inventory.py \
  --cluster-label example-pve --dmi-ssh --mac-ssh \
  --output output/proxmox-inventory-v03.json
```

The JSON is written atomically with mode `0600`; the `output/` directory is Git-ignored. Never publish the actual inventory JSON, host identifiers, MACs, serials or SSH credentials.

The physical MAC fallback reads `/sys/class/net/*/address` only when a physical sysfs `device` exists. These are **current interface MAC values**, not guaranteed factory MACs. No physical NIC MAC is guessed for Linux bridges or VLAN subinterfaces.

The built-in topology audit verifies references such as VLAN parents, bridge ports and bond slaves. It does not prove cable continuity, network reachability or correct VLAN forwarding.

## 03 / Verified results

| Measure | Result |
| --- | ---: |
| Successfully collected hosts | **9/9** |
| Interface records | **362** |
| Physical NIC MAC values | **20** |
| Usable DMI serials | **7** |
| Nodes without a usable serial | **2** |
| Topology reference issues | **0** |

The audit compared node/interface names as well as counts. A SHA-256 digest over a sorted `node|interface` list provided an additional consistency check; the actual infrastructure digest is omitted.

Two hosts had no usable serial from the source. These values stayed unknown rather than being fabricated.

## 04 / Existing-object reconciliation

The toolkit includes an offline comparison:

```bash
python3 netbox/preview.py \
  --inventory output/proxmox-inventory-v03.json \
  --output output/netbox-preview.json
```

**Important distinction:** devices and interfaces already existed in the live NetBox database. Initial serial/MAC enrichment was carried out in a separate manually reviewed, transaction-protected administrative procedure after a PostgreSQL backup. The generic `netbox/enrich_existing.py` module was subsequently validated in production **in dry-run mode only**; it did not perform that initial write.

A representative protected Django shell invocation, with generic site/role values:

```bash
runuser -u netbox -- /opt/netbox/venv/bin/python \
  /opt/netbox/netbox/manage.py shell -c \
  "from runpy import run_path; run_path('/secure/enrich_existing.py')['run'](
    '/secure/proxmox-inventory-v03.json',
    site_slug='example-office', role_slug='hypervisor',
    expected_devices=9, expected_interfaces=362,
    expected_serials=7, expected_macs=20
  )"
```

The verified repeat audit reported:

```text
mode: DRY-RUN
verified_devices: 9
verified_interfaces: 362
serials_to_add: 0
macs_to_assign: 0
serials_matching: 7
macs_matching: 20
```

The generic enrichment module is guarded, requires a separate confirmation for an optional apply, and updates eligible existing hardware fields only. It does not create IP addresses, VLANs, interfaces, VMs or devices. Avoid concurrent importers that modify the same records.

## 05 / Operational conclusions

- Separate **collection, comparison and apply** stages.
- Incomplete node collection or broken topology should never be reported as “in sync.”
- Unknown hardware identifiers remain unknown.
- Treat raw inventory JSON as confidential.
- Recheck continuously rather than relying on one successful inventory.

The next part of this implementation is covered in [Daily Proxmox–NetBox drift detection with systemd and Zabbix](/notes/monitoring/proxmox-netbox-drift-audit-zabbix/).

### Resources

- [NetBox Inventory Toolkit repository](https://github.com/greksw/netbox-inventory-toolkit)
- [Proxmox VE API Viewer](https://pve.proxmox.com/pve-docs/api-viewer/)
