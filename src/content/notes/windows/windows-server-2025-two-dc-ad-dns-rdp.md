---
title: "Windows Server 2025: two-DC Active Directory with DNS and restricted RDP"
description: "A production-oriented pattern for deploying two Active Directory domain controllers with AD-integrated DNS, secure dynamic updates and GPO-based RDP access boundaries."
category: "Windows"
tags: ["windows-server", "active-directory", "dns", "gpo", "rdp", "security"]
published: 2026-09-15
updated: 2026-09-15
status: current
testedOn: ["Windows Server 2025 Standard", "Active Directory Domain Services", "DNS Server", "Proxmox VE 9.x"]
featured: true
---

## Context

A small production site still benefits from treating identity services as infrastructure rather than as a single Windows VM with a few extra roles installed.

The pattern described here uses two domain controllers, AD-integrated DNS, a reverse lookup zone, secure dynamic updates and a deliberately narrow RDP model. The goal is not to document every wizard page, but to capture the design decisions and validation steps that matter when the domain has to remain supportable after deployment.

The values below are documentation examples. Replace the domain name, VLAN and IP addresses with values appropriate for the actual environment.

## Reference architecture

Example layout:

| Component | Example value |
| --- | --- |
| AD DNS domain | `ad.example.com` |
| NetBIOS name | `EXAMPLE` |
| Server VLAN | `164` |
| Server subnet | `10.40.64.0/24` |
| Gateway | `10.40.64.1` |
| DC1 | `dc01.ad.example.com` / `10.40.64.11` |
| DC2 | `dc02.ad.example.com` / `10.40.64.12` |
| RDP access group | `GG_RDP_Users` |

Both domain controllers should be separate VMs on different hypervisor nodes when the platform allows it. For a small site, 2 vCPU, 8 GB RAM and an 80 GB system disk are a reasonable starting point, but the sizing should follow the actual directory, DNS and authentication load.

Keep the DC network interface on the server VLAN and use a static address. Do not configure a public DNS resolver directly on a domain controller NIC. AD clients and DCs must resolve the AD namespace through AD-aware DNS servers; external resolution should be handled by DNS forwarders instead.

## Prerequisites

Before promotion, verify the basic infrastructure rather than using the AD deployment to discover network problems.

- both servers have stable hostnames and static IP addresses;
- forward and reverse routing between required client networks and the DC subnet is intentional;
- NTP/time synchronization is healthy;
- the hypervisor has working backups or a documented recovery path;
- no duplicate DNS suffix or legacy domain namespace exists;
- firewall policy allows the required AD DS, DNS, Kerberos, LDAP, SMB and RPC traffic between domain members and domain controllers;
- administrative access to both servers has been tested independently of the future domain.

For virtualized DCs, avoid taking arbitrary long-lived snapshots as a substitute for directory-aware backup and recovery planning. Hypervisor backup is useful, but Active Directory recovery decisions must still account for directory replication and the role of each DC.

## Deploy the first domain controller

Install the AD DS and DNS roles:

```powershell
Install-WindowsFeature AD-Domain-Services,DNS -IncludeManagementTools
```

Create the forest using the intended internal namespace:

```powershell
Install-ADDSForest `
  -DomainName "ad.example.com" `
  -DomainNetbiosName "EXAMPLE" `
  -InstallDNS
```

The promotion process will request the Directory Services Restore Mode password and reboot the server.

After reboot, do not immediately proceed to the second DC. First validate that the forest is actually healthy:

```powershell
Get-ADDomain
Get-ADForest
Get-ADDomainController -Filter *
Get-SmbShare -Name SYSVOL,NETLOGON
```

`SYSVOL` and `NETLOGON` must be present. Confirm DNS zone creation and basic name resolution before introducing another replication partner.

## Deploy the second domain controller

Before promotion, configure `dc02` to use `dc01` as its DNS server. Join the server to the new domain, install the roles and promote it as an additional DC:

```powershell
Install-WindowsFeature AD-Domain-Services,DNS -IncludeManagementTools

$cred = Get-Credential "EXAMPLE\Administrator"

Install-ADDSDomainController `
  -DomainName "ad.example.com" `
  -Credential $cred `
  -InstallDNS
```

After reboot, verify that both controllers are visible and replication is healthy:

```powershell
Get-ADDomainController -Filter * |
  Select-Object HostName,IPv4Address,Site,IsGlobalCatalog

repadmin /replsummary
```

A two-DC design is only useful if the second server is a real replication partner. Do not consider the deployment complete because both servers answer on TCP 3389 or because both appear in DNS.

## DNS design

AD-integrated DNS keeps the directory and DNS replication model aligned and avoids maintaining a separate zone-transfer design for the AD namespace.

The forward zone for the domain should be AD-integrated and configured for secure dynamic updates. Add a reverse zone for the server subnet as well. For the example network:

```powershell
Add-DnsServerPrimaryZone `
  -NetworkId "10.40.64.0/24" `
  -ReplicationScope "Domain" `
  -DynamicUpdate Secure
```

Inspect the zones on both DCs:

```powershell
Get-DnsServerZone |
  Select-Object ZoneName,ZoneType,IsDsIntegrated,DynamicUpdate,ReplicationScope
