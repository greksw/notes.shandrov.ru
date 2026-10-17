---
title: "VixWin Platinum 3.6.3 via GPO: preparing HKCU before the first launch"
description: "Active Directory case study: roaming user profiles, VixWin registry initialization, NAS-backed image database, logon scripts, PowerShell, and GPO filtering."
category: "Windows"
tags: ["vixwin","active-directory","gpo","powershell","roaming-profiles","registry","logon-scripts","sysvol","windows-11","automation"]
published: 2026-10-18
updated: 2026-10-18
status: current
testedOn: ["VixWin Platinum 3.6.3","Windows 11","Active Directory","PowerShell 5.1","GPO Logon Scripts","Roaming Profiles"]
featured: false
lang: en
translationKey: "windows/gpo-vixwin-platinum-user-profile-deployment"
---

## The problem

After moving from a locally configured account to Active Directory roaming profiles, VixWin Platinum 3.6.3 displayed its first-run wizard and offered to **create a new database**, although the existing image database was available via a mapped SMB drive. The patient list appeared empty because the new user's HKCU settings pointed to drive C: rather than Z:.

An October 2026 pilot deployed a **user GPO → CMD logon script → PowerShell launcher → per-user HKCU configuration**. On two Windows 11 domain workstations, tested user profiles opened VixWin without the initial language/mode/database wizard. A ten-user AD group was later granted GPO Apply permission. This is a site-specific deployment case, not a claim about every VixWin installation or every imaging-device setup.

**Sanitization:** All names such as ad.example.com, PC-01, nas01, CORP and user01 are placeholders. Real domain names, workstation IDs, network addresses, patient records, device identifiers and original .reg exports are not published.

## 1. Where VixWin stores settings

The primary user-specific branch was `HKCU\Software\Gendex\VixWin32`, including Setup, Preferences, Database, Customize, Toolbar, Toolbox and UserInterface. The common `C:\vixwin\VIXWIN.INI` only contained `Database=1` in this installation. Copying the INI therefore could not migrate the user profile.

The pilot exported only four UI subkeys: **Customize, Toolbar, Toolbox and UserInterface**. DICOM, CCDSensor, imaging hardware, licensing, and other potentially machine-specific settings were deliberately excluded.

## 2. Why importing UI settings alone failed

During first-run initialization VixWin regenerated database settings, changing `Dbdrive` and `DefaultImageDrive` from Z to C. Reapplying the database path *after* first launch fixed the patient list, but was an unsuitable unattended deployment sequence.

The verified approach was to initialize HKCU **before VixWin was ever opened by a new user**. These eight settings were sufficient for the tested configuration:

| Registry subkey | Name and example value | Type |
| --- | --- | --- |
| Setup | Config = 1 | DWORD |
| Setup | Version = Platinum v3.6.3 | String |
| Preferences | Language = LNGRUSSK.DLL | String |
| Database | Dbmode = 1 | DWORD |
| Database | DatabaseReadOnly = 1 | DWORD |
| Database | Dbdrive = Z | String |
| Database | DefaultImageDrive = Z | String |
| Database | LastPath = Z:\VXDATA | String |

**DatabaseReadOnly=1 was observed in this particular installation; it is not a universal prescription.** Understand database ownership, shared-access settings, device integration, and permissions before copying any values to a different site.

Next, the four sanitized UI subkeys were imported. A fresh user then opened the existing database without the first-run wizard.

## 3. Deployment design

    AD user OU: GPO + security-group filtering
          |
          v
    CMD logon script in user context
          |
          v
    PowerShell launcher: wait up to 60 seconds for mapped Z:
          |
          v
    Validate allowlisted workstation/user, SMB mapping, database folder
    Validate four private UI templates against SHA256
          |
          v
    Pre-initialize fresh HKCU OR back up existing HKCU
    Import UI, configure database path
    Verify, record deployment version, log success / skip

The code runs **as the interactive user**, never SYSTEM: HKCU and mapped drive letters are user-session dependent. An independent Drive Maps GPO provides Z:; the launcher only waits for its availability. The scripts do not create databases, install VixWin, alter NAS ACLs, manage DICOM devices, or touch images.

For existing profiles, back up HKCU first. For fresh profiles, create only the approved values. Any unexpected existing configuration should result in a review rather than blindly copying the entire Gendex branch.

## 4. User and computer GPOs

The **user GPO** was linked to the user OU, with GpoApply initially assigned to a pilot group and later switched to an explicitly reviewed ten-user group. Authenticated Users retained GpoRead. Workstation names were checked again inside PowerShell so user GPO applicability on other machines would not modify their registry.

A separate **computer GPO** targeted only the two allowed workstations and set:

    HKLM\SOFTWARE\Policies\Microsoft\Windows\System
    EnableLogonScriptDelay (DWORD) = 0

Disabling logon-script delay does **not** guarantee synchronous completion. In the pilot, the logon wrapper started within approximately 0–1 seconds of Explorer startup and exited after another 3–4 seconds. An operator should ensure first-run provisioning has finished before opening VixWin.

## 5. Diagnostics and verification

    whoami
    gpresult /scope user /r
    Test-Path 'Z:\VXDATA'
    Get-ItemProperty 'HKCU:\Software\Gendex\VixWin32\Database' |
      Select-Object Dbdrive,Dbmode,DefaultImageDrive,DatabaseReadOnly,LastPath

The launcher and deployment script write separate per-user logs. Expected events include a successful fresh-profile initialization followed by `SKIP` on repeat login, once the registry settings match the deployment marker. This skip check confirms required registry keys and selected database values, not pixel-identical toolbar layout.

When a mapped drive is unavailable, the launcher must fail without modifying HKCU and retry on a later sign-in. Roaming profiles should be closed cleanly before using the same account on another workstation.

## 6. Privacy, rollback, and limitations

**Never commit actual .reg exports from a clinical workstation without review.** Even apparently UI-only exports can contain unexpected values. Do not publish patient images, DICOM identifiers, internal DNS and IP addresses, clinic-specific paths, account SIDs, or production logs.

A sample configuration should include deliberately invalid checksums and refuse to deploy until an administrator explicitly configures trusted private UI templates. SHA256 alone does not establish authenticity if an attacker can change both the template and its manifest.

To roll back, remove GpoApply for the targeted group, sign out, restore the affected user's own HKCU backup, and validate the NAS mapping and application behavior. Never create a new local patient database as a workaround for an incorrect path.

## Conclusion

Legacy Windows applications may require **first-run HKCU pre-initialization**, not merely importing a .reg file or copying INI. The successful pattern combined verified registry types, a working NAS mapping, least-privilege user-context execution, GPO security filtering, SYSVOL replication checks, logging and repeat-safe application.

Related case studies: [7-Zip GPO deployment](/notes/windows/gpo-software-deployment-7zip-auto-update/) and [Veyon / AD troubleshooting](/notes/windows/veyon-workgroup-ad-authentication-gpo-diagnostics/).

## GitHub scripts

A sanitized **non-production demonstration** is available at [greksw/vixwin-gpo-deployment](https://github.com/greksw/vixwin-gpo-deployment): HKCU initializer, guarded logon launcher, CMD wrapper and GPO instructions. Actual clinical `.reg` exports are excluded, and example SHA256 values are deliberately invalid. **Do not run without site-specific security review and configuration.**
