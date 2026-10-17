---
title: "Safe Windows 10/11 Appx cleanup through GPO: user logon, Audit/Enforce and SystemApps guards"
description: "A user-GPO case study of exact-name Appx cleanup, PowerShell Audit/Enforce modes, protected packages, OneDrive safeguards and source evolution v1.0–v1.4."
category: "Windows"
tags: ["windows", "active-directory", "gpo", "powershell", "appx", "windows-11", "security", "automation", "sysvol"]
published: 2026-10-17
updated: 2026-10-17
status: current
testedOn: ["Windows 10/11", "Windows PowerShell 5.1", "Active Directory", "User Configuration GPO"]
featured: false
lang: en
translationKey: "windows/gpo-windows-appx-cleanup-user-logon"
---

## Problem and scope

An Active Directory environment needed controlled removal of selected **current-user Windows 10/11 Appx packages** without affecting unrelated user profiles, protected Windows components, or machine-wide Win32 software. The implementation uses **User Configuration GPO → Logon Scripts**, a CMD wrapper and PowerShell 5.1 running as the **interactive user, not SYSTEM**.

The v1.0, v1.3 and v1.4 snapshots document the evolution of the original implementation. Published examples are anonymized, incorporate additional safety controls and have not been re-executed on Windows after adaptation.

## Architecture

```text
Active Directory → User OU / Security Filtering
    → User Configuration → Windows Settings → Scripts (Logon)
    → Run-AppCleanup.cmd → Remove-UserApps.ps1 (interactive user)
        Audit: Get-AppxPackage → FOUND / REVIEW / PROTECTED
        Enforce: exact-name Remove-AppxPackage → REMOVED / DEFER / ERROR
    → %LOCALAPPDATA%\Example\AppCleanup\cleanup.log
```

GPO targeting is managed through OU links, security filtering and the resultant user policy—not through username suffixes inside the PowerShell script. Organization-specific user exceptions belong in private policy administration.

## Inventory first: Audit and Enforce

The script defaults to `-Mode Audit` and makes no removal changes during inventory. It rejects the `S-1-5-18` SYSTEM identity, skips Windows Server/RDS by default and uses a per-user mutex to avoid simultaneous executions.

```powershell
powershell.exe -NoProfile -File .\Remove-UserApps.ps1 -Mode Audit
Get-AppxPackage | Select-Object Name, PackageFamilyName, Version, NonRemovable
gpresult /scope user /r
Get-Content "$env:LOCALAPPDATA\Example\AppCleanup\cleanup.log" -Tail 40
```

Candidates are matched using **exact Appx `Name` values**; broad destructive wildcards like `*Office*`, `*Xbox*` and `*Skype*` are avoided. Exact matching does not guarantee a package is unnecessary: business dependencies still require review.

The original production CMD wrappers used `Enforce`; the **public CMD launcher defaults to `Audit`**. The current public PowerShell adaptation additionally requires `-AcknowledgeAppRemoval` before actual removal. Historical sources under `history/` are for review, not direct execution.

## Version evolution

| Revision | Observed changes |
| --- | --- |
| v1.0 | Exact Appx identities, Audit/Enforce, SYSTEM rejection, per-user mutex and logs, HKCU inventory |
| v1.3 | Expanded package set, `NonRemovable` / `IsPartOfSystem` / `Windows\SystemApps` checks, deferred Outlook removal while `olk.exe` is running |
| v1.4 | Exact Yandex Music package `A025C540.Yandex.Music` verified on one Windows 11 pilot machine |

Protected packages are logged as `PROTECTED`; the script does not seize ownership of system directories or forcibly delete their contents. Unexpected package names are recorded for review, not automatically removed.

## Outlook, OneDrive and limitations

`Remove-AppxPackage` applies **to the current user**. The script neither removes provisioned packages from the Windows image nor uninstalls machine-wide Win32 applications or forcibly changes `C:\Windows\SystemApps`.

For new Outlook (`Microsoft.OutlookForWindows`), removal is deferred if `olk.exe` is running. OneDrive Desktop is handled separately: its **per-user** uninstaller requires explicit opt-in and defers while OneDrive synchronization is active. HKCU Uninstall entries are inventoried only; arbitrary `UninstallString` commands are not executed.

Exit code `0` may indicate an intentional skip or deferral, not verified removal. Some Appx registrations can return after Windows updates. A general rollback, provisioned-package cleanup and fleet-wide compliance inventory are outside this implementation's scope.

## Source code and rollout checks

**[GitHub: greksw/windows-appcleanup-gpo](https://github.com/greksw/windows-appcleanup-gpo)** — [current script](https://github.com/greksw/windows-appcleanup-gpo/blob/main/scripts/Remove-UserApps.ps1), [source history](https://github.com/greksw/windows-appcleanup-gpo/tree/main/history), [GPO guide](https://github.com/greksw/windows-appcleanup-gpo/blob/main/docs/gpo-setup.md) and [security review](https://github.com/greksw/windows-appcleanup-gpo/blob/main/docs/security-review.md).

Before enabling removal, review actual Appx identities and business dependencies, audit a pilot OU, inspect user-scoped `gpresult` and logs, approve Enforce and document application recovery. GitHub Actions static checks are not a substitute for executing controlled tests on Windows.
