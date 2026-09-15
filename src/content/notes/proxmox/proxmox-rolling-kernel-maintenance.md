---
title: "Proxmox VE: rolling kernel maintenance with one-boot fallback"
description: "A production-oriented runbook for changing the kernel across a multi-node Proxmox VE cluster while preserving quorum, evacuating workloads and retaining a fast rollback path."
category: "Proxmox & Virtualization"
tags: ["proxmox", "kernel", "cluster", "maintenance", "quorum", "rollback"]
published: 2026-09-15
updated: 2026-09-15
status: current
testedOn: ["Proxmox VE 9.2.x", "9-node cluster", "UEFI/GRUB"]
featured: true
---

## Context

Kernel maintenance on a Proxmox VE cluster is not mainly an `apt` task. The risky part is changing the booted kernel while keeping cluster quorum, guest availability, storage access and an immediate recovery path under control.

The pattern here was developed around a nine-node production cluster and is intentionally conservative: one node is changed at a time, the target kernel is verified before reboot, workloads are moved away from the node, the first reboot is treated as a canary, and the previous kernel remains available through GRUB.

The same workflow works for a normal kernel rollout and for intentionally testing a different known-good kernel after a regression. The version number itself is not the control; the health gates around the reboot are.

## Maintenance invariants

Do not start the next node until all of these are true for the node that just returned:

- the cluster is quorate;
- the expected node count is restored;
- Corosync and Proxmox management services are healthy;
- the intended kernel is actually running;
- guest and storage state is normal;
- no new critical systemd failures appeared;
- the rollback kernel is still present.

This is a rolling maintenance operation. Never schedule multiple node reboots in parallel simply because the cluster has enough votes on paper.

## Example target kernel

Use a variable instead of repeating a version in every command:

```bash
TARGET_KERNEL="6.17.13-21-pve"
```

The example is intentionally a specific tested target. Replace it with the kernel selected for the actual maintenance window.

## Cluster preflight

Start from a healthy cluster, not from a cluster that is already degraded.

```bash
pvecm status
```

Confirm at minimum:

- `Quorate: Yes`;
- the expected number of nodes is present;
- votes and quorum are consistent with the design;
- no node is unexpectedly offline.

For a nine-node cluster, one planned node outage still leaves a wide voting margin, but quorum arithmetic is only one dependency. Shared storage, HA state and running workloads must also be healthy.

If HA is used:

```bash
ha-manager status
```

If Ceph is part of the cluster:

```bash
ceph -s
```

If external storage is used:

```bash
pvesm status
```

Stop the maintenance window if Ceph already has unexpected degraded/inactive placement groups, required storage is unavailable, or HA is already recovering unrelated workloads.

## Select a canary node

Do not begin with the most operationally sensitive host. Pick a node whose workloads can be migrated cleanly and whose failure would not create a second incident.

Before evacuation, record the local guest set:

```bash
qm list
pct list
```

For HA-managed resources, verify their current state before moving anything. For ordinary VMs and containers, migrate them using the normal Proxmox migration workflow. The exact command depends on storage and guest type, so the important validation is the end state: the maintenance node should not retain production workloads that would be interrupted by reboot unless that interruption is explicitly accepted.

After migration, re-check the node and the cluster task log. Do not reboot while backup, replication, storage migration or another administrative task is still active.

## Node preflight

On the selected node, capture its current state before changing boot behavior:

```bash
hostname -s
date
uptime
pveversion
uname -r
```

Verify that the target kernel is actually installed and has boot artifacts:

```bash
test -s "/boot/vmlinuz-${TARGET_KERNEL}"
test -s "/boot/initrd.img-${TARGET_KERNEL}"
```

Then inspect the boot layout:

```bash
findmnt /boot/efi || true
proxmox-boot-tool status || true
```

A node that boots through GRUB does not necessarily use `proxmox-boot-tool` to synchronize EFI System Partitions. On such systems, `proxmox-boot-tool status` can report that `/etc/kernel/proxmox-boot-uuids` does not exist. That is not by itself a kernel-maintenance failure; it means the boot path must be understood before applying ESP-specific commands.

Check the core cluster services:

```bash
systemctl is-active pve-cluster
systemctl is-active corosync
systemctl is-active pvedaemon
systemctl is-active pveproxy
systemctl is-active pvestatd
```

And record existing failed units so that old failures are not mistaken for a regression after reboot:

```bash
systemctl --failed --no-pager
```

## Preserve the rollback path

Do not purge the previously working kernel before the rollout is complete.

The safest first test is a one-boot pin:

```bash
proxmox-boot-tool kernel pin "${TARGET_KERNEL}" --next-boot
```

Proxmox documents `--next-boot` specifically for booting a selected kernel once. This is useful because the one-time pin is cleared automatically after that boot rather than changing the long-term default indefinitely.

On nodes whose EFI System Partitions are managed by `proxmox-boot-tool`, synchronize after changing the pin:

```bash
proxmox-boot-tool refresh
```

Do not run bootloader maintenance mechanically across mixed boot layouts. Inspect each node first.

Before reboot, verify once more that both the target and the previous known-good kernel remain installed under `/boot`.

## Final pre-reboot gate

Immediately before rebooting the canary node, repeat the checks that can change quickly:

```bash
pvecm status
ha-manager status
pvesm status
```

