---
title: "Veyon from Windows WORKGROUP to Active Directory clients: authentication, troubleshooting and GPO deployment"
description: "A Veyon 4.11.3 case study: a non-domain Windows Master, matching local credentials, Security 4625, access-control rules, DNS redirection and PowerShell/GPO deployment v1.3."
category: "Windows"
tags: ["veyon", "windows", "active-directory", "workgroup", "logon-authentication", "gpo", "powershell", "scheduled-tasks", "troubleshooting", "ldap"]
published: 2026-10-16
updated: 2026-10-16
status: current
testedOn: ["Veyon 4.11.3", "Windows 11 WORKGROUP", "Windows 10/11 AD clients", "Active Directory", "PowerShell 5.1", "Group Policy Preferences"]
featured: false
lang: en
translationKey: "windows/veyon-workgroup-ad-authentication-gpo-diagnostics"
---

## Scenario and scope

We needed to access Windows domain-joined workstations through **Veyon Master running on a Windows 11 computer outside Active Directory** (WORKGROUP). In the same infrastructure, Veyon Service was being deployed to AD workstations by GPO and PowerShell. In October 2026, we restored the connection from WORKGROUP and verified several automated deployment batches.

This case concerns **Windows**, not the previous [Ubuntu Veyon without domain join case](/notes/linux/veyon-ubuntu-ad-without-domain-join/).

All internal names, hostnames, accounts, groups, OUs, addresses and domains are anonymized. Commands are illustrative and contain no production passwords. The actual `Install-Veyon-v1.3.ps1` source has since been reviewed. The article now includes an [anonymized reference template](/downloads/Install-Veyon-v1.3-example.ps1). This template is **intentionally not deployment-ready**: its SHA256 values, domain, operator group and approved networks are placeholders. It is neither a verbatim production script nor a universal safe installer.

## Architecture

```text
Windows 11 / WORKGROUP
  Veyon Master 4.11.3
  local operator1 account
        |
        +---- DNS -> AD workstation names
        +---- LDAPS :636 -> Active Directory objects
        +---- TCP/11100 -----------------------------+
                                                     |
                                        Windows / AD domain member
                                        Veyon Service 4.11.x
                                        Logon authentication
                                        Access Control based on AD group
                                                     |
                                              AD / Domain Controller

Deployment (domain-joined clients only):
GPO -> Scheduled Task (SYSTEM) -> Install-Veyon-v1.3.ps1 -> EXE/config/service/firewall
```

**Three independent mechanisms** need to be checked: LDAP delivers a list of computers, Windows verifies the submitted credentials, and Veyon access-control rules decide whether an authenticated operator may connect.

## 1. What worked before the fix

We had already confirmed:

- Veyon Master 4.11.3 started correctly on Windows 11 WORKGROUP.
- LDAPS queries returned AD computers and OUs.
- The remote AD workstation was reachable over TCP/11100.
- Veyon Service was running and listening on the domain client.
- The intended domain operator was in the configured access group.
- A separate connection to a domain controller using domain credentials worked.

Nevertheless, Veyon Master failed to connect. **Successful directory queries, network reachability, and even a successful `net use` are not proof that Veyon is presenting the intended Windows identity** to the remote Service.

## 2. Fix DNS and routing before investigating authentication

The investigation first exposed a separate networking issue: a gateway **DNS redirect** intercepted DNS requests from the WORKGROUP segment. Once narrowly scoped exceptions were added for the AD DNS servers, internal workstation names resolved correctly.

Run on the Windows Veyon Master:

```powershell
Resolve-DnsName pc01.ad.example.com
Resolve-DnsName dc01.ad.example.com
Test-NetConnection pc01.ad.example.com -Port 11100
Test-NetConnection dc01.ad.example.com -Port 636
```

Run on the target domain workstation:

```powershell
Get-Service VeyonService -ErrorAction SilentlyContinue
Get-NetTCPConnection -LocalPort 11100 -State Listen -ErrorAction SilentlyContinue
```

Check effective DNS resolvers and NAT rules rather than testing only raw IP connectivity. The DNS redirect was resolved **before** the authentication problem. Keep any gateway DNS exceptions restricted to the necessary systems and flows.

## 3. Domain credentials still failed from WORKGROUP

Trying `CORP\operator1` and `operator1@ad.example.com` did not fix the connection. Security logs on the remote Windows host showed **event 4625 (LogonType 3)** for a different account rather than the expected domain operator.

The captured events included `0xC000006D` (logon failure) and `0xC000006A` (wrong password for the specified user). At this point the failure was no longer a transport problem; it was related to the **effective account context** used for authentication.

We also observed another distinct failure stage: Veyon reported successful VNC authentication, but its **Access Control** subsequently denied the connection because the evaluated identity did not satisfy the allowed-group condition.

| Symptom | Investigate |
| --- | --- |
| TCP/11100 is unavailable | Service, host firewall, routing and ACLs |
| Security 4625 with a wrong user or password | Actual username/domain received by the target |
| VNC authentication succeeded, then Access Control denied | Effective identity and Veyon rules/group backend |
| LDAP works, remote control fails | Authentication, authorization and remote service, not just LDAP |

