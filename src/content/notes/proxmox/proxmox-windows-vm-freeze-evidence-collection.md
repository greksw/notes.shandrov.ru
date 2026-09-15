---
title: "Proxmox VE: collecting evidence before rebooting a frozen Windows VM"
description: "A production incident-response runbook for preserving host, QEMU, task and storage evidence before resetting an unresponsive Windows guest."
category: "Proxmox & Virtualization"
tags: ["proxmox", "windows", "incident-response", "qemu", "troubleshooting", "forensics"]
published: 2026-09-15
updated: 2026-09-15
status: current
testedOn: ["Proxmox VE 9.x", "Windows Server guests", "systemd journal"]
featured: true
---

## Context

A frozen Windows VM creates pressure to restore service quickly, but an immediate reboot destroys some of the most useful evidence.

The right first question is not "how do I restart it?" but "what can I still capture before I change the state?"

This runbook focuses on the Proxmox side of the incident. It is designed for cases where a Windows guest becomes unresponsive or partially responsive while the Proxmox node itself is still reachable.

The examples use sanitized VM IDs and time ranges. Replace them with the actual incident data.

## Objectives

Before rebooting or resetting the guest, try to preserve evidence for these questions:

- was the failure limited to one VM or did the host show wider pressure;
- was the QEMU process still alive;
- did Proxmox record stop, reset, migration or backup tasks around the incident;
- were there OOM, hung task, blocked I/O, timeout or storage errors on the host;
- was the VM still consuming CPU or blocked in kernel I/O;
- did storage, backup or migration activity overlap the freeze;
- did the guest recover after a clean shutdown request or only after a hard reset.

Do not turn evidence collection into a long outage. The goal is a compact, repeatable capture before state is destroyed.

## First rule: record the incident window

Write down the best known start time and the time the problem was confirmed.

Example:

```text
incident_start=2026-08-03 21:30
incident_end=2026-08-03 23:00
vmid=522
node=pve-node09
```

An approximate window is still useful. It allows later comparison between user reports, Proxmox tasks, QEMU logs and host-level warnings.

Use the same time window consistently throughout the investigation.

## Confirm the VM and node

From any cluster node:

```bash
pvesh get /cluster/resources --type vm | grep -E '(^|[[:space:]])522([[:space:]]|$)'
```

On the hosting node:

```bash
qm status 522
qm config 522
```

Capture the configuration before making changes. Important details include:

- machine type;
- CPU type and vCPU count;
- memory and ballooning settings;
- storage backend and disk format;
- VirtIO/SCSI controller choice;
- network model;
- QEMU Guest Agent configuration;
- watchdog configuration, if any.

Do not assume the VM is on the node where it normally runs. Verify the current owner first.

## Capture cluster and node health

A guest freeze can be a symptom of a host or storage problem, so capture the wider platform state before focusing only on Windows.

```bash
pvecm status
pvesm status
```

If Ceph is used:

```bash
ceph -s
```

Capture basic host pressure:

```bash
uptime
free -h
df -h
```

For a quick view of scheduler and I/O pressure:

```bash
vmstat 1 5
```

If `iostat` is installed:

```bash
iostat -xz 1 5
```

The purpose is not to prove the root cause immediately. It is to preserve whether the host looked normal or overloaded at the same time as the guest failure.

## Confirm that the QEMU process still exists

A VM can appear `running` in Proxmox while its userspace process is unhealthy or waiting on a lower layer.

Locate the process:

```bash
pgrep -af 'kvm.*-id 522|qemu-system.*-id 522'
```

Or inspect the PID file:

```bash
cat /run/qemu-server/522.pid 2>/dev/null
```

Then inspect the process:

```bash
PID="$(cat /run/qemu-server/522.pid 2>/dev/null)"
ps -o pid,ppid,stat,etime,%cpu,%mem,wchan:32,cmd -p "$PID"
```

The process state and `wchan` can be useful when QEMU is blocked in kernel I/O rather than consuming CPU normally.

Do not attach debuggers or send signals as a first step unless the incident requires deeper live analysis. Start with read-only inspection.

## Capture Proxmox task history

Look for operations involving the VM around the incident window.

A cluster task query is useful for recent activity:

```bash
pvesh get /cluster/tasks --vmid 522 --limit 50
```

Look for:

- `qmstart`;
- `qmstop`;
- `qmshutdown`;
- `qmreset`;
- migration;
- backup;
- snapshot;
- storage migration;
- replication.

