---
title: "Proxmox Backup Server: backup policy, exclusions, verification and restore testing"
description: "A production-oriented framework for defining PBS backup coverage, retention, prune and GC jobs, verification, restore drills and explicitly accepted exclusions."
category: "Storage & Backup"
tags: ["proxmox", "pbs", "backup", "restore", "retention", "verification"]
published: 2026-09-16
updated: 2026-09-16
status: current
testedOn: ["Proxmox VE 9.x", "Proxmox Backup Server 4.x", "VM and CT backups"]
featured: true
---

## Context

A backup system is not complete when scheduled jobs are green.

A production backup policy has to answer a wider set of questions:

- what must be backed up;
- what is intentionally excluded;
- how often backups run;
- how long recovery points are retained;
- when unreferenced data is actually reclaimed;
- whether stored backup data is still readable;
- whether a restore has been tested;
- what recovery risk remains accepted by design.

Proxmox Backup Server provides strong primitives for deduplicated VM and container backups, pruning, garbage collection and verification. The operational value comes from combining those primitives into an explicit policy rather than treating them as unrelated jobs.

The examples below use generic identifiers. Adapt retention and scheduling to the actual RPO, RTO, storage capacity and workload criticality.

## Start with a coverage policy

Do not begin with a retention string. Begin with workload classification.

A practical model is to assign every VM and container to one of four classes:

| Class | Typical workload | Backup expectation |
| --- | --- | --- |
| Critical | identity, databases, line-of-business services | scheduled backup, tighter RPO, frequent verification, restore drill |
| Standard | normal production servers | scheduled backup and regular verification |
| Rebuildable | automation-managed or easily recreated services | backup optional depending on rebuild cost |
| Excluded | disposable test systems, templates, archived or accepted-risk workloads | no regular backup, documented reason |

The important control is not the exact class names. The important control is that every guest has an intentional status.

An unclassified guest is not an accepted exclusion; it is an unknown.

## Keep an exclusion register

Some guests do not justify regular PBS consumption. That can be valid when the decision is explicit.

Examples include:

- short-lived test VMs;
- templates that can be recreated from installation media and documented configuration;
- non-critical appliances with immutable configuration;
- abandoned or archive-only systems;
- workloads whose recovery method is deliberately manual.

For every exclusion, record at least:

| Field | Example |
| --- | --- |
| Workload | `vm-example-test` |
| Owner / service | infrastructure team |
| Reason | disposable test system |
| Recovery method | redeploy from automation |
| Maximum accepted data loss | all local state |
| Review date | quarterly |

This turns "not in the PBS job" from an accident into a risk decision.

## Backup success is not application consistency

A successful Proxmox backup proves that the hypervisor backup operation completed. It does not automatically prove that every application inside the guest has a transactionally consistent recovery point.

For Windows and Linux guests, QEMU Guest Agent integration can improve filesystem coordination when configured and supported by the guest. Databases and other transactional systems can still require application-aware procedures, dumps, WAL/binlog retention or additional recovery controls.

Treat these as separate questions:

1. can the VM or CT be restored;
2. can the application inside it recover cleanly to the required point.

A green PBS task answers the first question better than the second.

## Define backup schedules by RPO

Avoid one universal schedule if workload requirements differ.

Example policy:

| Class | Example schedule | Approximate infrastructure RPO |
| --- | --- | --- |
| Critical | every 4 hours | up to 4 hours |
| Standard | nightly | up to 24 hours |
| Rebuildable | weekly or manual | accepted |
| Excluded | none | explicitly accepted |

The schedule should reflect recovery requirements, not simply the amount of available storage.

Before adding more backup frequency, check whether the workload and network can sustain the change without overlapping jobs or creating storage contention.

## Separate schedule from retention

Backup frequency and retention solve different problems.

A workload can run every four hours while retaining only a useful subset of historical points. PBS pruning supports retention dimensions such as:

- keep last;
- keep hourly;
- keep daily;
- keep weekly;
- keep monthly;
- keep yearly.

An example retention policy could be:

```text
keep-last:    6
keep-daily:   14
keep-weekly:  8
keep-monthly: 12
```

This is an example, not a universal recommendation. Retention must be sized against business recovery requirements and datastore capacity.

## Understand prune versus garbage collection

Pruning and garbage collection are different operations.

**Prune** removes backup snapshots according to the configured retention policy.

**Garbage collection** scans the datastore and reclaims chunks that are no longer referenced by any retained snapshot, subject to PBS safety rules around recently used chunks.

Therefore:

```text
prune != immediate space reclamation
```

A datastore can show snapshots removed by pruning while disk usage remains largely unchanged until garbage collection completes.

