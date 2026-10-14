---
title: "Automated software deployment and updates with GPO: PowerShell, MSI and SHA256 using 7-Zip"
description: "A production case study of rolling out 7-Zip 26.04 with Group Policy Preferences, scheduled tasks, SYSVOL, manifest.json, SHA256 verification and PowerShell."
category: "Windows"
tags: ["active-directory", "gpo", "group-policy-preferences", "powershell", "scheduled-tasks", "7-zip", "msi", "sysvol", "dfsr", "automation"]
published: 2026-10-14
updated: 2026-10-14
status: current
testedOn: ["Active Directory Domain Services", "Windows 10/11", "Windows Server", "PowerShell 5.1", "Group Policy Preferences", "7-Zip 26.04"]
featured: false
lang: en
translationKey: "windows/gpo-software-deployment-7zip-auto-update"
---

## Objective and outcome

We needed to install and update 7-Zip centrally on Active Directory workstations and terminal servers, without logging into every PC and without depending on an interactive user session. Some endpoints are powered off overnight, while Windows Installer operations may already be in progress. Running the same deployment twice must not reinstall a current version.

In October 2026 we implemented **GPO → Scheduled Task → PowerShell → manifest.json → verified MSI**. Tests confirmed an upgrade from **7-Zip 26.03 to 26.04**. Several rollout faults were diagnosed and fixed, including missing GPO scope, incorrect SHA256 data and inconsistent SYSVOL/NETLOGON content across domain controllers.

**Anonymization:** real domain names, GPO names, computers, OUs, and IP addresses are not published. The names `ad.example.com`, `PC-A`, `PC-B`, `Corp-7Zip-AutoUpdate`, and `Corp-7Zip-Install-Now` are placeholders. The snippets are **adapted illustrations** of the design, not verbatim copies of the production `Install-7Zip.ps1`.

## Why a scheduled task instead of MSI assignment

Classic **Group Policy Software Installation** supports MSI assignment. Here, however, we needed an explicit retry schedule, our own version/hash checks, detailed local logs, and coordination between an immediate-install task and a recurring task. Therefore **GPO creates the task**, and a PowerShell installer runs as `NT AUTHORITY\SYSTEM`.

```text
              Active Directory / GPO scoped to computer OU
                                 |
                                 v
                    Group Policy Preferences
                                 |
                        Scheduled Task (SYSTEM)
                                 |
                                 v
                     Install-7Zip.ps1 (NETLOGON)
                         |         |         |
                         |         |         +--> Global mutex
                         |         +------------> manifest.json / SHA256
                         +----------------------> installed version
                                 |
                                 v
                        msiexec /i /qn /norestart
                                 |
                                 v
                         deploy.log / exit code
```

This is a pragmatic model for **managed MSI rollout**, not a complete endpoint-management platform. For large packages, complex dependencies or thousands of clients, a dedicated package share/repository or endpoint-management agent may be more suitable.

## 1. Package repository

The pilot used a directory accessible to domain computers through `NETLOGON`:

```text
\\ad.example.com\NETLOGON\Software\7Zip\
├── manifest.json
├── 7z2604-x64.msi
├── 7z2604.msi
└── Scripts\
    └── Install-7Zip.ps1
```

For version 26.04, the x64 MSI `7z2604-x64.msi` was **2,009,088 bytes**, and the x86 MSI `7z2604.msi` was **1,574,400 bytes**. Each package had a recorded SHA256 hash. An initial deployment failure was caused by invalid/placeholder hashes in the manifest — an important example of why integrity checks must fail closed.

Illustrative manifest schema (**not a literal copy** of the production file; the PowerShell parser must match the chosen format):

```json
{
  "Version": "26.04",
  "Packages": {
    "x64": {"File": "7z2604-x64.msi", "SHA256": "<full, trusted SHA256>"},
    "x86": {"File": "7z2604.msi", "SHA256": "<full, trusted SHA256>"}
  }
}
```