If a task looks relevant, record its UPID and inspect its log before rebooting the guest.

Task correlation matters because an apparent "random" freeze may line up with backup, migration or storage operations that are otherwise forgotten after service is restored.

## Search the host journal for the VM and QEMU

Use a narrow incident window first.

```bash
journalctl \
  --since '2026-08-03 21:30:00' \
  --until '2026-08-03 23:00:00' \
  --no-pager | \
grep -Ei 'VM 522|:522:|qemu.?522|qm(stop|shutdown|reset|start).*522'
```

Then search the same window for host-level failure indicators:

```bash
journalctl \
  --since '2026-08-03 21:30:00' \
  --until '2026-08-03 23:00:00' \
  --no-pager | \
grep -Ei 'watchdog|oom|out of memory|hung task|blocked for more than|i/o error|input/output error|timeout|reset|nvme|scsi|rbd|ceph|nfs|zfs'
```

Avoid searching the entire journal first. A tight window reduces unrelated noise and makes later incident review reproducible.

## Inspect kernel messages separately

Kernel-level symptoms are especially important for storage stalls, driver problems and OOM events.

For the current boot:

```bash
journalctl -k \
  --since '2026-08-03 21:30:00' \
  --until '2026-08-03 23:00:00' \
  --no-pager
```

Or filter for likely indicators:

```bash
journalctl -k \
  --since '2026-08-03 21:30:00' \
  --until '2026-08-03 23:00:00' \
  --no-pager | \
grep -Ei 'oom|hung|blocked|i/o|timeout|reset|nvme|scsi|rbd|ceph|nfs|zfs'
```

If the host itself was rebooted after the incident, inspect the previous boot with `journalctl -b -1` as appropriate.

## Check for OOM evidence

A QEMU process killed by the host OOM killer can look like a guest-side outage while the actual failure is host memory pressure.

```bash
journalctl \
  --since '2026-08-03 21:30:00' \
  --until '2026-08-03 23:00:00' \
  --no-pager | \
grep -Ei 'oom-killer|out of memory|killed process.*qemu|killed process.*kvm'
```

Also compare the VM memory configuration with current host pressure.

If ballooning is enabled, record that fact. Do not interpret the configured maximum memory as the only memory value relevant to the incident.

## Check for blocked I/O and hung tasks

Windows guests can appear frozen when QEMU is waiting on storage rather than when Windows itself has crashed.

Host evidence may include messages such as:

- task blocked for more than N seconds;
- I/O timeout;
- SCSI/NVMe reset;
- RBD/Ceph timeout;
- NFS server not responding;
- filesystem or block-device errors.

Search for these indicators in the incident window before resetting the VM.

If multiple VMs on the same datastore show similar symptoms, shift the investigation toward the storage path rather than treating each guest as an independent Windows problem.

## Check storage and backup overlap

If the VM disks reside on shared storage, record the storage backend state while the failure is still present.

For Proxmox storage:

```bash
pvesm status
```

For Ceph:

```bash
ceph -s
```

For a mounted NFS datastore:

```bash
findmnt -t nfs,nfs4
```

Check whether a backup or migration task overlapped the incident. High I/O activity is not proof of causation, but losing the timing correlation makes later analysis much weaker.

## Check the QEMU Guest Agent without depending on it

If the guest agent is configured, its responsiveness is useful evidence:

```bash
qm guest cmd 522 ping
```

Interpret the result carefully:

- agent responds: Windows or at least the agent path is still partially alive;
- agent does not respond: the guest may be hung, the agent service may be down, or the communication path may be broken.

Guest-agent failure alone is not proof that the whole VM is frozen.

## Distinguish console, network and OS failure

Before rebooting, determine what exactly is unavailable.

Useful checks include:

- Proxmox console display updates or remains frozen;
- ICMP responds or not;
- RDP port responds or not;
- application port responds or not;
- QEMU Guest Agent responds or not;
- VM CPU usage is active, idle or stuck;
- another VM on the same host/storage is healthy or affected.

This classification helps separate:

- Windows service failure;
- Windows OS hang;
- guest network failure;
- QEMU process problem;
- host/storage problem.

Do not collapse all of these into the single label "VM freeze".

## Optional: capture current QEMU status

For deeper incidents, the QEMU monitor can provide additional state, but use it carefully on production systems.

```bash
qm monitor 522
```

