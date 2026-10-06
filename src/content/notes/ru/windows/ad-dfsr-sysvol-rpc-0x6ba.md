---
title: "DFSR/SYSVOL: repadmin OK, а dcdiag показывает RPC 0x6ba"
description: "Реальный кейс Windows Server 2025: AD replication без ошибок, но dcdiag падает на DFSREvent, KccEvent и SystemLog из-за RPC-доступа к удалённым журналам."
category: "Windows"
tags: ["windows-server-2025", "active-directory", "dfsr", "sysvol", "repadmin", "dcdiag", "rpc"]
published: 2026-10-06
updated: 2026-10-06
status: current
testedOn: ["Windows Server 2025 Standard", "Active Directory Domain Services", "DFS Replication"]
featured: true
lang: ru
translationKey: "windows/ad-dfsr-sysvol-rpc-0x6ba"
---

## Контекст

После развёртывания двух Windows Server 2025 DC в `ad.okdent-spb.ru` базовая AD DS replication выглядела исправно, но полный `dcdiag` показывал ошибки.

Имена серверов и IP ниже обезличены.

## Симптом

`repadmin /replsummary`:

```text
Fails: 0 / 5
Error: 0%
```

Все naming contexts реплицировались успешно.

Но `dcdiag /e /c /v` отмечал:

```text
DFSREvent
KccEvent
SystemLog
RPC 0x6ba
```

При этом проходили:

```text
Connectivity
Advertising
SysVolCheck
NetLogons
Replications
Topology
DNS
```

Это важный признак: красный `DFSREvent` ещё не доказывает отказ SYSVOL replication.

## Разделяем уровни

Проверяются отдельно:

1. AD DS replication;
2. DFSR/SYSVOL;
3. доступ диагностики к Event Log через RPC.

```cmd
repadmin /replsummary
repadmin /showrepl *
repadmin /queue
```

На обоих DC:

```powershell
Get-SmbShare -Name SYSVOL,NETLOGON
Get-Service DFSR,Netlogon
```

```cmd
dcdiag /test:sysvolcheck
dcdiag /test:netlogons
```

В данном случае SYSVOL и NETLOGON были опубликованы, а проверки проходили.

## RPC и удалённый Event Log

Ключевой тест:

```powershell
Get-WinEvent -ComputerName dc02 -LogName "DFS Replication" -MaxEvents 20
```

Именно удалённое чтение журнала воспроизводило RPC-проблему.

На целевом DC была разрешена встроенная firewall group **Remote Event Log Management**. После этого удалённый `Get-WinEvent` начал работать.

Следовательно, часть красного результата `dcdiag` была связана не с отказом AD replication, а с невозможностью диагностического теста прочитать удалённые журналы через RPC.

## Повторная проверка

После восстановления доступа к Event Log:

```powershell
Get-WinEvent -ComputerName dc02 -LogName "DFS Replication" -MaxEvents 50 |
  Select TimeCreated,Id,LevelDisplayName,Message
```

Затем:

```cmd
dcdiag /e /c /v
repadmin /replsummary
repadmin /showrepl *
```

Важно учитывать, что `DFSREvent` анализирует недавние события. Исторические warning/error записи могут сохранять тест красным некоторое время после восстановления рабочего состояния.

## Что не стоит делать сразу

Если одновременно:

```text
repadmin = OK
SysVolCheck = PASS
NetLogons = PASS
SYSVOL/NETLOGON shares = present
```

не нужно автоматически:

- перестраивать DFSR database;
- выполнять восстановление SYSVOL;
- demote/promote DC;
- менять DNS наугад;
- откатывать DC из snapshot.

Сначала нужно определить, сломан ли replication engine или только диагностический доступ к журналам.

## Диагностический порядок

```text
1. repadmin /replsummary
2. repadmin /showrepl *
3. SYSVOL + NETLOGON
4. dcdiag /test:sysvolcheck
5. dcdiag /test:netlogons
6. DNS / DC Locator
7. RPC/SMB connectivity
8. remote Get-WinEvent
9. DFS Replication events
10. repeat dcdiag
```

## Вывод

Главный урок — не смешивать AD DS replication, DFSR и RPC-доступ к Event Log.

`repadmin` может быть полностью зелёным, а `dcdiag` одновременно показывать `DFSREvent/KccEvent/SystemLog` и `0x6ba`. В этом кейсе важной частью проблемы оказался доступ к удалённым журналам событий через firewall/RPC.

Красный `dcdiag` — повод разложить диагностику по слоям, а не автоматически начинать аварийное восстановление SYSVOL.