Investigate authentication events **on the remote target host**, correlating the timestamp and source address with a Veyon Master connection attempt.

## 4. The working fix: a matching local WORKGROUP account

A **local** account `operator1` was created on the non-domain Windows computer running Veyon Master, with the same username and password as the intended domain operator. Connections to the AD-joined workstations then succeeded.

This is consistent with **Veyon's Logon authentication model**: the Master sends the provided identity/credentials to the remote Service, which asks the remote OS to validate them. Veyon's documentation points out the requirement for matching account credentials across machines in this mode.

**This does not establish domain trust.** The local user does not become an AD principal. Without inspecting the successful 4624 event and the effective group/identity used by Veyon on the target, we cannot claim which exact Windows authentication resolution path was used in every session. The positive connection does not by itself prove that a broad access rule was not involved.

**Security trade-off:** duplicating a domain password in a local account is credential reuse and increases exposure. This is a **verified site-specific workaround, not a recommended default for large deployments**. For long-term administration, prefer a domain-joined management workstation or a carefully managed Veyon key-file authentication model with strict access to the private key. A domain password change does not automatically update the local account. Do not grant local administrator rights unless explicitly required.

## 5. Authentication versus Veyon Access Control

Domain group usage and group-restricted access were configured on the Windows client. A reported `UserGroups/UseDomainUserGroups=true` is not sufficient proof that the remote Veyon Service will treat a WORKGROUP local user as a member of a domain operator group.

Read the effective configuration on the remote computer:

```powershell
$Cli = 'C:\Program Files\Veyon\veyon-cli.exe'
& $Cli config get 'UserGroups/Backend'
& $Cli config get 'UserGroups/UseDomainUserGroups'
& $Cli config get 'AccessControl/AccessRestrictedToUserGroups'
```

Some settings may be renamed or absent in a particular build. A non-existent or legacy key should not be treated as the confirmed root cause.

In **Veyon Configurator → Access control**, review the rule order, **Accessing user is member of group** condition, user-group backend and default deny behavior. Do not keep an unrestricted allow rule merely to make a connection test pass.

## 6. Analyze Windows Security events

Run on the **target AD workstation** after a connection attempt, with permissions to read its Security log:

```powershell
$since = (Get-Date).AddMinutes(-10)
Get-WinEvent -FilterHashtable @{
    LogName='Security'; Id=4624,4625; StartTime=$since
} -ErrorAction SilentlyContinue | ForEach-Object {
    [xml]$xml = $_.ToXml()
    $fields = @{}
    foreach ($item in $xml.Event.EventData.Data) {
        $fields[$item.Name] = $item.'#text'
    }
    [pscustomobject]@{
        Time=$_.TimeCreated; EventId=$_.Id
        User=$fields.TargetUserName; Domain=$fields.TargetDomainName
        LogonType=$fields.LogonType; Status=$fields.Status
        SubStatus=$fields.SubStatus; SourceIP=$fields.IpAddress
    }
} | Format-Table -AutoSize
```

The most useful fields are `TargetUserName`, `TargetDomainName`, `LogonType`, `Status` and `SubStatus`. Not every 4624/4625 event is generated by Veyon: correlate timestamps, process and source. Redact user identifiers and network addresses before publishing any log output.

Review `VeyonMaster.log` on the Master and the Veyon/Windows logs available on the Service host. The log file names and paths depend on build and configuration; failure to find one guessed filename does not mean Veyon emitted no diagnostic data.

## 7. Review of the actual `Install-Veyon-v1.3.ps1`

An important correction: the installer is a **Veyon EXE** launched with `/S /NoMaster`, **not an MSI**. The script targets Windows 10/11 workstations only (CIM `Win32_OperatingSystem.ProductType = 1`) and runs through a GPO Scheduled Task as **LOCAL SYSTEM**. It deliberately skips Windows Server and domain controllers. It installs **Veyon Service, not Master**.

### Layer 1: constrain execution

- PowerShell 5.1 and StrictMode.
- Workstation-only OS guard; `S-1-5-18` SYSTEM SID required for live deployment.
- Global named mutex to prevent overlapping runs.
- Effective firewall profiles must be enabled and must not default to unrestricted inbound traffic.
- `-WhatIfCheck` skips installation and firewall mutations, **but is not completely side-effect-free**: the script may create directories, emit logs and secure a temporary directory while verifying effective configuration.

### Layer 2: manifest and integrity

The script loads a NETLOGON `manifest.json` with required version **4.11.3.0**. It pins SHA256 hashes for x64/x86 EXE packages and a configuration JSON. It validates hashes in the manifest, on the network share and again after local copying. It also checks the installer via `Get-AuthenticodeSignature` for `Status = Valid` and the expected signer subject of Veyon Solutions.

A signer subject comparison is **not the same as pinning a certificate thumbprint**; normal code-signing trust and source control still matter.