If Ceph is used:

```bash
ceph -s
```

Also confirm that the node is evacuated and that no administrative task is still running.

The decision point is simple: if the cluster is not in the same healthy state as at the start of the window, do not reboot.

## Reboot one node

Reboot only the selected node:

```bash
reboot
```

Monitor the node through an independent path if possible. For a kernel change, access to IPMI, iKVM, a hypervisor console or a physical console is more valuable than another SSH session because a bootloader or early-kernel failure can happen before networking is available.

Do not touch the next node while the canary is booting.

## Post-boot validation

Once SSH or the console is available, verify the actual running kernel first:

```bash
uname -r
```

It must match the intended target:

```bash
[ "$(uname -r)" = "${TARGET_KERNEL}" ]
```

Then repeat the service checks:

```bash
systemctl is-active pve-cluster
systemctl is-active corosync
systemctl is-active pvedaemon
systemctl is-active pveproxy
systemctl is-active pvestatd
systemctl --failed --no-pager
```

From a cluster member, verify quorum and membership again:

```bash
pvecm status
```

If HA, Ceph or external storage are used, repeat the same checks from preflight:

```bash
ha-manager status
pvesm status
ceph -s
```

Only after infrastructure health is confirmed should workloads be returned to the node or new migrations be started.

## Validate real workloads

A node being visible in the GUI is not sufficient evidence that the maintenance succeeded.

Check representative workloads that exercise the paths relevant to the cluster:

- at least one VM with normal network and storage I/O;
- any latency-sensitive or Windows workload that previously exposed kernel regressions;
- storage-backed workloads if Ceph/NFS/PBS connectivity is important;
- HA-managed resources if HA is enabled.

For individual guests:

```bash
qm status <vmid>
pct status <ctid>
```

Use application-level checks as well where practical. A guest being `running` does not prove that its network, filesystem or service stack is healthy.

## Continue node by node

After the canary has remained stable for the chosen observation period, repeat the same sequence for the next node:

1. verify cluster health;
2. evacuate the node;
3. verify target boot artifacts and rollback kernel;
4. set the one-boot target;
5. reboot only that node;
6. validate kernel, services, quorum, storage and workloads;
7. continue only when the node is fully healthy.

The process should be boring and repetitive. That is desirable. A rolling maintenance window is not the place to optimize away safety checks.

## Rollback: target kernel boots but is unstable

If the node boots successfully but the new kernel causes runtime problems, evacuate workloads again before the recovery reboot.

If the previous known-good kernel is still installed, select it for the next boot:

```bash
PREVIOUS_KERNEL="<known-good-kernel>"
proxmox-boot-tool kernel pin "${PREVIOUS_KERNEL}" --next-boot
```

Refresh only when the node uses `proxmox-boot-tool`-managed ESPs, then reboot the node and repeat the full post-boot validation.

Do not roll the problematic kernel to additional nodes while the canary is under investigation.

## Rollback: target kernel does not boot

If the node cannot reach userspace or networking, remote shell commands are no longer a recovery mechanism.

Use the console and select the previous kernel from **GRUB → Advanced options for Proxmox VE**. This is why the old kernel must remain installed until the rollout is proven.

Because `--next-boot` is a one-time selection, it does not permanently replace the normal default kernel. After recovering the node, inspect the failed boot before attempting another rollout.

Useful evidence includes:

```bash
journalctl -b -1 -k
journalctl -b -1 -p warning..alert
```

The previous boot journal can reveal driver, storage, filesystem, networking or hardware initialization failures that are invisible after simply returning to the old kernel.

## Stop conditions

Abort the rollout rather than continuing automatically if any of the following appears:

- quorum is lost or unstable;
- Corosync membership is inconsistent;
- required storage becomes unavailable;
- Ceph develops unexpected degraded/inactive state;
- HA starts recovering unrelated resources;
- the node returns on the wrong kernel;
- core Proxmox services fail;
- representative workloads show new errors;
- the rollback kernel or console path is no longer available.

A maintenance procedure should define when to stop, not only how to continue.

## Why one-boot pinning is useful

A permanent kernel pin is sometimes appropriate, but it is a poor default for a first cluster-wide test.

A one-boot pin provides a controlled experiment:

- the intended kernel is explicit;
- the existing default is not permanently replaced;
- the previous kernel remains available in GRUB;
- a canary can be evaluated before the next node is touched.

Proxmox also supports permanent pinning and `kernel unpin`, but those should be deliberate lifecycle decisions rather than an accidental side effect of a maintenance window.

## Operational notes

Keep the preflight and post-boot commands identical wherever possible. Comparing the same signals before and after reboot makes regressions easier to identify.

Record the kernel actually running on every node rather than assuming package installation means rollout completion. A cluster can easily end a maintenance window with different installed and booted kernels if a node was skipped or booted the wrong GRUB entry.

For large clusters, maintain a simple node checklist with states such as `pending`, `evacuated`, `rebooted`, `validated` and `complete`. The checklist matters more than clever automation when the operation contains deliberate human stop/go decisions.

## References

- Proxmox VE Administration Guide: <https://pve.proxmox.com/pve-docs/pve-admin-guide.pdf>
- Proxmox VE Cluster File System documentation: <https://pve.proxmox.com/pve-docs/chapter-pmxcfs.html>
