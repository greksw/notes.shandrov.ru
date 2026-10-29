---
title: "Veyon and unstable RDP: troubleshooting Interception, UpperFilters and GPO deployment"
description: "A Windows Veyon 4.11.3–4.11.4 case study: intermittent RDP black screens, Interception filter drivers, UpperFilters, safe removal and a controlled GPO deployment pilot."
category: "Windows"
tags: ["veyon", "rdp", "interception", "windows", "active-directory", "gpo", "powershell", "upperfilters", "troubleshooting", "scheduled-tasks", "kaspersky"]
published: 2026-10-29
updated: 2026-10-29
status: current
testedOn: ["Veyon 4.11.3–4.11.4", "Windows 10 22H2", "Active Directory", "PowerShell 5.1", "Group Policy Preferences", "Windows OpenSSH"]
featured: false
lang: en
translationKey: "windows/veyon-interception-rdp-troubleshooting"
---

## Symptoms and scope

After centrally deploying Veyon Service to domain-joined Windows workstations, Remote Desktop Protocol (RDP) connections occasionally failed: a black screen after authentication, a disconnected client, or error **0x10b**. TCP/3389 remained reachable, Remote Desktop Services stayed running, and the workstation could still be accessed through SSH. A reboot temporarily restored RDP, but the problem returned.

During an October 2026 investigation of Veyon 4.11.3 and 4.11.4 endpoints, some workstations showed **running Interception drivers** registered as `keyboard` and `mouse` class `UpperFilters`. On one affected workstation, the driver was taken out of the input stack under controlled conditions and a revised Veyon configuration was deployed.

**Observed result at publication:** the Interception drivers were stopped, their UpperFilters entries were absent, Veyon Service remained running, and the new deployment configuration completed successfully. No new TerminalServices Event ID 36 errors were recorded immediately after the change. **Long-term RDP stability had not yet been established.** A successful installer exit code or an Active session does not prove that display, input and reconnection work.

All real hostnames, domains, accounts, GPOs, operator groups and internal addresses are anonymized.

## 1. Why Interception matters

Interception is a keyboard and mouse input filter driver used by certain Veyon input-locking features. [Veyon's platform notes](https://docs.veyon.io/en/latest/admin/platform-notes.html) warn that it **can interfere with RDP** and document the disable/uninstall process.

Three different states must be checked:

1. `Windows/UseInterceptionDriver=false` — Veyon is configured not to use Interception.
2. The `keyboard` and `mouse` entries are absent from class `UpperFilters`.
3. The `keyboard` and `mouse` driver services are `STOPPED`.

One state alone is insufficient. Initially, our affected system already had the Veyon setting at `false`, but both drivers were still running and listed as class filters.

## 2. Services, sessions and RDP event logs

Run locally on the affected workstation, or via an SSH PowerShell session:

~~~powershell
Get-Service VeyonService, TermService |
  Select-Object Name, Status, StartType

qwinsta
quser
~~~

From an administration workstation:

~~~powershell
Test-NetConnection PC-TEST-01 -Port 3389
Test-NetConnection PC-TEST-01 -Port 11100
~~~

An open RDP port does not guarantee that Windows can initialize a session. `Active` does not necessarily mean the screen and keyboard work; `Disconnected` can also result from a normal user disconnect.

Inspect Event ID 36 in `Microsoft-Windows-TerminalServices-LocalSessionManager/Operational`:

~~~powershell
$Boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime

$Errors = @(
  Get-WinEvent -FilterHashtable @{
    LogName   = 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'
    StartTime = $Boot
    Id        = 36
  } -ErrorAction SilentlyContinue
)

[pscustomobject]@{
  Computer = $env:COMPUTERNAME
  LastBoot = $Boot
  RdpEvent36Count = $Errors.Count
}

$Errors | Select-Object -First 10 TimeCreated, Id, Message | Format-List
~~~

During this incident, session-state errors included `0x800708CA` and `0x8007000C`. In `Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Operational` we also observed `Failed to create Input devices` with `0x80070057`.

**These errors are not unique signatures of an Interception conflict.** Correlate them with driver state and the exact timing of changes.

## 3. Inspect Interception driver services and class UpperFilters

~~~powershell
sc.exe query keyboard
sc.exe query mouse
~~~

Before remediation, both drivers showed `RUNNING`. Inspect the class filters:

~~~powershell
$Classes = [ordered]@{
  Keyboard = '{4D36E96B-E325-11CE-BFC1-08002BE10318}'
  Mouse    = '{4D36E96F-E325-11CE-BFC1-08002BE10318}'
}

foreach ($Entry in $Classes.GetEnumerator()) {
  $Path = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$($Entry.Value)"
  $Key = Get-Item -LiteralPath $Path
  $Filters = @($Key.GetValue('UpperFilters'))

  [pscustomobject]@{
    Class = $Entry.Key
    UpperFilters = $Filters -join ', '
    InterceptionPresent = $Filters -contains $Entry.Key.ToLowerInvariant()
  }
}
~~~

An affected system may show:

~~~text
Keyboard: keyboard, klkbdctl.KES-XX, kbdclass, klfltdev.KES-XX
Mouse:    mouse, mouclass, klfltdev.KES-XX
~~~

After Interception is removed from the stack:

~~~text
Keyboard: klkbdctl.KES-XX, kbdclass, klfltdev.KES-XX
Mouse:    mouclass, klfltdev.KES-XX
~~~

`kbdclass` and `mouclass` are Windows components. The `klkbdctl...` and `klfltdev...` filters were present on our Kaspersky Endpoint Security workstations. Exact filter sets vary.

**Never clear UpperFilters wholesale or manually remove Windows/security vendor filters.** An incorrect edit can disable local keyboard and mouse input.

## 4. Confirm UseInterceptionDriver in the registry and Veyon export

~~~powershell
$Path = 'HKLM:\SOFTWARE\Veyon Solutions\Veyon\Windows'
$Key = Get-Item -LiteralPath $Path

[pscustomobject]@{
  ValueExists = $Key.GetValueNames() -contains 'UseInterceptionDriver'
  Value = $Key.GetValue('UseInterceptionDriver')
}
~~~

The desired result is a present value of `false`. If absent, Veyon may use its enabled default.

Also inspect the effective Veyon configuration, without displaying the complete export:

~~~powershell
$Cli = 'C:\Program Files\Veyon\veyon-cli.exe'
$Export = Join-Path $env:TEMP (
  'veyon-audit-' + [guid]::NewGuid().ToString('N') + '.json'
)

try {
  & $Cli config export $Export | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Veyon export failed: $LASTEXITCODE"
  }

  $Cfg = Get-Content -LiteralPath $Export -Raw -Encoding UTF8 |
    ConvertFrom-Json

  [pscustomobject]@{
    SettingPresent = $null -ne $Cfg.Windows.PSObject.Properties['UseInterceptionDriver']
    Value = $Cfg.Windows.UseInterceptionDriver
  }
}
finally {
  Remove-Item -LiteralPath $Export -Force -ErrorAction SilentlyContinue
}
~~~