Grant **read-only access to domain computers** and limit modification of the script, MSI and manifest to authorized administrators. `NETLOGON` data is replicated through SYSVOL, which is appropriate for modest content but can make large installers expensive to replicate. A separate read-only SMB repository is generally better at scale.

## 2. Installer responsibilities

A reliable script needs more than a call to `msiexec`:

1. Acquire a cross-process named mutex before doing any installation work.
2. Load the manifest from a controlled UNC location and choose x64/x86 based on OS architecture.
3. Discover the installed product version from registry uninstall entries; avoid using `Win32_Product` for routine inventory.
4. Skip installation if the current version is equal to or newer than the target.
5. Check the selected MSI path, expected size (if supplied), and **SHA256 before execution**.
6. Run Windows Installer silently, log the result locally and return a meaningful process exit code.

An illustrative integrity check:

```powershell
$expected = [string]$package.SHA256
if ($expected -notmatch '^[0-9a-fA-F]{64}$') {
    throw 'Invalid expected SHA256 in manifest'
}
$actual = (Get-FileHash -LiteralPath $msiPath -Algorithm SHA256).Hash
if ($actual -ine $expected) {
    throw "SHA256 mismatch: $msiPath"
}
```

Version values may be rendered as `26.04` or `26.4` depending on the parser. Do not compare them lexicographically; normalize numeric versions first.

The pilot used a shared mutex name, illustrated here as `Global\Corp-7Zip-Deploy`, across both tasks. Mutex ownership must be released in `finally`, and timeouts must be handled. This protects **our own deployment tasks**, not arbitrary concurrent MSI installations by other services; Windows Installer can still return `1618`.

After verifying package integrity and installed version, an illustrative installer call is:

```powershell
$msiLog = 'C:\ProgramData\Corp\7Zip\msi-install.log'
$args = '/i "{0}" /qn /norestart /L*v "{1}"' -f $msiPath, $msiLog
$result = Start-Process -FilePath 'msiexec.exe' -ArgumentList $args -Wait -PassThru
switch ($result.ExitCode) {
    0    { 'Installed successfully' }
    3010 { 'Installed, reboot required' }
    default { throw "MSI exit code: $($result.ExitCode)" }
}
```

**Security note:** `-ExecutionPolicy Bypass` is not a trust or integrity control. Use write permissions, a controlled package supply chain, SHA256 validation, and code signing where appropriate. If an attacker can replace both the MSI and the manifest, a hash stored beside the package does not provide independent authenticity.

## 3. GPO and scheduled task

Link the policy to the **computer OU**, not the OU of interactive users. One real rollout issue was precisely that the GPO had not been linked to the target workstation OU. Once linked to the equivalent of `OU=Workstations`, the task began appearing after computer policy refresh.

In Group Policy Management Editor:

```text
Computer Configuration
  > Preferences
    > Control Panel Settings
      > Scheduled Tasks
```

| Setting | Pilot configuration |
| --- | --- |
| Task | `Corp-7Zip-AutoUpdate` |
| Principal | `NT AUTHORITY\SYSTEM`, highest privileges |
| Action | `powershell.exe` plus noninteractive script arguments |
| Schedule | Daily at 03:00 |
| Random delay | Up to 1 hour to spread load |
| Script path | `\\ad.example.com\NETLOGON\Software\7Zip\Scripts\Install-7Zip.ps1` |

Action arguments:

```text
-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "\\ad.example.com\NETLOGON\Software\7Zip\Scripts\Install-7Zip.ps1"
```

An optional initial-install task, shown as `Corp-7Zip-Install-Now`, used the **same script and mutex**. The two schedules must never implement two conflicting installers. If machines might be off during the daily window, consider enabling missed-run catch-up and/or a startup trigger after piloting to avoid indefinite delays.

A task running under `SYSTEM` usually accesses network shares using the **computer account**. Verify share and NTFS read permissions for domain computers, not only for the administrator testing interactively.

## 4. Client validation

Run from an elevated PowerShell console on a test workstation:

