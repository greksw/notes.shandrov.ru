---
title: "Windows Server 2025: два контроллера домена AD, DNS и ограниченный RDP"
description: "Практический подход к развёртыванию двух контроллеров Active Directory с AD-integrated DNS, безопасными динамическими обновлениями и разграничением RDP-доступа через GPO."
category: "Windows"
tags: ["windows-server", "active-directory", "dns", "gpo", "rdp", "security"]
published: 2026-09-16
updated: 2026-09-16
status: current
testedOn: ["Windows Server 2025 Standard", "Active Directory Domain Services", "DNS Server", "Proxmox VE 9.x"]
featured: true
lang: ru
translationKey: "windows/windows-server-2025-two-dc-ad-dns-rdp"
---

## Контекст

Даже небольшой производственный контур выигрывает от того, что службы идентификации рассматриваются как полноценная инфраструктура, а не как одна Windows VM с несколькими установленными ролями.

В этой схеме используются два контроллера домена, AD-integrated DNS, reverse lookup zone, безопасные динамические обновления и намеренно ограниченная модель RDP-доступа.

Цель — зафиксировать архитектурные решения и проверки, которые определяют поддерживаемость домена после ввода в эксплуатацию.

Все значения ниже обезличены.

## Эталонная архитектура

| Компонент | Пример |
| --- | --- |
| DNS-домен AD | `ad.example.com` |
| NetBIOS | `EXAMPLE` |
| VLAN серверов | `164` |
| Подсеть | `10.40.64.0/24` |
| Шлюз | `10.40.64.1` |
| DC1 | `dc01.ad.example.com` / `10.40.64.11` |
| DC2 | `dc02.ad.example.com` / `10.40.64.12` |
| Группа RDP | `GG_RDP_Users` |

Контроллеры домена желательно размещать на разных узлах гипервизора.

Для небольшого домена 2 vCPU, 8 ГБ RAM и 80 ГБ системного диска — разумная стартовая конфигурация, но фактический sizing должен соответствовать нагрузке.

На сетевых интерфейсах DC используйте статические адреса. Не прописывайте публичные DNS-серверы непосредственно на NIC контроллеров домена.

Клиенты AD и сами DC должны разрешать внутреннее пространство имён через AD-aware DNS, а внешние запросы — через forwarders.

## Предварительные условия

До promotion проверьте:

- стабильные hostname и статические IP;
- маршрутизацию между клиентскими сетями и VLAN контроллеров;
- исправную синхронизацию времени;
- рабочую схему backup/recovery;
- отсутствие конфликтующего старого namespace;
- firewall для AD DS, DNS, Kerberos, LDAP, SMB и RPC;
- административный доступ к обоим серверам.

Снапшоты гипервизора не заменяют корректную стратегию восстановления Active Directory.

## Первый контроллер домена

Установите роли:

```powershell
Install-WindowsFeature AD-Domain-Services,DNS -IncludeManagementTools
```

Создайте forest:

```powershell
Install-ADDSForest `
  -DomainName "ad.example.com" `
  -DomainNetbiosName "EXAMPLE" `
  -InstallDNS
```

После reboot убедитесь, что первый DC исправен:

```powershell
Get-ADDomain
Get-ADForest
Get-ADDomainController -Filter *
Get-SmbShare -Name SYSVOL,NETLOGON
```

`SYSVOL` и `NETLOGON` должны существовать.

Также проверьте DNS zone и разрешение имён до добавления второго replication partner.

## Второй контроллер домена

До promotion настройте `dc02` на использование `dc01` как DNS, присоедините его к домену и установите роли:

```powershell
Install-WindowsFeature AD-Domain-Services,DNS -IncludeManagementTools

$cred = Get-Credential "EXAMPLE\Administrator"

Install-ADDSDomainController `
  -DomainName "ad.example.com" `
  -Credential $cred `
  -InstallDNS
```

После reboot:

```powershell
Get-ADDomainController -Filter * |
  Select-Object HostName,IPv4Address,Site,IsGlobalCatalog

repadmin /replsummary
```

Два DC имеют смысл только тогда, когда второй сервер действительно участвует в репликации.

Наличие обоих серверов в DNS или доступность TCP 3389 этого не доказывают.

## DNS

AD-integrated DNS использует ту же модель репликации, что и каталог, и не требует отдельной схемы zone transfer для внутреннего namespace.

Forward zone домена должна быть интегрирована с AD и использовать secure dynamic updates.

Для серверной подсети создайте reverse zone:

```powershell
Add-DnsServerPrimaryZone `
  -NetworkId "10.40.64.0/24" `
  -ReplicationScope "Domain" `
  -DynamicUpdate Secure
```

Проверьте зоны:

```powershell
Get-DnsServerZone |
  Select-Object ZoneName,ZoneType,IsDsIntegrated,DynamicUpdate,ReplicationScope
