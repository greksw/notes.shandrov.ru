---
title: "Picasso Importer on TrueNAS: from a complete export to a working 3D view (Part 3)"
description: "A verified CBCT workflow with a personal SMB inbox, the original Default.npj, ZFS snapshot verification, no-overwrite publication, and two Windows shortcuts."
category: "Storage and Backup"
tags: ["truenas", "zfs", "smb", "active-directory", "picasso-viewer", "ez3d2009", "dicom", "powershell", "sha256"]
published: 2026-11-21
updated: 2026-11-21
status: current
testedOn: ["TrueNAS SCALE 25.10.8", "ZFS", "SMB", "Windows 11", "Active Directory", "Windows PowerShell 5.1", "Picasso Viewer 4.0.42"]
featured: false
lang: en
translationKey: "storage-backup/truenas-picasso-importer-production-part-3"
---

[Part 1](/notes/storage-backup/truenas-picasso-ez3d2009-pilot-part-1/) tested viewing studies from central storage. [Part 2](/ru/notes/storage-backup/truenas-picasso-ez3d2009-merged-dataset-part-2/) covered consolidation and verification of the local archives (in Russian). The next question was whether a clinician could add a **new** study and open it from the same shared archive.

Two new packages made it all the way to a working 3D view in Picasso Viewer. One was submitted from PowerShell and the other from a desktop shortcut. A separate workstation verified automatic shortcut setup at Windows sign-in. These results cover the tested workflows and workstations.

## How the components interact

![AD and GPO deploy the uploader to Windows. Windows sends the study to a personal SMB inbox. The importer on TrueNAS reads a ZFS input snapshot and publishes the validated study. Picasso Viewer reads Production over SMB.](/images/notes/storage-backup/picasso-importer-flow.png)

On the workstation, the preparation shortcut opens the user's `Drop` folder and the submission shortcut sends one export folder to the user's `Incoming` over SMB. The user can write to their own queue. A Python importer writes to the shared archive locally on TrueNAS. Picasso Viewer reads published studies from a separate read-only SMB share.

## Why a successful DICOM copy was insufficient

The first new job with 400 DICOM files reached `IMPORTED_VERIFIED`, but the study was absent from the Viewer list. The complete export included the original `Default.npj`. Adding that file from the same export to a copy of the DICOM files made the study appear and open in 3D.

The client and server then adopted a flat package with the DICOM files and one original `Default.npj`. The client selects images from either the export root or the `Data` directory tree. It stops if images are present in both places or if flattening would produce duplicate file names. Ancillary export files are skipped. The project is copied byte for byte, and the server verifies its size and SHA‑256 hash. Both the project and images come from the same export. The vendor application interprets the project format.

This change was verified for new submissions. The intermittent `Can not open ProjectFile` failure in Part 1 was a separate observation from the earlier pilot.

## From submission to the Viewer list

| Stage | What is checked |
|---|---|
| Windows prepares the package | The network copy is checked against the source with SHA‑256. During transfer, the folder has a temporary name. Once verified, the client writes a ready marker and atomically gives the directory its final name. |
| TrueNAS accepts a job | Cron checks the queue every five minutes and selects one ready job. The importer captures a ZFS input snapshot and compares its own manifests of the live package and the snapshot. |
| The importer checks UIDs | Study Instance UIDs and SOP Instance UIDs are checked against the existing archive. A duplicate ends without creating another directory. UID overlap requires investigation. |
| The importer publishes | The package is staged outside the Viewer directory. After verifying the copied files and permissions, the importer uses a no-replace rename. It records the result separately from the published study. |
| The clinician opens the study | The study appears in the shared list. Acceptance includes scrolling through slices and rotating the 3D view from the production source. |

The importer checks pool health, replication state and the expected SMB access mode before acting on the queue. The original guard also compared the exact TrueNAS version string. After an upgrade, the next import stopped at that check. The current version records the OS release and checks the state of the required resources. The source is retained. A successful import leaves input, pre- and post-import snapshots and a job result. Publication and subsequent backup replication can be checked separately.

## Delivering two shortcuts to the Windows desktop

A computer policy installs the uploader and icons under protected `Program Files` at startup. A user policy verifies the protected copy and configures the per-user desktop shortcuts at sign-in.

Windows PowerShell 5.1 with `RemoteSigned` refused to run the unsigned setup script directly over UNC during manual testing. The standard Logon script now verifies the SHA‑256 of a temporary local copy and starts it with `RemoteSigned`. Shortcut migration matches the known submission command and the expected PowerShell executable. The script verifies the protected uploader path and hash before writing a shortcut.

`Plan` can check that the setup recognizes an old shortcut without replacing it. A fresh `APPLY` log after an interactive Windows sign-in verifies automatic execution. SSH is useful for running `Plan`. An interactive desktop sign-in exercises the actual Logon policy.

## What the acceptance tests confirmed

| Test | Result |
|---|---|
| Submission from PowerShell | 456 DICOM files and one `Default.npj`. The server returned `IMPORTED_VERIFIED`. The study opened from Production and the 3D view rotated. |
| Submission from the desktop shortcut | 400 DICOM files and one `Default.npj`. Transfer, server import and opening the new study from Production were verified. |
| Windows Logon on another workstation | A fresh sign-in produced a setup log confirming that both shortcuts were verified. |

The client reports readiness for processing, the server JSON records publication, and the Viewer confirms that the published set opens in the application. Keep those three events separate during troubleshooting. The job ID and submission time are enough to start a queue investigation. The case study omits images, patient names, internal paths, user accounts and raw logs.

[Project page on the main site](https://shandrov.ru/en/projects/picasso-importer/).
