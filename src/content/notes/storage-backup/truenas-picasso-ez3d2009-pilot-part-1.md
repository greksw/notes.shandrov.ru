---
title: "Picasso Viewer and Ez3D2009 on TrueNAS: centralized CBCT storage pilot (Part 1)"
description: "Field report: CBCT/DICOM on ZFS and SMB, SHA-256 verification of 1,939 files, three Windows 11 clients, and intermittent Ez3D2009 ProjectFile errors investigated with Process Monitor."
category: "Storage and Backup"
tags: ["truenas", "zfs", "smb", "windows-11", "active-directory", "dicom", "cbct", "picasso-viewer", "ez3d2009", "powershell", "sysinternals", "procmon", "troubleshooting"]
published: 2026-10-30
updated: 2026-10-30
status: lab
testedOn: ["TrueNAS SCALE", "ZFS RAIDZ2 (SSD)", "Windows 11", "Picasso Viewer 4.0.42", "Ez3D2009 1.2.6.22 / 1.2.6.33", "SMB", "PowerShell 5.1", "Sysinternals Process Monitor"]
featured: false
lang: en
translationKey: "storage-backup/truenas-picasso-ez3d2009-pilot-part-1"
---

## Scope and outcome

The goal was to test central storage for dental cone-beam CT (CBCT) studies while retaining the existing Picasso Viewer and Ez3D2009 workflows on domain-joined Windows workstations. A primary constraint was preserving live local databases throughout the pilot.

**Status as of October 30, 2026:** all three pilot studies opened from the central SMB share on **two workstations**, including concurrent viewing. On a third workstation, the same studies could open successfully but intermittently produced `Can not open ProjectFile`. Process Monitor proved a temporary CSV sharing conflict between Ez3D2009 processes, but the **root cause of the intermittent failures remains unproven**. No production-wide migration was performed.

Hostnames, domain, share, and paths in the examples are placeholders. No patient records, DICOM headers, actual network addresses, license keys, or original trace files are published.

## 01 / Architecture

| Item | Tested configuration |
|---|---|
| Storage | TrueNAS SCALE, SSD-backed ZFS RAIDZ2 |
| Compression | ZFS `lz4` |
| NAS uplink | 10 GbE |
| Clients | Three Active Directory Windows 11 workstations on 1 GbE |
| Access | Read-only SMB for the pilot users through an AD group |
| Viewer | Picasso Viewer 4.0.42 |
| Imaging application | Ez3D2009 1.2.6.22 / 1.2.6.33 |

```text
                  Active Directory
                         |
                    TrueNAS SCALE
                   SSD / ZFS RAIDZ2
                         |
                   Read-only SMB
                         |
           +-------------+-------------+
           |             |             |
        WIN-01        WIN-02        WIN-03
        Windows       Windows       Windows
           |             |             |
       Picasso       Picasso       Picasso
        Viewer        Viewer        Viewer
           |             |             |
        Ez3D2009      Ez3D2009      Ez3D2009
        PASSED        PASSED       INTERMITTENT
```

An example SMB location is `\\nas.example.local\CBCT-ReadOnly$\Picasso`. Picasso Viewer was configured to retain the network path, avoid automatic deletion, and download manually. SMB permissions and AD-group membership were tested in the users' real sign-in sessions.

Read-only viewing is **not** a complete acquisition or archival workflow. Imports from imaging equipment, write permissions, audit trails, independent backups and recovery need separate designs.

## 02 / Study set and integrity verification

The pilot used three CBCT studies:

| Metric | Value |
|---|---:|
| DICOM files (`.dcm`) | 1,936 |
| Project files (`.npj`) | 3 |
| **Total files** | **1,939** |
| Logical size | **2.46 GiB** |
| ZFS space used with `lz4` | approximately **1.86 GiB** |

The originals and independent backups were preserved. Client-side local databases were not deleted; a temporarily renamed local dataset was restored and checked against a recorded file manifest.

A SHA-256 comparison of the source tree and central copy reported **1,939 matching files, zero missing, zero extra, and zero changed**. The audit was repeated after the same study had been accessed concurrently from two computers: no differences were detected.

Checksums matter here: matching names and sizes alone do not prove that image or project contents are intact. Avoid publishing file manifests or DICOM metadata; their paths may contain patient-identifying information.

## 03 / Client results

| Scenario | WIN-01 | WIN-02 | WIN-03 |
|---|---|---|---|
| All three studies listed | Yes | Yes | Yes |
| SMB project files readable | Yes | Yes | Yes |
| MPR / 3D opens | All three | All three | Intermittently |
| `Can not open ProjectFile` | Not observed | Not observed | **Observed** |

WIN-01 and WIN-02 also opened the same study concurrently. On WIN-03, the failing study varied across attempts; the error was not permanently tied to one corrupted project.

The exact message was:

```text
Can not open ProjectFile !!!
Please use the Ez3D2009 Menu (File -> Open Project)
```

The three `Default.npj` files were readable from WIN-03, and all pilot file hashes matched the source copy. These observations **did not support** a corrupt central dataset or a straightforward SMB ACL problem, though they did not rule out all UNC-path-specific application behavior.

## 04 / Executables versus local runtime

On two workstations with Ez3D2009 **1.2.6.33**, the `Ez3D2009.exe` hashes were identical. The complete set of **52 EXE/DLL/OCX files in the installation root** also had matching names and SHA-256 fingerprints.