```powershell
gpupdate /target:computer /force
gpresult /scope computer /r

Get-ScheduledTask -TaskName 'Corp-7Zip-AutoUpdate' |
    Select-Object TaskName, State
Get-ScheduledTaskInfo -TaskName 'Corp-7Zip-AutoUpdate' |
    Select-Object LastRunTime, NextRunTime, LastTaskResult

Start-ScheduledTask -TaskName 'Corp-7Zip-AutoUpdate'
Get-Content 'C:\ProgramData\Corp\7Zip\deploy.log' -Tail 40
```

`Start-ScheduledTask` is **asynchronous**. Wait for the task to finish before interpreting its new return code; confirm the product version and local logs separately. The task merely being in the `Ready` state does not prove installation happened.

`LastTaskResult = 267011` is decimal for `0x41303`: **the task has not yet run**, not an MSI failure. Conversely, a return code of `0` only proves the launched process returned success; the script must propagate installation errors properly rather than swallowing them.

## 5. Troubleshooting from the actual rollout

| Symptom | Diagnosis | Resolution |
| --- | --- | --- |
| `Corp-7Zip-AutoUpdate` missing on PC-A | GPO did not apply to the computer OU | Linked GPO to `OU=Workstations`; refreshed policies and checked after reboot if necessary |
| Task was `Ready` but no install | No scheduled execution yet / machine unavailable overnight | Manual pilot test and separate initial-install task |
| `LastTaskResult = 267011` | Scheduler reports no prior run | Inspected next/last run timestamps; tested execution |
| `Invalid SHA256` | Manifest contained invalid hash data | Calculated hashes for the actual MSI packages and corrected manifest |
| Different scripts on two DCs | SYSVOL/NETLOGON file replication had not converged | Compared both DC copies, checked replication and verified matching hashes afterward |
| Permission error reading task details | Client test lacked elevated privileges | Repeated checks from an elevated shell |
| Two potential simultaneous install tasks | Initial-install and daily tasks could overlap | Shared named mutex and Windows Installer exit-code handling |

On the AD side, these are useful checks:

```powershell
repadmin /replsummary
repadmin /showrepl *
```

However, **repadmin checks AD replication, not SYSVOL file replication itself**. Compare actual script sizes/hashes on every DC and check DFSR state and event logs. In the pilot the inconsistent script copies were approximately **2,181 bytes versus 3,693 bytes**.

An anonymized comparison snippet:

```powershell
$relative = 'NETLOGON\Software\7Zip\Scripts\Install-7Zip.ps1'
'dc01.ad.example.com', 'dc02.ad.example.com' | ForEach-Object {
    $path = '\\' + $_ + '\' + $relative
    [pscustomobject]@{
        Server = $_
        Length = (Get-Item -LiteralPath $path).Length
        SHA256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
}
```

## 6. Results, limits and rollback

After fixing GPO targeting, hash metadata and differences between DC copies, version **26.04** was confirmed on pilot workstations. Some clients needed a policy refresh, reboot or first manual start. Later, clients without direct manual intervention also successfully installed the update. Local logs recorded `MSI exit code: 0` and subsequent `Already current: 26.4` messages.

This is **not proof that every machine in the domain is compliant**. A full rollout requires centralized software inventory and collection of errors across all target hosts.

Before broad production rollout, establish a pilot OU, validate x86/x64 packages, verify UNC access for computer accounts, plan repository availability, define log retention and monitoring, and document rollback. Simply changing a manifest version does **not guarantee MSI downgrade**.

**Takeaway:** GPO delivers and schedules the workload; operational reliability comes from an idempotent installer, trusted packages, verifiable logs and healthy directory and file replication.

## References

- [Microsoft Learn: Get-FileHash](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/get-filehash?view=powershell-5.1)
- [Microsoft Learn: Windows Installer error codes](https://learn.microsoft.com/en-us/windows/win32/msi/error-codes)
- [Microsoft Learn: Task Scheduler error/success constants](https://learn.microsoft.com/en-us/windows/win32/taskschd/task-scheduler-error-and-success-constants)
- [7-Zip official website](https://www.7-zip.org/)