```

Ключевые инварианты:

- forward zone интегрирована с AD;
- dynamic updates — secure;
- reverse zone также реплицируется через AD;
- оба DC отвечают авторитетно за AD namespace;
- внешние имена разрешаются через forwarders.

После стабилизации двух DC настройте DNS client settings так, чтобы контроллеры могли использовать друг друга и самих себя.

## Модель RDP-доступа

RDP — это граница авторизации, а не просто включённый сервис.

Используйте отдельную доменную security group, например `GG_RDP_Users`, для сотрудников, которым нужен RDP к обычным рабочим станциям.

Администрирование контроллеров домена отделяется от этой группы.

На OU рабочих станций GPO может задавать:

- разрешение Remote Desktop Services connections;
- обязательный Network Level Authentication;
- firewall rules для TCP/UDP 3389;
- добавление `GG_RDP_Users` в `Remote Desktop Users` или эквивалентную управляемую политику.

Не используйте Domain Admins как универсальный способ дать RDP к пользовательским ПК.

## Явно защитите контроллеры домена

Группа для RDP к рабочим станциям не должна автоматически получать право входа на DC.

Создайте отдельную GPO только для **Domain Controllers OU** и запретите для `GG_RDP_Users`:

- `Deny log on locally`;
- `Deny log on through Remote Desktop Services`.

Deny имеет приоритет над allow, поэтому scope политики критичен.

Не связывайте её с корнем домена и не добавляйте административные группы в deny-list.

## Проверка GPO

На рабочей станции:

```powershell
gpupdate /force
gpresult /r
```

Проверьте, что workstation GPO применена и тестовый пользователь из `GG_RDP_Users` может подключиться с NLA.

На контроллере домена:

```powershell
gpresult /scope computer /r
```

Затем проверьте обе стороны границы:

1. пользователь `GG_RDP_Users` входит на разрешённую workstation;
2. тот же пользователь не может войти по RDP на `dc01` и `dc02`;
3. авторизованный администратор по-прежнему может управлять DC.

Политика не считается проверенной, пока не протестированы и allow, и deny paths.

## Проверка каталога и DNS

```powershell
repadmin /replsummary

dcdiag /e /test:DNS

Get-ADDomainController -Filter * |
  Select-Object HostName,IPv4Address,Site,IsGlobalCatalog

Resolve-DnsName dc01.ad.example.com
Resolve-DnsName dc02.ad.example.com
```

Дополнительно проверьте:

- `SYSVOL` и `NETLOGON` на обоих DC;
- A и PTR records;
- secure dynamic registration от доменного клиента;
- аутентификацию при временном отключении одного DC;
- применение Group Policy при недоступности одного контроллера.

Последние два теста подтверждают отказоустойчивость лучше, чем простой ping обоих серверов.

## Сценарии отказа

### Один DC недоступен

Клиенты должны продолжать разрешать AD namespace и аутентифицироваться через оставшийся DC.

Если проблема появляется только при выключении одного сервера, в первую очередь проверяйте DNS client configuration.

### Нарушена репликация

Не вносите несвязанные изменения в GPO и каталог, пока не понятна причина.

Начните с `repadmin /replsummary`, DNS между контроллерами и событий Directory Service/DNS.

### Обычные RDP-пользователи могут войти на DC

Проверяйте scope, inheritance и effective policy.

Наличие GPO в консоли не доказывает, что она реально применяется к Domain Controllers OU.

### Администраторы неожиданно заблокированы

Используйте оставшийся административный путь, проверьте effective User Rights Assignment, исправьте membership или scope и только затем обновляйте policy.

## Rollback и recovery

Для ошибок GPO безопаснее отменить последнее изменение, чем восстанавливать DC из снапшота.

Для политик:

- вносите небольшие изменения;
- сначала тестируйте на ограниченном OU;
- фиксируйте предыдущие значения;
- сохраняйте хотя бы один проверенный административный путь к DC.

Если deployment второго DC завершился частично, сначала определите реальное состояние promotion.

Не запускайте promotion повторно поверх частично созданного объекта без проверки AD Sites and Services, DNS и replication metadata.

Для реального восстановления каталога используйте документированную AD recovery procedure.

## Безопасность

- интерактивный вход на DC должен быть доступен только нужным администраторам;
- используйте NLA;
- не публикуйте TCP/UDP 3389 в недоверенные сети;
- не добавляйте обычных support-пользователей в привилегированные AD-группы;
- используйте secure dynamic DNS updates;
- не прописывайте публичный DNS на NIC domain members и DC;
- мониторьте replication, authentication и DNS failures.

Полезная граница проста: сотрудники поддержки получают доступ только к системам, которые обслуживают, а контроллеры домена остаются отдельным административным уровнем.

## Ограничения

Этот runbook намеренно не задаёт универсальную OU-структуру, password policy, AD CS, tiered administration или конкретный backup product.

Также предполагается один AD site. В multi-site среде sites, subnets и replication topology следует определить явно.