```

The important invariants are:

- the AD forward zone is directory-integrated;
- dynamic updates are secure rather than unrestricted;
- the reverse zone is replicated through AD;
- both domain controllers can answer authoritative queries for the AD namespace;
- external names are resolved through configured forwarders, not by bypassing AD DNS on clients.

Once both DCs are stable, configure their DNS client settings so that each controller can use an AD DNS peer and itself. Exact preferred/alternate ordering is an operational choice; the critical rule is that the NIC must not point directly to public resolvers.

## RDP access model

RDP should be treated as an authorization boundary, not simply enabled everywhere.

Use a dedicated domain security group such as `GG_RDP_Users` for staff who need interactive access to ordinary workstations. Keep domain-controller administration separate.

For workstation OUs, a GPO can enforce the following baseline:

- Remote Desktop Services connections are allowed;
- Network Level Authentication is required;
- Windows Defender Firewall allows the Remote Desktop rules for TCP and UDP 3389;
- `GG_RDP_Users` is granted workstation RDP access through the local `Remote Desktop Users` group or an equivalent controlled policy.

Do not use Domain Admins as the generic solution for workstation RDP access.

## Explicitly protect domain controllers

A workstation RDP group should not automatically become a domain-controller logon group.

Create a separate GPO linked only to the **Domain Controllers OU** and explicitly deny the workstation RDP group these rights:

- `Deny log on locally`;
- `Deny log on through Remote Desktop Services`.

The deny policy has precedence over allow policy, which is exactly why this control must be scoped carefully. Do not link this GPO at the domain root, and do not add administrative groups to the deny list.

Before broad rollout, validate the policy with a test account that is a member of `GG_RDP_Users` but has no administrative role.

## GPO validation

On a workstation that should accept RDP:

```powershell
gpupdate /force
gpresult /r
```

Confirm that the intended workstation GPOs are applied and that the test user can establish an RDP session with NLA enabled.

On a domain controller, verify that the DC-specific restriction policy is applied:

```powershell
gpresult /scope computer /r
```

Then test both sides of the boundary:

1. a member of `GG_RDP_Users` can log on through RDP to an allowed workstation;
2. the same user is denied RDP access to `dc01` and `dc02`;
3. an authorized administrator can still manage both DCs.

Do not treat a policy as validated until both the allowed and denied paths have been tested.

## Directory and DNS validation

A compact post-deployment validation set is more useful than relying on Event Viewer being quiet.

```powershell
repadmin /replsummary

dcdiag /e /test:DNS

Get-ADDomainController -Filter * |
  Select-Object HostName,IPv4Address,Site,IsGlobalCatalog

Resolve-DnsName dc01.ad.example.com
Resolve-DnsName dc02.ad.example.com
```

Also verify:

- `SYSVOL` and `NETLOGON` shares exist on both DCs;
- forward records for both controllers are correct;
- PTR records resolve through the reverse zone;
- secure dynamic registration works from a domain-joined client;
- a client can authenticate when either one of the two DCs is temporarily unavailable;
- Group Policy still applies with one DC offline.

The last two checks prove much more about the design than simply pinging both servers.

## Failure scenarios

### One DC is unavailable

Clients should continue resolving the AD namespace and authenticating through the remaining DC. Investigate DNS client configuration first if authentication appears to fail only when one server is down.

### Replication is unhealthy

Do not make unrelated GPO or directory changes until the replication state is understood. Start with `repadmin /replsummary`, DNS resolution between DCs and the Directory Service/DNS event logs.

### RDP users can reach a domain controller

Check GPO scope, inheritance and effective policy on the DC. A policy existing in Group Policy Management is not evidence that it is applied to the Domain Controllers OU.

### Administrators are unexpectedly denied

Treat this as a policy-scope problem. Use an unaffected administrative path, inspect effective User Rights Assignment, correct the deny-group membership or GPO scope, and force policy refresh only after confirming the change.

## Rollback and recovery notes

The safest rollback is usually to reverse the most recent policy or membership change rather than attempting to restore a DC VM snapshot.

For GPO changes:

- keep changes small and attributable;
- validate on a limited OU or test workstation first;
- document the previous setting before changing logon rights;
- maintain at least one tested administrative path to the DCs.

For a failed additional-DC deployment, determine whether the server was fully promoted before attempting cleanup. Do not repeatedly rerun promotion commands against a partially created DC object without first checking AD Sites and Services, DNS records and replication metadata.

For actual directory recovery, use a documented AD recovery procedure rather than improvising from a hypervisor snapshot.

## Security notes

Two domain controllers improve availability, but they do not reduce the importance of access control.

- keep interactive logon to DCs limited to administrators who need it;
- use NLA for RDP;
- do not expose TCP/UDP 3389 from untrusted networks;
- keep normal workstation-support users outside privileged AD groups;
- use secure dynamic DNS updates;
- keep public DNS resolvers off DC and domain-member NIC configuration;
- monitor replication, authentication and DNS failures rather than waiting for users to report them.

The useful boundary is simple: ordinary support staff can reach the systems they operate, while domain controllers remain a separate administrative tier.

## Known caveats

This runbook intentionally does not prescribe a universal OU hierarchy, password policy, AD CS design, tiered administration model or backup product. Those depend on the size and risk profile of the environment.

It also assumes a single AD site. Multi-site deployments should define sites, subnets and replication topology explicitly rather than relying on the default site indefinitely.

The example addresses and domain name are sanitized documentation values; the operational pattern is the relevant part.
