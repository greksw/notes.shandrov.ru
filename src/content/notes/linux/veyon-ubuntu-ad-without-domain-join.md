---
title: "Veyon on Ubuntu with Active Directory authentication without domain join"
description: "A Veyon Master 4.11.3 case study integrating Ubuntu 24.04 with Kerberos/PAM and LDAPS without joining Linux to Active Directory."
category: "Linux"
tags: ["veyon", "ubuntu", "active-directory", "kerberos", "pam", "ldaps"]
published: 2026-10-14
updated: 2026-10-14
status: current
testedOn: ["Ubuntu 24.04.5 LTS", "Veyon 4.11.3", "Kerberos", "PAM", "LDAPS"]
featured: false
lang: en
translationKey: "linux/veyon-ubuntu-ad-without-domain-join"
---

## Context

The objective was to operate Veyon Master on Ubuntu, authenticate operators with Active Directory, and retrieve Windows computer objects from AD without joining the Linux host to the domain. No `realm join`, AD computer account or SSSD domain enrollment was required.

All real domain names, IP addresses, identities and organizational structures are anonymized. `ad.example.com` is a documentation placeholder, not a production domain.

## Architecture

```text
Ubuntu 24.04.5 / Veyon Master 4.11.3 (not joined to AD)
       ├── Kerberos + dedicated PAM → AD domain controllers
       ├── LDAPS TCP/636 → AD users, groups and computers
       └── Veyon Master → Windows Veyon Service
                             ├── Logon authentication
                             └── Access-control rules
```

**Kerberos/PAM authentication**, **LDAP directory discovery**, and **Windows-side authorization** are separate. Reading a computer from LDAP does not imply permission to control it.

## 1. DNS, time and network prerequisites

```bash
resolvectl query dc01.ad.example.com
timedatectl status
nc -vz dc01.ad.example.com 88
nc -vz dc01.ad.example.com 636
nc -vz workstation01.ad.example.com 11100
```

Kerberos depends on correct DNS, synchronized clocks and a reachable KDC. Never expose the Veyon Service port directly to the Internet.

## 2. Kerberos without domain enrollment

The Ubuntu host was configured for an explicit AD Kerberos realm, using a dedicated service principal and a protected keytab. It was not enrolled with `realm join`.

```bash
klist
klist -k -e /path/to/protected.keytab
```

The file path is illustrative. A keytab is sensitive credential material and must never be published, embedded in a repository or distributed without appropriate protection and rotation procedures.

## 3. Dedicated PAM service

A separate `/etc/pam.d/veyon` service used `pam_krb5`, avoiding changes to global PAM stacks such as `login` or `common-auth`. In Veyon Configurator, **Logon authentication** was associated with the custom PAM service `veyon`.

```bash
pamtester veyon demo-operator authenticate acct_mgmt
```

An authorized operator passed both checks. A negative test with an unavailable keytab was rejected. Exact module options must be validated for the installed `pam_krb5` package before reuse.

## 4. The Veyon authentication helper

A crash occurred in the privileged `veyon-auth-helper` execution path. Ownership, file permissions and linked libraries were inspected. A compatible corrected build restored Veyon Master login.

This was a package/runtime-specific correction, not a general recommendation to alter privileged binary permissions. Any local change to a privileged helper needs provenance verification, security review and a rollback plan.

## 5. LDAPS directory discovery

A separate least-privilege LDAP account was used for reading directory objects. The issuing CA was trusted by Ubuntu; the LDAPS certificate chain and hostname had to be verified.

Illustrative query:

```bash
ldapsearch -x \
  -H ldaps://dc01.ad.example.com:636 \
  -D 'CN=svc-ldap-reader,CN=Users,DC=ad,DC=example,DC=com' \
  -W \
  -b 'OU=Workstations,DC=ad,DC=example,DC=com' \
  '(objectCategory=computer)' dNSHostName
```

Configure Veyon LDAP with the server, TCP/636, Base DN, a read-only bind identity, the relevant computer subtree, `sAMAccountName` and `dNSHostName`. Computer objects and OUs were successfully returned in the pilot.

## 6. Windows authorization

Windows Veyon Service used Logon authentication. Access should be limited through Veyon Access Control and a dedicated AD operator group.

Two checks are required: a group member is allowed, and a valid AD user outside the group is denied. Successful remote access was observed; the explicit negative authorization test was **not yet documented as passing**.

## Verification results

| Check | Result |
| --- | --- |
| Ubuntu not joined to AD | Confirmed |
| Kerberos and protected keytab | Passed |
| Dedicated PAM authentication | Passed |
| Negative test with unavailable keytab | Rejected |
| LDAPS computer and OU lookup | Passed |
| Veyon Master connection to Windows Service | Passed |
| Screen viewing and remote control | Passed |
| Denial for AD user outside operator group | Still to verify |

Minor display artifacts during remote viewing were unrelated to authentication.

## Troubleshooting and operations

Troubleshoot in layers: DNS/time, KDC, PAM, directory credentials and TLS trust, LDAP search scope, then Windows Veyon Service and access-control rules. Back up PAM and Veyon configuration before changing packages. A Veyon upgrade may replace any locally corrected helper. Protect and rotate keytab and bind-account credentials.

## Conclusion

Ubuntu can authenticate Veyon operators against AD and discover workstations via LDAPS without being joined to the domain. The crucial design principle is separating operator identity validation, directory discovery and Windows-side remote-access authorization — and testing both permitted and denied access.

## References

- [Veyon documentation](https://docs.veyon.io/en/latest/)
- [Veyon LDAP integration](https://docs.veyon.io/en/latest/admin/ldap.html)