Full configuration exports may contain internal authentication details. Our pilot confirmed `false` in both the registry and the Veyon export.

## 5. Removing an installed driver safely

[Veyon's documented sequence](https://docs.veyon.io/en/latest/admin/platform-notes.html) is **disable Interception usage → reboot Windows → run the bundled uninstaller**. New installations should pass `/NoInterception`.

On the target workstation with administrative privileges:

~~~powershell
& 'C:\Program Files\Veyon\veyon-cli.exe' config set Windows/UseInterceptionDriver false
~~~

Before changing input drivers, arrange a backup, a maintenance window, saved user data and **verified physical-console access**. SSH or NoMachine can help with management but are not full substitutes for local recovery.

The bundled uninstall command is:

~~~powershell
& 'C:\Program Files\Veyon\interception\install-interception.exe' /uninstall
~~~

Run it **on the workstation**, not on the domain controller. The `%~dp0` syntax in a batch file is not PowerShell syntax.

One attempt in our incident returned:

~~~text
Error deleting \system32\drivers\keyboard.sys
~~~

Read-only checks afterwards revealed that the Interception `UpperFilters` entries were already gone, while the drivers remained loaded until a controlled reboot. After reboot, both driver services were `STOPPED` with code 1077; Windows and Kaspersky class filters remained in place.

**This is an observation from one machine, not a guarantee that rebooting after any uninstall error is safe.** If uninstall is partial, inspect driver files, services and filter registrations first. Avoid manually deleting `keyboard.sys`/`mouse.sys`, bulk `sc delete` or `pnputil` operations, and unsupervised registry edits.

## 6. Read-only remote audit of several workstations

With working WMI/DCOM, an administrator can query a limited group of computers:

~~~powershell
$Computers = @('PC-TEST-01', 'PC-TEST-02')
$HKLM = [uint32]2147483650

$Paths = @{
  Keyboard = 'SYSTEM\CurrentControlSet\Control\Class\{4D36E96B-E325-11CE-BFC1-08002BE10318}'
  Mouse    = 'SYSTEM\CurrentControlSet\Control\Class\{4D36E96F-E325-11CE-BFC1-08002BE10318}'
}

foreach ($PC in $Computers) {
  try {
    $Reg = [WmiClass]"\\$PC\root\default:StdRegProv"

    foreach ($Name in @('Keyboard', 'Mouse')) {
      $Response = $Reg.GetMultiStringValue($HKLM, $Paths[$Name], 'UpperFilters')
      if ($Response.ReturnValue -ne 0) {
        throw "$Name read failed: $($Response.ReturnValue)"
      }
      $Filters = @($Response.sValue)

      [pscustomobject]@{
        Computer = $PC
        Class = $Name
        InterceptionPresent = $Filters -contains $Name.ToLowerInvariant()
        UpperFilters = $Filters -join ', '
        Status = 'OK'
      }
    }
  }
  catch {
    [pscustomobject]@{
      Computer = $PC
      Class = '-'
      InterceptionPresent = $null
      UpperFilters = ''
      Status = $_.Exception.Message
    }
  }
}
~~~

An RPC failure is **UNKNOWN**, not proof that the driver is absent.

## 7. Prevent GPO from reinstalling the driver

The environment deployed Veyon through **Group Policy Preferences → Scheduled Task → PowerShell as SYSTEM**. The previous installer invocation was:

~~~powershell
$Version = '4.11.3.0'
$psi.Arguments = '/S /NoMaster'
~~~

`/NoInterception` was missing, and the imported corporate JSON did not explicitly contain `Windows.UseInterceptionDriver=false`. A daily GPP task with action `Update` could reapply the old configuration.

The production script also pinned installer/config SHA-256, checked the signature, operator access group and restricted TCP/11100 firewall configuration, and rejected unexpected versions. **Do not replace the production EXE or JSON in place** without updating the complete, verified deployment package.

For a pilot, use GPMC item-level targeting:

~~~text
Computer Configuration → Preferences → Control Panel Settings
  → Scheduled Tasks → Veyon-AutoDeploy
    → Common → Item-level targeting
~~~

Rules such as `Computer Name is not PC-TEST-01` must all be combined with **AND**. Disable existing local tasks separately and verify after policy refresh; GPP may otherwise re-enable them.

~~~powershell
schtasks.exe /Query /S PC-TEST-01 /TN 'Veyon-AutoDeploy' /FO LIST /V
~~~

## 8. The revised deployment pilot

The new pilot included:

- Veyon 4.11.4 with `/S /NoMaster /NoInterception`;
- a managed JSON configuration explicitly setting `Windows.UseInterceptionDriver=false`;
- SHA-256, installer signature, AD operator-group and restricted TCP/11100 firewall checks;
- a guard **rejecting** machines with active Interception filters instead of automatically uninstalling them;
- a `-WhatIfCheck` mode;
- live execution as `NT AUTHORITY\SYSTEM` through a temporary Scheduled Task.

Dry runs as an administrator and as SYSTEM both exited 0 without installation or service restarts. The live pilot also exited 0 with `SUCCESS` in the deployment log; Task Scheduler **Event ID 201** confirmed action completion. The temporary task was removed after validation.

Checklist:

| Check | Expected |
| --- | --- |
| VeyonService / TermService | Running |
| Registry and Veyon export | `UseInterceptionDriver=false` |
| Driver services `keyboard` / `mouse` | STOPPED |
| Class `UpperFilters` | No Interception `keyboard` / `mouse` entries |
| Windows and security driver filters | Preserved |
| Legacy GPO deployment task | Not re-enabled |
| Deployment log / Event ID 201 | SUCCESS / exit 0 |
| RDP Event ID 36 | No new occurrences in the observation window |
| RDP and Veyon Master | Screen, input and reconnection actually work |
| Next-business-day check | Preferably without an intervening reboot |

**Conclusion:** an Interception/RDP conflict remains a well-supported working hypothesis, consistent with the vendor guidance and observations. The filter driver was successfully taken out of the input stack and the revised deployment configuration was applied. Proving the root cause resolved requires a further period of stable RDP use.

## References and related articles

- [Veyon — Platform specific notes](https://docs.veyon.io/en/latest/admin/platform-notes.html)
- [Veyon — Release notes](https://docs.veyon.io/en/latest/admin/release-notes.html)
- [Microsoft — Remote Desktop disconnected errors](https://learn.microsoft.com/en-us/troubleshoot/windows-server/remote/troubleshoot-remote-desktop-disconnected-errors)
- [Related case: Veyon, Active Directory and GPO](/notes/windows/veyon-workgroup-ad-authentication-gpo-diagnostics/)
