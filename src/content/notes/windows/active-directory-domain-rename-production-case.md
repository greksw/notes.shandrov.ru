---
title: "Renaming an Active Directory domain in production: a practical case"
description: "A production-oriented Active Directory domain rename case using rendom and gpfixup, covering DNS, SYSVOL, GPOs, SPNs, certificates, NAS integration and post-migration validation."
category: "Windows"
tags: ["windows-server", "active-directory", "domain-rename", "rendom", "gpfixup", "gpo", "dns", "kerberos"]
published: 2026-10-06
updated: 2026-10-06
status: current
testedOn: ["Windows Server 2022", "Active Directory Domain Services", "DNS Server", "Group Policy Management"]
featured: true
translationKey: "windows/active-directory-domain-rename-production-case"
---

## Context

Renaming an existing Active Directory domain is an infrastructure migration, not merely a DNS change. The old namespace can remain embedded in GPOs, SYSVOL, DNS, SPNs, certificates, UNC paths, services and third-party systems.

This case covered the following production rename:

```text
fm2.loc
        ↓
ad.fondmet.com
```

The `FM2` NetBIOS name was retained. All IP addresses, endpoint/server names and internal GPO names in this article are anonymized.

## Initial layout

| Component | Example |
| --- | --- |
| DC1 | `dc01.fm2.loc` / `10.20.30.10` |
| DC2 | `dc02.fm2.loc` / `10.20.30.11` |
| New namespace | `ad.fondmet.com` |
| NetBIOS | `FM2` |

## 1. Pre-flight

Active Directory should be healthy before a rename.

```powershell
repadmin /replsummary
repadmin /showrepl *
dcdiag /e /c /v
dcdiag /test:dns /e /v
netdom query fsmo
```

Verify `SYSVOL` and `NETLOGON`:

```cmd
net share
```

For DFSR-backed SYSVOL, the healthy state is `State = 4`.

System State backups of both DCs were created before the change. A hypervisor snapshot alone should not be treated as the recovery plan for this operation.

## 2. Domainlist.xml

```cmd
rendom /list
```

Edit `Domainlist.xml`:

```text
fm2.loc → ad.fondmet.com
```

Keep the NetBIOS name as `FM2`.

Validate:

```cmd
rendom /showforest
```

## 3. Upload and prepare

```cmd
rendom /upload
repadmin /replsummary
rendom /prepare
```

Every DC should reach `Prepared`.

## 4. Execute the rename

```cmd
rendom /execute
```

After the controllers reboot, immediately re-check:

```powershell
repadmin /replsummary
repadmin /showrepl *
dcdiag /e /c /v
```

In this environment, one DC temporarily experienced domain discovery and replication problems. Connectivity restoration, synchronization and KCC convergence returned the directory to a healthy state. Cleanup was therefore deliberately postponed.

## 5. Validate the new namespace

```cmd
nltest /dsgetdc:ad.fondmet.com /kdc /force
nslookup -type=SRV _ldap._tcp.dc._msdcs.ad.fondmet.com
```

```powershell
Resolve-DnsName dc01.ad.fondmet.com
Resolve-DnsName dc02.ad.fondmet.com
```

Documentation-only addressing:

```text
dc01.ad.fondmet.com → 10.20.30.10
dc02.ad.fondmet.com → 10.20.30.11
```

## 6. Repair Group Policy references

```cmd
gpfixup /olddns:fm2.loc /newdns:ad.fondmet.com /dc:dc01 /v
```

Check that `gPCFileSysPath` points to the new SYSVOL:

```text
\\ad.fondmet.com\SYSVOL\ad.fondmet.com\Policies\{GUID}
```

On test clients:

```cmd
gpupdate /force
gpresult /r
gpresult /h C:\Temp\gpresult.html
```

The migration also exposed an older security-filtering issue in one internal GPO. Its actual name is intentionally omitted.

## 7. Third-party systems

One internal management service still used:

```text
security01.fm2.loc
```

and had to be changed to:

```text
security01.ad.fondmet.com
```

A temporary GPO was used to update client configuration. Its real internal name is anonymized.

Before a rename, inventory:

- EDR/antivirus;
- backup agents;
- monitoring;
- LDAP clients;
- RDS;
- scheduled tasks;
- Windows services;
- application configuration;
- scripts;
- hard-coded UNC paths and FQDNs.

## 8. Certificates

A domain rename does not reissue third-party certificates. Review Subject and SAN entries for internal services, RDP, LDAPS, reverse proxies and web interfaces.

Anonymized examples:

```text
app01.fm2.loc
terminal01.fm2.loc
security01.fm2.loc
```

## 9. NAS and ACLs

The file-storage system is anonymized as `nas01`.

After rejoining:

```text
nas01.ad.fondmet.com
NAS01$@AD.FONDMET.COM
```

Validation included machine trust, user/group resolution, SIDs, RID/idmap and existing SMB ACLs. Avoid changing idmap without a clear requirement because existing ACL mappings can break.

## 10. SPNs

Search for the old namespace:

```cmd
setspn -Q */*.fm2.loc
```

Inspect a specific account:

```cmd
setspn -L COMPUTERNAME
```

Do not delete matches automatically. Identify the owning service first.

## 11. Cleanup

Keep the old namespace available during the transition while applications, certificates, tasks, scripts and UNC paths are audited.

After stabilization:

```cmd
rendom /clean
rendom /end
repadmin /syncall /AdeP
repadmin /replsummary
```

## Pre-flight checklist

```text
[ ] repadmin /replsummary clean
[ ] dcdiag without critical errors
[ ] AD DNS healthy
[ ] SYSVOL/NETLOGON available
[ ] DFSR SYSVOL State = 4
[ ] FSMO role placement recorded
[ ] System State backup of both DCs
[ ] GPO inventory
[ ] search old FQDN in SYSVOL
[ ] SPN inventory
[ ] certificate audit
[ ] service accounts
[ ] scheduled tasks
[ ] Windows services
[ ] NAS/Samba
[ ] monitoring
[ ] backup
[ ] EDR/antivirus
[ ] LDAP/Kerberos applications
```

## Post-flight checklist

```text
[ ] Get-ADDomain / Get-ADForest
[ ] netdom query fsmo
[ ] repadmin /replsummary
[ ] repadmin /showrepl
[ ] dcdiag
[ ] DNS SRV records
[ ] nltest /dsgetdc
[ ] SYSVOL / NETLOGON
[ ] gpupdate / gpresult
[ ] gPCFileSysPath
[ ] SPNs
[ ] Kerberos
[ ] NAS
[ ] certificates
[ ] monitoring / backup
[ ] search for the old namespace
```

## Takeaway

The core command sequence is short:

```cmd
rendom /list
rendom /upload
rendom /prepare
rendom /execute
gpfixup
rendom /clean
rendom /end
```

The real migration is broader:

```text
AD → DNS → replication → SYSVOL → GPO → clients
   → NAS → applications → certificates → SPNs
```

A domain rename is not complete when `rendom /execute` reports `Done`; it is complete when the infrastructure no longer has unintended dependencies on the old namespace.