Read-only monitor commands can help confirm whether QEMU itself remains responsive. Avoid issuing state-changing monitor commands unless they are part of the recovery decision.

For routine incidents, host journal, task history, process state and storage health usually provide higher-value evidence with less operational risk.

## Save evidence before recovery

A small evidence directory is enough.

Example:

```bash
mkdir -p /root/incidents/vm-522-20260803
```

Save relevant command outputs there or copy them to the incident record before rebooting.

Useful artifacts are:

- `qm config`;
- `qm status`;
- cluster and storage status;
- QEMU PID/process state;
- filtered host journal;
- filtered kernel journal;
- task history;
- relevant task logs;
- exact recovery action and timestamp.

Avoid collecting secrets, guest memory dumps or unrelated configuration unless the incident specifically requires them.

## Decide between shutdown, stop and reset

Use the least destructive recovery action that still restores service.

If the guest agent and Windows are responsive enough, attempt a normal shutdown first:

```bash
qm shutdown 522 --timeout 60
```

If that fails and service impact requires recovery, the next action depends on the state and operational risk.

A hard stop or reset destroys guest-side runtime evidence and can create filesystem/application recovery work. That may still be necessary, but it should be a deliberate incident decision rather than the first diagnostic step.

Record exactly which command was used.

## After recovery: preserve the timeline

Once the VM is running again, do not stop at "service restored".

Record:

- freeze detection time;
- evidence collection window;
- recovery command and time;
- VM boot time;
- application recovery time;
- whether Windows Event Logs show a crash, unexpected shutdown or storage/network event;
- whether the same host or storage showed related symptoms.

The timeline is often more valuable than any single log line.

## Windows-side follow-up

After the guest is reachable, collect Windows evidence before normal event retention overwrites it.

Useful sources include:

- System event log;
- Application event log;
- unexpected shutdown events;
- storage/controller warnings;
- NTFS/ReFS events;
- service-specific failures;
- Windows Error Reporting or crash dump data, if configured;
- performance monitoring data, if available.

Correlate Windows timestamps with the Proxmox host timeline. Time synchronization matters; a few minutes of clock drift can create false sequencing.

## Compare with other affected VMs

If more than one VM froze during the same period, build a comparison table rather than analyzing each one in isolation.

Useful columns are:

| Field | Example |
| --- | --- |
| VM ID | `522` |
| node | `pve-node09` |
| storage | `shared-rbd` |
| freeze time | `21:42` |
| QEMU alive | yes |
| guest agent | no response |
| host OOM | no |
| I/O warnings | yes/no |
| overlapping backup | yes/no |
| recovery action | reset |

Patterns become visible quickly when incidents are compared this way.

Three frozen Windows VMs on different nodes but the same storage path point in a different direction from three unrelated guest OS failures.

## Avoid weak conclusions

Do not conclude "Windows froze" solely because RDP stopped responding.

Do not conclude "Proxmox issue" solely because the VM recovered after `qm reset`.

Do not conclude "storage problem" solely because a backup was running.

Each of those is a hypothesis. Preserve evidence first, then correlate timing and scope.

## Minimal fast-response checklist

When outage pressure is high, capture at least this before rebooting:

```bash
qm status 522
qm config 522
pvecm status
pvesm status
pgrep -af 'kvm.*-id 522|qemu-system.*-id 522'
pvesh get /cluster/tasks --vmid 522 --limit 30
journalctl --since '-30 min' --no-pager | grep -Ei '522|qemu|oom|hung|blocked|i/o|timeout'
```

Then record the recovery action and exact timestamp.

This takes minutes and preserves substantially more diagnostic value than an immediate reset.

## Stop conditions

Do not continue guest-level troubleshooting if evidence shows a wider infrastructure failure, for example:

- multiple VMs affected on the same host;
- multiple VMs affected on the same datastore;
- host OOM activity;
- kernel hung-task or blocked-I/O warnings;
- Ceph degraded/inactive state;
- NFS timeout or server-not-responding messages;
- repeated QEMU I/O errors;
- cluster or Corosync instability.

At that point, protect the broader platform and treat the VM freeze as a symptom.

## Operational notes

The best incident script is not the one that collects the most data. It is the one operators can run safely under pressure without changing system state.

Keep command blocks short, capture a narrow time range and separate evidence collection from recovery actions.

A reboot can restore availability while simultaneously removing the only evidence that explains why the failure happened. Preserving a few minutes of host-side state before recovery is usually worth the effort.