```text
\\ad.example.com\NETLOGON\Software\Veyon\
├── manifest.json
├── Packages\...
├── Config\...
└── Scripts\Install-Veyon-v1.3.ps1
```

### Layer 3: v1.3 corrects installer-process handling

Version `v1.3` starts the EXE with `.NET System.Diagnostics.ProcessStartInfo`, `UseShellExecute = false`, `CreateNoWindow = true`, a **600-second timeout**, and strict exit-code checking. A stalled process is terminated where possible and logged. This addressed the installer execution problems observed with the earlier `v1.2` approach.

This script is **not a general automatic updater**: it deliberately refuses an already-installed version other than `4.11.3.0` and requires manual upgrade review before changing pinned hashes, config and upgrade procedure.

### Layer 4: restrict exposure during deployment

Before first installation, the script adds a temporary **inbound Block TCP/11100** rule, imports vetted JSON, disables other enabled Veyon-related inbound Allow rules and creates its own limited `Allow TCP/11100` rule restricted to approved source addresses. It leaves unrelated firewall rules untouched.

It then ensures `VeyonService` is automatic and running, checks `veyon-cli.exe` version, effective configuration and firewall. Only after verification does it remove the temporary block. **If deployment fails, the block intentionally remains active** and must not be removed without examining why validation failed.

The source also handles a Veyon 4.11.3 quirk: `veyon-cli config get` may return an empty server-port value while `config export` shows port `11100`. Effective configuration is therefore exported to a temporary ACL-restricted directory (SYSTEM and Administrators only), inspected, and deleted.

### Layer 5: idempotence and health checks

A rerun returns `Already current; configuration, service and firewall checks OK` only if the installed version, service status, stamped package/config hashes, restricted allow rule, effective Veyon configuration and absence of a temporary Block rule all match.

The state stamp is an additional check, **not a replacement** for checking the actual service and access-control configuration.

### Client-side validation

```powershell
$TaskName = 'Corp-Veyon-AutoDeploy' # example only
Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue |
    Select-Object TaskName, State, @{N='RunAs';E={$_.Principal.UserId}}
Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue |
    Select-Object LastRunTime, LastTaskResult, NextRunTime
Get-Service VeyonService -ErrorAction SilentlyContinue
Get-NetFirewallRule | Where-Object DisplayName -Like '*Veyon*' |
    Select-Object DisplayName, Enabled, Direction, Action
Get-Content "$env:ProgramData\Example\Veyon\deploy.log" -Tail 30 # example path
```

Pair `LastTaskResult = 0` with the deploy log, service state and firewall. Task completion alone does not prove Veyon was configured as intended.

**83 of 85 installations** were confirmed in a validation batch. The two remaining workstations exhibited an installer launch issue (`0xC0000142`). After reboot and rechecking them, the Veyon Service was operational and the symptom did not recur, but **the root cause of `0xC0000142` was not established**. These observations do not imply permanent 100% fleet compliance.

The revised script was checked on both domain controllers and an idempotent rerun reported `Already current` on a sample domain workstation. GPO applies to domain-joined clients, **not to the separate WORKGROUP Master**.

The [anonymized reference script `Install-Veyon-v1.3-example.ps1`](/downloads/Install-Veyon-v1.3-example.ps1) retains the operational logic, but deliberately contains invalid SHA256 placeholders and RFC 5737 example addresses. **It is not ready to deploy without independent review and site-specific configuration.**

## 8. Reusable read-only PowerShell diagnostics

The companion [Veyon-Diagnostics.ps1](/downloads/Veyon-Diagnostics.ps1) is a **new, read-only diagnostic helper**. It checks DNS, TCP/11100, local Veyon CLI, Veyon Service, selected configuration keys and Scheduled Task state. It **does not create accounts, change firewall rules or install software**.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Veyon-Diagnostics.ps1 `
  -TargetHost pc01.ad.example.com -TaskName Corp-Veyon-AutoDeploy
```

To investigate 4624/4625 events, run the section 6 command on the remote Windows target. This helper is **not** a copy of production `Install-Veyon-v1.3.ps1`.

## Results and limits

- The DNS redirect issue was resolved independently of Veyon authentication.
- LDAPS and TCP/11100 confirmed connectivity, not remote-control authorization.
- Security 4625 revealed a wrong identity/password, while Veyon's Access Control exposed a separate authorization failure.
- A WORKGROUP local account with matching credentials enabled connections to AD computers **in this environment**.
- Deployment v1.3 was reviewed as source code and passed a repeat no-op check on a pilot client; the audit does not establish full-fleet compliance.
- For security assurance, verify a successful 4624 identity/group path and **explicitly reject** an unauthorized user without any temporary unconditional allow rule.

## References

- [Veyon: Logon authentication](https://docs.veyon.io/en/latest/admin/configuration.html)
- [Veyon: Access control rules](https://docs.veyon.io/en/latest/admin/access-control-rules.html)
- [Veyon: Troubleshooting](https://docs.veyon.io/en/latest/admin/troubleshooting.html)
- [Veyon: Command line interface](https://docs.veyon.io/en/latest/admin/cli.html)