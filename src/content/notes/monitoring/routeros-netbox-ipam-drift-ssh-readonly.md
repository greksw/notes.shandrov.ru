---
title: "RouterOS and NetBox: read-only IPAM drift detection with SSH and API"
description: "A practical RouterOS 7 versus NetBox 4.7 IPAM audit: exact VLAN, prefix and interface/IP comparison, least-privilege SSH, read-only API access and reviewed IPsec exceptions."
category: "Monitoring & Security"
tags: ["mikrotik", "routeros", "netbox", "ipam", "ssh", "python", "drift-detection", "network-automation", "security"]
published: 2026-10-21
updated: 2026-10-21
status: current
testedOn: ["MikroTik RouterOS 7", "NetBox 4.7.3", "Python 3.11", "OpenSSH", "AlmaLinux 9", "systemd"]
featured: false
lang: en
translationKey: "monitoring/routeros-netbox-ipam-drift-ssh-readonly"
---

## Why an IPAM database still needs drift detection

NetBox records what a network *should* contain: devices, interfaces, VLANs, prefixes and IP assignments. It does not, on its own, guarantee that the currently running router configuration still matches those records. An IP may be moved to another interface, a VLAN may be changed, or a runtime address may appear without a documented change.

This case study describes a **read-only audit of MikroTik RouterOS 7 against NetBox 4.7**. The system reports differences but **does not automatically modify either endpoint**. Its implementation was validated incrementally: collect both sources independently, compare exact records, investigate a dynamic IPsec address, and run a recurring audit.

Every hostname, IP address, VLAN count and sample identity below is **illustrative and anonymized**. No real network map, VPN identifier, API token or SSH credential is published.