That distinction matters during capacity incidents.

## Inspect configured PBS jobs

On the PBS host, the current configuration can be reviewed from the CLI:

```bash
proxmox-backup-manager datastore list
proxmox-backup-manager prune-job list
proxmox-backup-manager garbage-collection list
proxmox-backup-manager verify-job list
```

The current PBS documentation exposes these job families separately, which matches the operational model: retention, space reclamation and integrity checking are independent controls.

Review job configuration as part of change control rather than assuming the GUI still reflects the original design months later.

## Design prune jobs intentionally

A prune job should have a clear relationship to backup frequency.

For example, if a standard VM is backed up nightly but only one backup per week is kept, the practical restore-point density is weekly regardless of how often the backup job runs after pruning.

When changing retention:

1. estimate how many snapshots will remain;
2. identify protected or manually important recovery points;
3. run the policy against non-critical data first if the change is substantial;
4. review the prune task result;
5. run or wait for scheduled garbage collection before evaluating reclaimed capacity.

Do not change prune and GC policy during a storage emergency without understanding which recovery points will disappear.

## Schedule garbage collection after pruning

GC is most useful after prune activity has made chunks unreferenced.

A simple operational sequence is:

```text
backup jobs -> prune -> garbage collection -> verification window
```

Exact timing depends on backup duration and datastore performance. Avoid running all heavy maintenance tasks simultaneously on the same storage if they compete for I/O.

Check current GC state with:

```bash
proxmox-backup-manager garbage-collection list
```

For a specific datastore, PBS also exposes status and manual start operations:

```bash
proxmox-backup-manager garbage-collection status <datastore>
proxmox-backup-manager garbage-collection start <datastore>
```

Use manual GC as a controlled operation, not as a reflex every time free space changes.

## Verification is an integrity control

PBS verification jobs validate stored backup data so corruption can be detected before the day a restore is needed.

List verification jobs:

```bash
proxmox-backup-manager verify-job list
```

A verification job can be run manually by ID:

```bash
proxmox-backup-manager verify-job run <job-id>
```

Verification is especially important for long-lived recovery points that may not be read again for months.

A useful policy is to verify new or recently created snapshots regularly and ensure older snapshots are reverified before their previous verification becomes operationally stale.

## Verification is not a restore test

A verified backup is stronger evidence than a backup that has never been read again, but it still does not prove the restored operating system or application will start correctly.

A restore test answers different questions:

- can the backup be located quickly;
- are permissions and credentials available;
- can the target storage accept the restore;
- does the guest boot;
- does networking come up safely in an isolated environment;
- does the application start;
- is the recovered data usable.

Treat verification and restore drills as complementary controls.

## Restore-test representative workloads

Do not wait for a real outage to discover the restore procedure.

Choose representative workloads from the critical classes, for example:

- one Windows server;
- one Linux VM;
- one container;
- one workload using large virtual disks;
- one workload whose application has its own consistency requirements.

Restore the backup under a temporary VMID or CTID and isolate networking before boot if duplicate addresses, domain membership or production services could create conflicts.

For VM restore from a backup volume, Proxmox VE supports `qmrestore`:

```bash
qmrestore <backup-volume> <temporary-vmid> --storage <target-storage>
```

The exact backup-volume identifier should be copied from the actual storage content view rather than reconstructed by hand.

After the test, remove the temporary guest only after the recovery evidence has been recorded.

## Test the recovery path, not only the data

A useful restore drill records timestamps:

```text
T0  incident declared
T1  correct backup identified
T2  restore started
T3  VM/CT restore completed
T4  guest booted
T5  application validated
```

This gives an observed recovery time rather than an assumed RTO.

If the restore is too slow, the problem may be network throughput, target storage, datastore contention, large disk size or simply an unrealistic RTO. The drill exposes that before a production outage.

## Validate backup-job coverage after infrastructure changes

Backup coverage frequently breaks because infrastructure changes faster than the backup schedule.

Common triggers for review include:

- a new VM or CT is created;
- a workload moves from test to production;
- a template becomes a long-lived server;
- a VM is migrated into another cluster;
- storage or PBS credentials change;
- an old exclusion is no longer justified.

After each significant change, ask whether the guest is in the correct backup class and job.

Do not rely on remembering to add it later.

## Monitor backup failures as service failures

A failed scheduled backup is not routine noise for a critical workload.

Investigate recurring failures by separating possible causes:

- guest lock or another running task;
- storage unavailable;
- network interruption;
- PBS authentication or permission issue;
- snapshot/guest-agent problem;
- datastore capacity pressure;
- overlapping maintenance;
- corrupted or unhealthy source storage.