This rules out a simple mismatch in those root-level binaries; it **does not** prove identical runtime dependencies, per-user settings, subdirectories, registry state or licensing.

Direct Ez3D launch on the problematic PC displayed an expired-trial re-registration notice, whereas a launch initiated by Picasso Viewer did not show that notice. Licensing is therefore an **unresolved observation**, not an established cause, and not a reason to bypass registration controls.

## 05 / Why Get-Process was inconclusive

A process snapshot can show an orphaned instance:

```powershell
Get-Process -Name Ez3D2009 -ErrorAction SilentlyContinue |
    Select-Object Id, StartTime, SessionId, Responding, MainWindowHandle
```

But short-lived processes can disappear before the command runs. After some failures, no Ez3D process remained; at other times an instance existed with `MainWindowHandle=0`. That value alone does **not** imply a hang: at least one successful MPR/3D opening produced a process with no detected main window handle.

We captured a reproduction using [Microsoft Sysinternals Process Monitor](https://learn.microsoft.com/en-us/sysinternals/downloads/procmon) under a separate administrator identity. We did **not** grant administrative privileges to the clinical user.

An illustrative PowerShell capture:

```powershell
$Procmon = 'C:\Tools\Procmon64.exe'
$Pml = 'C:\Diagnostics\Ez3D-Test.pml'

Start-Process $Procmon -ArgumentList (
    '/AcceptEula /NoFilter /Quiet /Minimized ' +
    '/BackingFile "' + $Pml + '"'
)

# Reproduce one failure, then stop promptly:
Start-Process $Procmon -ArgumentList '/Terminate /Quiet' -Wait
```

The capture yielded a **597.14 MB PML** containing **1,356,803 events**. Raw PML and unfiltered CSV exports can contain medical-data paths and local profile information; they were not published.

## 06 / Evidence from Process Monitor

Process Monitor confirmed that Picasso Viewer **did launch** Ez3D2009. The trace contained three separate Ez3D processes, with an overlap between the first and second.

The first grouped results included:

| Operation result | Count |
|---|---:|
| `Ez3D2009.exe / PATH NOT FOUND` | 89 |
| `Ez3D2009.exe / SHARING VIOLATION` | 1 |
| `picasso-viewer.exe / RegCreateKey / ACCESS DENIED` | 62 |

These counts are not themselves root-cause evidence. Applications commonly probe missing paths and may receive benign registry denials. We therefore correlated process ID, exact resource identity, and event times.

A specific conflict emerged in `%LOCALAPPDATA%\Temp`: two Ez3D processes tried to open **the same CSV file**.

| Time | Event |
|---|---|
| 08:27:06 | Ez3D instance 1 opens CSV: `SUCCESS` |
| 08:27:56 | Instance 2 opens same CSV: `SHARING VIOLATION` |
| 08:28:02 | Instance 1 closes CSV |
| 08:28:20 | Instance 3 opens CSV: `SUCCESS` |

**The file-sharing conflict is proven.** However, there is not yet enough evidence to conclude that this CSV conflict causes every `Can not open ProjectFile` incident.

## 07 / A successful test was not a permanent fix

We repeated openings with a clean process state between studies:

1. Open a study from Picasso Viewer and verify MPR/3D.
2. Close Ez3D normally.
3. Confirm zero `Ez3D2009.exe` processes.
4. Proceed to the next study.

All **three studies opened successfully**, and all three Ez3D instances terminated normally. This supported—but did not prove—the theory that concurrent instances cause the failures.

After **restarting Picasso Viewer**, the error returned: studies 3 and 1 failed, while study 2 opened. A later `Get-Process` snapshot showed zero Ez3D instances, but that snapshot could not exclude a rapidly started and exited process.

Therefore, serialization was a useful experiment, **not a verified remediation**.

## 08 / Next steps and operational lessons

The next diagnostic phase should correlate successful and failed attempts in a controlled capture, including process timestamps, `Default.npj` and dependent file accesses, temporary-file behavior, Windows Application Error / Windows Error Reporting events, working directory, and launch context.

Investigate licensing, UNC paths, registry and user-profile state as separate hypotheses. Avoid changing SMB ACLs, wiping `AppData`, replacing binaries, disabling security tools, or editing licensing without evidence.

**Lessons from the pilot:**

- TrueNAS/ZFS over read-only SMB can serve these test studies to multiple viewers.
- SHA-256 verification narrowed the diagnosis by excluding dataset divergence.
- Identical root-level EXE/DLL files do not imply identical application environments.
- Process Monitor exposed a real collision that periodic `Get-Process` polling missed.
- A sharing violation is evidence of a resource conflict, **not automatically the root cause** of the visible error.
- One successful complete cycle does not establish stability.
- Preserve local production databases and backups until migration readiness is proven.

**Current status:** laboratory pilot; not approved for a clinic-wide cutover. A follow-up article will cover a confirmed fix and repeated validation only after the cause is demonstrated.

### References

- [Microsoft Sysinternals Process Monitor](https://learn.microsoft.com/en-us/sysinternals/downloads/procmon)
- [Troubleshoot application start failures with Process Monitor](https://learn.microsoft.com/en-us/troubleshoot/windows-client/shell-experience/troubleshoot-apps-start-failure-use-process-monitor)