**Code:** [NetBox Inventory Toolkit](https://github.com/greksw/netbox-inventory-toolkit) and the [RouterOS IPAM audit pull request](https://github.com/greksw/netbox-inventory-toolkit/pull/16). The PR contains the comparison library and source adapters, not the full locally deployed production wrapper.

## 01 / Architecture and trust boundaries

```text
MikroTik RouterOS 7                         NetBox 4.7
  dedicated ssh,read account                  HTTPS GET, view-only API token v2
  strict known_hosts verification             trusted certificate authority
             |                                          |
             v                                          v
     RouterOSSSHReader                            NetBoxReader
     VLAN interfaces + IPs                        Devices / Interfaces
                                                  VLANs / Prefixes / IPs
             |                                          |
             +-------------------+----------------------+
                                 v
                       Normalize both snapshots
                                 |
                                 v
                        Read-only comparison
                                 |
                        CLEAN / DRIFT / ERROR
```

The RouterOS account has only `ssh,read` privileges, an origin-IP restriction and a dedicated Ed25519 identity. It does not need `write`, `policy` or `sensitive` permissions. SSH is restricted to public-key authentication, a preapproved host key and two hardcoded commands; SSH agent and port forwarding are disabled.

NetBox uses a separate service user with view permissions for `Device`, `Interface`, `VLAN`, `Prefix` and `IPAddress`. Its API v2 token has writing disabled, and should also have an allowed-origin IP and expiration date. TLS certificate verification is mandatory; `verify=False` and `curl -k` are not solutions to trust problems.

## 02 / The RouterOS collector

The SSH collector avoids enabling the RouterOS REST service. It executes only the following two predefined commands:

```routeros
:put [:serialize to=json value=[/interface vlan print as-value] options=json.no-string-conversion]
:put [:serialize to=json value=[/ip address print as-value] options=json.no-string-conversion]
```

`routeros/ssh_source.py` restricts commands to that fixed list, parses the responses as JSON arrays and rejects malformed, oversized or unavailable data. From RouterOS it normalizes VLAN ID/name/parent/disabled and the IPv4 CIDR/interface/dynamic/disabled fields.

Raw JSON must be kept private. Exporting the entire response as Prometheus labels or CI logs would disclose internal infrastructure details.

## 03 / The NetBox GET-only adapter

The NetBox collector first confirms one matching router by **device name, site and role**. It then resolves that device's interfaces, the selected VLAN group, its prefixes and IP addresses assigned to those interfaces.

Allowed API endpoints are deliberately narrow:

```text
/api/dcim/devices/
/api/dcim/interfaces/
/api/ipam/vlans/
/api/ipam/prefixes/
/api/ipam/ip-addresses/
```

Pagination, result cardinality and schema validation matter. A partial API response cannot be treated as a clean network inventory.

## 04 / What is actually compared

| Area | Verified invariant |
|---|---|
| VLANs | Exact set of VLAN IDs on RouterOS and in the selected NetBox VLAN group |
| Prefix | RouterOS static gateway subnet on each VLAN interface matches the corresponding NetBox Prefix |
| IPv4 | Exact active static `(CIDR, interface)` pairs match |
| Completeness | Both source counts match the reviewed baseline |
| Evidence integrity | Duplicates, malformed snapshots, stale timestamps or disabled entries are explicitly handled |
| Runtime addresses | Unreviewed dynamic or disabled IPv4 entries are not silently excluded |

This is **not full RouterOS configuration equivalence**. The first version does not audit bridge filtering, access/trunk ports, PVID, VRFs, routes, DHCP or VPN health. The parent-interface name is validated but not compared against an independent NetBox parent-interface model. The VLAN comparison assumes one expected prefix per selected VLAN.

One subtlety: **a deviation from the approved object-count baseline returns `ERROR`, not `DRIFT`**. The audit treats this as incomplete or untrusted evidence. Exact record differences with otherwise complete datasets return `DRIFT`.

## 05 / Illustrative Python integration

This is an **adaptable example**, not a drop-in deployment script. Prepare verified root-only SSH identity, host-key file, NetBox token and CA certificate before use. Values use documentation-only networks and identities.

```python
from pathlib import Path
from routeros.ssh_source import RouterOSSSHReader
from routeros.ipam_sources import (
    NetBoxReader, routeros_snapshot, netbox_snapshot,
)
from routeros.ipam_audit import compare

ros_reader = RouterOSSSHReader(
    host="192.0.2.1", username="audit",
    identity_file="/etc/ipam-audit/routeros.key",
    known_hosts_file="/etc/ipam-audit/known_hosts",
)
ros = routeros_snapshot(ros_reader)

nb_reader = NetBoxReader(
    origin="https://netbox.example.net",
    token=Path("/etc/ipam-audit/netbox.token").read_text().strip(),
    ca_file="/etc/ipam-audit/trusted-ca.pem",
)
nb = netbox_snapshot(
    nb_reader, router_name="edge-router-01",
    site_slug="office", vlan_group_slug="office-vlans",
)

result = compare(ros, nb, expected_vlans=8, expected_static_addresses=12)
print(result["status"], result["differences"], result["categories"])
```

The baseline numbers `8` and `12` are fictional; replace them with independently approved quantities. A production wrapper must turn exceptions into exit code `2` without exposing credentials or private identifiers.

## 06 / Dynamic IKEv2/IPsec Mode Config addresses

During the validation, a RouterOS address with `dynamic=true` initially produced `DRIFT` in category `dynamic_review_required`. A dynamic IP is not necessarily DHCP: an IKEv2 client can install an address using **IPsec Mode Config**.

Before approving an exact exception, verify the expected peer and identity, active Phase 2, the dynamic IPsec policy containing that host address and the dynamically generated Mode Config NAT rule and connection mark. Then approve only the particular `(CIDR, interface)` pair:

```python
result = compare(
    ros, nb,
    expected_vlans=8,
    expected_static_addresses=12,
    approved_dynamic=(("198.51.100.10/24", "wan1"),),
)
```

This example is **only for an independently reviewed exception**. Current snapshots do not collect enough IPsec policy/NAT evidence to re-validate the address's provenance automatically on every run. The exception is not proof of VPN health. If the reviewed address moves or disappears, it is detected; broadly ignoring all dynamic addresses would be unsafe.

## 07 / Exit codes and result scope

| Exit | State | Meaning |
|---|---|---|
| `0` | CLEAN | Complete snapshots; checked invariants match; reviewed exceptions accounted for |
| `1` | DRIFT | Concrete differences or unexpected runtime address assignments |
| `2` | ERROR | Connection failure, malformed/stale data, baseline completeness violation or validation error |

`CLEAN` means that the explicitly modeled facts match. It **does not** mean that RouterOS and NetBox contain identical full configurations. There is no automatic repair or synchronization.

## Operational outcome

The end-to-end read-only comparison was validated and moved into a private local scheduled runner. The next step is to publish its state to a monitoring system without treating failed audits as successes. See [Prometheus monitoring for the RouterOS–NetBox IPAM audit](/notes/monitoring/routeros-netbox-ipam-prometheus-alerting/).

The durable lesson is to establish **reviewed baselines, constrained read privileges and three distinct states: CLEAN, DRIFT and ERROR** before considering remediation.