Fix the cause instead of repeatedly rerunning the task until one execution becomes green.

## Capacity planning with deduplication

PBS deduplication means logical backup size and physical datastore growth are not identical.

This makes simple capacity formulas less accurate, especially for similar VMs. However, deduplication should not be treated as unlimited capacity.

Track:

- datastore physical usage;
- recent growth rate;
- GC reclaimed bytes;
- number of protected snapshots;
- large new workload introductions;
- retention-policy changes.

A datastore that depends on heroic GC runs to remain operational has a capacity-planning problem.

## Protect the backup server itself

PBS is part of the recovery path and should not share every failure domain with the protected cluster.

At minimum, consider separation of:

- management credentials;
- storage failure domain;
- network path;
- administrative access;
- monitoring and alerting.

Where the risk model requires it, add a second PBS, remote sync or offline/offsite copy. A single PBS is still a single backup-system failure domain even if the data inside it is deduplicated and verified.

## Consider offsite or second-copy recovery

A local PBS protects well against many guest and cluster failures, but it may not protect against site loss, ransomware with administrative reach or simultaneous storage destruction.

PBS supports datastore synchronization to another backup server. Whether this is required depends on the business impact and threat model.

The important distinction is:

```text
backup copy != independent disaster-recovery copy
```

Document whether offsite recovery exists. If it does not, state the residual risk explicitly.

## Accepted-risk exclusions

An exclusion is acceptable only when all of the following are true:

- the workload is identified;
- the reason is documented;
- the recovery method is known;
- the maximum data loss is understood;
- the decision has an owner;
- the exclusion is reviewed periodically.

Examples of defensible exclusions include disposable test VMs or services that can be rebuilt completely from version-controlled automation.

Examples of poor exclusions include "backup job was full" or "nobody added it yet".

## Templates and archive systems

Templates and archive-only VMs often need different treatment from production servers.

If a template is reproducible from documented installation media, cloud-init, automation and packages, manual or infrequent backup may be enough.

If an archive VM contains unique historical data, its low runtime importance does not automatically make it low backup importance.

Classify based on recoverability and data value, not CPU usage.

## Application-specific backup layers

PBS should coexist with application-native backup where the application requires it.

Examples include:

- PostgreSQL base backup plus WAL strategy;
- database dumps for portable logical recovery;
- Mailcow or application-level configuration exports where resources permit;
- directory-service-aware recovery procedures;
- file-level copy for data requiring different retention from the VM.

This is defense in depth. It does not mean every workload needs duplicate backup mechanisms.

Use application-native backup where it materially improves recovery granularity or consistency.

## A minimal operational review

A periodic PBS review should answer these questions:

```text
Are all production workloads classified?
Are exclusions still intentional?
Did scheduled backup jobs succeed?
Are prune jobs retaining the intended history?
Did garbage collection complete normally?
Are verify jobs succeeding?
Has at least one representative restore been tested recently?
Is datastore growth within expected limits?
Is the offsite/second-copy risk explicitly addressed?
```

This review is more useful than looking only at the last backup timestamp.

## Stop conditions

Stop changing retention or deleting recovery points if:

- the business owner cannot confirm which historical points are still required;
- verification is reporting unexplained failures;
- the datastore or underlying filesystem is unhealthy;
- active backup jobs are still writing to the affected datastore;
- a prune change would remove the only known-good recovery point;
- the recovery path has never been tested and the workload is critical.

During a storage-capacity incident, creating more free space is not automatically more important than preserving the only viable restore point.

## Recovery evidence to retain

For critical restore drills and real recoveries, record:

- source backup timestamp;
- PBS datastore and namespace;
- restore target;
- restore start/end time;
- boot result;
- application validation result;
- any manual steps needed;
- observed RTO;
- any data gap relative to the required RPO.

This converts recovery from tribal knowledge into an operational procedure.

## Production pattern

A practical PBS design is not complicated:

```text
classify workloads
  -> schedule backups
  -> document exclusions
  -> prune intentionally
  -> run GC
  -> verify stored backups
  -> perform restore drills
  -> review accepted risk
```

The strongest signal is not "all backup jobs are green". It is that the organization knows what is protected, what is intentionally not protected, and how long a tested recovery actually takes.

## References

- Proxmox Backup Server documentation: <https://pbs.proxmox.com/docs/>
- Proxmox Backup Server Administration Guide: <https://pbs.proxmox.com/docs/proxmox-backup.pdf>
- Proxmox VE backup and restore documentation: <https://pve.proxmox.com/pve-docs/chapter-vzdump.html>
