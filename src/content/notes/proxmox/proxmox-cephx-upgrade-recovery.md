---
title: "Upgrading a three-node Proxmox VE cluster and migrating CephX to aes256k"
description: "A Proxmox VE 9.2 and Ceph Squid 19.2.7 upgrade case covering Corosync quorum loss, OSD recovery, old RBD sessions, and the warning that survived CephX key rotation."
category: "Proxmox & Virtualization"
tags: ["proxmox", "ceph", "cephx", "corosync", "rbd", "quorum"]
published: 2026-11-15
updated: 2026-11-17
status: current
testedOn: ["pve-manager 9.2.26", "Ceph Squid 19.2.7", "Linux 7.0.14-28-pve", "3 nodes"]
lang: en
translationKey: "proxmox/proxmox-cephx-upgrade-recovery"
---

On November 13, 2026, one node of a three-node Proxmox VE cluster temporarily saw only its own vote after an upgrade. Corosync lost links to both peers, HA waited for quorum, and Ceph reported clock skew, an unavailable OSD, and old CephX keys at the same time. Connectivity and redundancy had to come back first. During key rotation, the next job was refreshing RBD clients that still held the previous key.

The upgrade logs recorded pve-manager 9.2.26, kernel 7.0.14-28-pve, and Ceph Squid 19.2.7. The cluster had three monitors, one OSD per node, and 33 placement groups (PGs). Guest disks were on RBD.

## What surfaced after the upgrade

| Symptom | What the checks showed |
| --- | --- |
| Corosync saw one vote out of three, KNET logged `has no active links` for both peers, and `pve-ha-crm` entered `wait_for_quorum` | KNET later logged `link: 0 is up` for both peers. Membership returned to three nodes, followed by another brief departure and rejoin. The underlying cause of the link loss remains unknown. |
| Two monitors reported about 0.46 seconds of `clock skew` | The `chronyd` log recorded selection of a time source. A subsequent `ceph health detail` snapshot no longer showed the clock warning. |
| One OSD was `down` and 33 PGs were `degraded` | The startup logs showed OSD activation through `ceph-volume`. The OSD tree later showed all three up, and `ceph -s` confirmed three `up/in` and 33 `active+clean` PGs. The PG state confirmed that redundancy had recovered. |
| `ceph-crash` received `Permission denied` when reading the administrative keyring under `/etc/pve/priv` | The migration helper rotated the `client.crash` key. Successful crash-report submission still requires a separate check of the service log. |

Corosync and Ceph maintain independent quorums. `pvecm status` reports the votes that Proxmox cluster management and HA depend on. `ceph quorum_status` reports monitor membership. The OSD and PG states show storage redundancy. The following commands capture those states after a node boots.

```bash
pveversion
uname -r
pvecm status
ha-manager status
ceph versions
ceph quorum_status -f json | jq '{quorum_names, quorum_leader_name}'
ceph -s
ceph health detail
ceph osd tree
```

Ceph Squid 19.2.6 introduced checks for older CephX key and ticket types following the fix for CVE-2025-30156. The migration changed the cipher used for authentication keys and service tickets. The format and contents of the RBD volumes stayed intact.

## How the CephX rotation proceeded

1. **Cluster-owned keys and new tickets.** With quorum and redundancy restored, we reviewed the plan from the standard `/usr/share/pve-manager/migrations/pve-cephx-rotate-service-keys` helper. On one node, we applied `--rotate-cluster-keys --apply`. The phase covered monitors, managers, OSDs, bootstrap identities, and the crash identity. Monitors restarted one by one and rejoined quorum. All three OSDs accepted the new key type without a restart during this phase. New service tickets switched to `aes256k`.
2. **The `client.admin` key.** We staged the new key alongside the previous one. Monitors accepted both while clients were being refreshed. The helper initially showed ten `client.admin` sessions using the previous key across the three nodes. Its VM and RBD hints helped locate consumers. Session counts refer to monitor connections, while VM hints apply to the host as a whole.
3. **Refresh RBD clients.** During the maintenance window, we fully stopped and started four running VMs and one LXC container. Two VMs that were already down stayed down. A full stop released the previous RBD connections. Rebooting inside a VM can leave the QEMU process and its key in place. Proxmox also documents live migration for a compatible VM when the destination has the updated keyring. An LXC container on RBD needs a full stop and start.
4. **Confirm the new key and restrict ciphers.** After checking the remaining sessions, `--confirm-all-clients-refreshed` promoted the new `client.admin` key and retired the previous one. After `--restrict-ciphers`, monitors accepted only `aes256k`. Where disconnected or external clients exist, check them and their keyring copies before this step. The helper observes sessions visible to the monitors.

Inspect the migration plan and cipher settings in the monitor map:

```bash
/usr/share/pve-manager/migrations/pve-cephx-rotate-service-keys
ceph mon dump -f json | jq '{auth_allowed_ciphers, auth_service_cipher}'
```

## Why HEALTH_WARN survived cipher enforcement

After rotation, all three OSDs were `up/in`, all 33 PGs were `active+clean`, and persistent keys and new service tickets had moved to `aes256k`. At the November 13 check at 23:53 UTC+03:00, all three monitors were in quorum. `AUTH_INSECURE_ROTATING_SERVICE_KEY_TYPE` remained for four service groups with old temporary keys: `mon`, `mds`, `osd`, and `mgr`.

Monitors retain several generations of temporary service keys to handle previously issued tickets. `auth_service_ticket_ttl` was 3,600 seconds on this cluster. Generations expire in sequence, so the warning can persist for several hours. We chose to let the old generations expire. Forcing a reset invalidates previously issued tickets.

```bash
ceph config get mon auth_service_ticket_ttl
ceph health detail
ceph -s
```

### Follow-up check on November 17

The Ceph dashboard showed `HEALTH_OK` with no warnings or errors. All three monitors appeared healthy, all three OSDs were `up/in`, and all 33 PGs were `active+clean`. The warning about temporary CephX keys had cleared.

## References and related notes

- [Proxmox VE: CephX Key Migration](https://pve.proxmox.com/pve-docs/chapter-pveceph.html#pveceph_cephx_migration)
- [Ceph Squid: CephX configuration and key rotation](https://docs.ceph.com/en/squid/rados/configuration/auth-config-ref/#upgrading-and-rotating-cephx-keys)
- [Ceph: rotating service key health check](https://docs.ceph.com/en/umbrella/rados/operations/health-checks/#auth-insecure-rotating-service-key-type)
- [General Ceph key migration procedure](/notes/storage/ceph-auth-aes256k-migration/)
- [Rolling Proxmox VE kernel maintenance](/notes/proxmox/proxmox-rolling-kernel-maintenance/)
