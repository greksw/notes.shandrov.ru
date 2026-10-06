---
title: "Переименование домена Active Directory в production: практический кейс"
description: "Практический кейс переименования домена Active Directory: rendom, gpfixup, DNS, SYSVOL, GPO, SPN, сертификаты, NAS и post-migration audit."
category: "Windows"
tags: ["windows-server", "active-directory", "domain-rename", "rendom", "gpfixup", "gpo", "dns", "kerberos"]
published: 2026-10-06
updated: 2026-10-06
status: current
testedOn: ["Windows Server 2022", "Active Directory Domain Services", "DNS Server", "Group Policy Management"]
featured: true
lang: ru
translationKey: "windows/active-directory-domain-rename-production-case"
---

## Контекст

Переименование существующего домена Active Directory — это полноценная инфраструктурная миграция, а не просто смена DNS-имени. Старый namespace может оставаться в GPO, SYSVOL, DNS, SPN, сертификатах, UNC-путях, сервисах и сторонних системах.

В этом кейсе выполнялось переименование:

```text
legacy.example.local
        ↓
ad.example.com
```

NetBIOS-имя `FM2` сохранялось. Все IP-адреса, имена конечных серверов и внутренние названия GPO в статье обезличены.

## Исходная схема

| Компонент | Пример |
| --- | --- |
| DC1 | `dc01.legacy.example.local` / `10.20.30.10` |
| DC2 | `dc02.legacy.example.local` / `10.20.30.11` |
| Новый namespace | `ad.example.com` |
| NetBIOS | `FM2` |

## 1. Pre-flight

До rename Active Directory должен быть исправен.

```powershell
repadmin /replsummary
repadmin /showrepl *
dcdiag /e /c /v
dcdiag /test:dns /e /v
netdom query fsmo
```

Проверяем `SYSVOL` и `NETLOGON`:

```cmd
net share
```

Для DFSR-backed SYSVOL рабочее состояние — `State = 4`.

Перед изменениями были сделаны System State Backup обоих DC. Полагаться только на snapshot гипервизора для такой операции не стоит.

## 2. Domainlist.xml

```cmd
rendom /list
```

В `Domainlist.xml` меняем:

```text
legacy.example.local → ad.example.com
```

NetBIOS оставляем `FM2`.

Проверка:

```cmd
rendom /showforest
```

## 3. Upload и prepare

```cmd
rendom /upload
repadmin /replsummary
rendom /prepare
```

Все DC должны перейти в состояние `Prepared`.

## 4. Выполнение rename

```cmd
rendom /execute
```

После перезагрузки контроллеров сразу выполняем повторную диагностику:

```powershell
repadmin /replsummary
repadmin /showrepl *
dcdiag /e /c /v
```

В нашем случае один DC временно испытывал проблемы с обнаружением домена и репликацией. После восстановления связности, синхронизации и работы KCC состояние нормализовалось. Поэтому cleanup сразу после `/execute` не выполнялся.

## 5. Проверка нового namespace

```cmd
nltest /dsgetdc:ad.example.com /kdc /force
nslookup -type=SRV _ldap._tcp.dc._msdcs.ad.example.com
```

```powershell
Resolve-DnsName dc01.ad.example.com
Resolve-DnsName dc02.ad.example.com
```

Документационная адресация:

```text
dc01.ad.example.com → 10.20.30.10
dc02.ad.example.com → 10.20.30.11
```

## 6. Исправление Group Policy

После rename:

```cmd
gpfixup /olddns:legacy.example.local /newdns:ad.example.com /dc:dc01 /v
```

Проверяем, что `gPCFileSysPath` у GPO указывает на новый SYSVOL:

```text
\\ad.example.com\SYSVOL\ad.example.com\Policies\{GUID}
```

На клиентах:

```cmd
gpupdate /force
gpresult /r
gpresult /h C:\Temp\gpresult.html
```

Одна из внутренних GPO после миграции выявила старую проблему с security filtering. Конкретное имя политики в публичной версии не приводится.

## 7. Сторонние системы

Один внутренний сервис использовал старый FQDN:

```text
security01.legacy.example.local
```

После миграции:

```text
security01.ad.example.com
```

Для обновления клиентской конфигурации использовалась временная GPO с обезличенным названием.

До rename стоит проверить:

- EDR/антивирус;
- backup agents;
- monitoring;
- LDAP-клиенты;
- RDS;
- scheduled tasks;
- Windows services;
- конфигурационные файлы;
- скрипты;
- hardcoded UNC/FQDN.

## 8. Сертификаты

Domain rename не перевыпускает сертификаты сторонних сервисов. После миграции нужно проверить Subject и SAN у внутренних сервисов, RDP, LDAPS, reverse proxy и web-интерфейсов.

Примеры обезличенных старых имён:

```text
app01.legacy.example.local
terminal01.legacy.example.local
security01.legacy.example.local
```

## 9. NAS и ACL

Файловое хранилище в статье обезличено как `nas01`.

После повторного присоединения:

```text
nas01.ad.example.com
NAS01$@AD.FONDMET.COM
```

Проверялись machine trust, разрешение пользователей и групп, SID, RID/idmap и существующие SMB ACL. Не следует менять idmap без необходимости: это может нарушить соответствие старых ACL доменным идентификаторам.

## 10. SPN

Поиск старого namespace:

```cmd
setspn -Q */*.legacy.example.local
```

Проверка конкретного объекта:

```cmd
setspn -L COMPUTERNAME
```

Найденные SPN нельзя удалять автоматически: сначала нужно определить сервис-владелец.

## 11. Cleanup

Старый namespace лучше сохранять на переходный период, пока выполняется аудит приложений, сертификатов, задач, скриптов и UNC-путей.

После стабилизации:

```cmd
rendom /clean
rendom /end
repadmin /syncall /AdeP
repadmin /replsummary
```

## Pre-flight checklist

```text
[ ] repadmin /replsummary без ошибок
[ ] dcdiag без критических ошибок
[ ] AD DNS исправен
[ ] SYSVOL/NETLOGON доступны
[ ] DFSR SYSVOL State = 4
[ ] FSMO-роли зафиксированы
[ ] System State Backup обоих DC
[ ] аудит GPO
[ ] поиск старого FQDN в SYSVOL
[ ] аудит SPN
[ ] сертификаты
[ ] service accounts
[ ] scheduled tasks
[ ] Windows services
[ ] NAS/Samba
[ ] monitoring
[ ] backup
[ ] EDR/антивирус
[ ] LDAP/Kerberos приложения
```

## Post-flight checklist

```text
[ ] Get-ADDomain / Get-ADForest
[ ] netdom query fsmo
[ ] repadmin /replsummary
[ ] repadmin /showrepl
[ ] dcdiag
[ ] DNS SRV
[ ] nltest /dsgetdc
[ ] SYSVOL / NETLOGON
[ ] gpupdate / gpresult
[ ] gPCFileSysPath
[ ] SPN
[ ] Kerberos
[ ] NAS
[ ] сертификаты
[ ] monitoring / backup
[ ] поиск старого namespace
```

## Итог

Основной цикл команд короткий:

```cmd
rendom /list
rendom /upload
rendom /prepare
rendom /execute
gpfixup
rendom /clean
rendom /end
```

Но реальная миграция шире:

```text
AD → DNS → replication → SYSVOL → GPO → clients
   → NAS → applications → certificates → SPN
```

Domain Rename заканчивается не тогда, когда `rendom /execute` показывает `Done`, а когда инфраструктура больше не имеет незапланированных зависимостей от старого namespace.
