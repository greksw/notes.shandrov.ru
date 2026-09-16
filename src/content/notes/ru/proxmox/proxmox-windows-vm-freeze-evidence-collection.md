---
title: "Proxmox VE: сбор диагностических данных перед перезагрузкой зависшей Windows VM"
description: "Runbook реагирования на инцидент: как сохранить данные Proxmox, QEMU, задач и storage до reset или reboot неотвечающей Windows VM."
category: "Proxmox и виртуализация"
tags: ["proxmox", "windows", "incident-response", "qemu", "troubleshooting", "forensics"]
published: 2026-09-16
updated: 2026-09-16
status: current
testedOn: ["Proxmox VE 9.x", "Windows Server guests", "systemd journal"]
featured: true
lang: ru
translationKey: "proxmox/proxmox-windows-vm-freeze-evidence-collection"
---

## Контекст

Когда Windows VM зависает, естественное желание — как можно быстрее перезапустить её и вернуть сервис. Но немедленный reboot или reset уничтожает часть диагностических данных, которые могли бы объяснить причину отказа.

Первый вопрос должен быть не «как её перезапустить?», а «что можно успеть зафиксировать до изменения состояния?».

Этот runbook посвящён стороне Proxmox. Он рассчитан на ситуацию, когда Windows guest перестал отвечать полностью или частично, но сам Proxmox node остаётся доступен.

Примеры используют обезличенные VMID и временные интервалы. Подставляйте фактические данные инцидента.

## Что нужно выяснить

До reboot или reset постарайтесь собрать данные, которые помогут ответить:

- проблема затронула только одну VM или весь host;
- жив ли QEMU process;
- были ли рядом по времени backup, migration, snapshot, stop или reset tasks;
- есть ли на host признаки OOM, hung task, blocked I/O, timeout или storage errors;
- продолжает ли VM потреблять CPU или QEMU ждёт I/O;
- совпадает ли freeze со storage activity;
- удалось ли восстановить guest штатным shutdown или потребовался hard reset.

Сбор данных не должен превращаться в длительный outage. Цель — короткий, повторяемый набор действий перед восстановлением сервиса.

## Зафиксируйте окно инцидента

Запишите наиболее вероятное время начала проблемы и время её подтверждения.

Пример:

```text
incident_start=2026-08-03 21:30
incident_end=2026-08-03 23:00
vmid=522
node=pve-node09
```

Даже приблизительный интервал полезен. Он позволяет позже сопоставить обращения пользователей, Proxmox tasks, QEMU, journal и storage events.

## Подтвердите VM и текущий node

С любого узла кластера:

```bash
pvesh get /cluster/resources --type vm | grep -E '(^|[[:space:]])522([[:space:]]|$)'
```

На текущем hosting node:

```bash
qm status 522
qm config 522
```

Сохраните конфигурацию до любых изменений.

Особенно важны:

- machine type;
- CPU type и vCPU;
- memory и ballooning;
- storage backend;
- VirtIO/SCSI controller;
- network model;
- QEMU Guest Agent;
- watchdog, если используется.

Не предполагайте, что VM находится на привычном узле. Сначала подтвердите фактический hosting node.

## Зафиксируйте состояние кластера и host

Freeze одной VM может быть симптомом общей проблемы host или storage.

```bash
pvecm status
pvesm status
```

Если используется Ceph:

```bash
ceph -s
```

Базовая нагрузка host:

```bash
uptime
free -h
df -h
```

Быстрый снимок scheduler и I/O pressure:

```bash
vmstat 1 5
```

Если установлен `iostat`:

```bash
iostat -xz 1 5
```

Цель — зафиксировать, выглядел ли host нормально или одновременно испытывал нагрузку.

## Проверьте QEMU process

VM может отображаться как `running`, хотя QEMU process уже работает ненормально или ждёт нижележащий I/O.

Найдите process:

```bash
pgrep -af 'kvm.*-id 522|qemu-system.*-id 522'
```

Или PID file:

```bash
cat /run/qemu-server/522.pid 2>/dev/null
```

Затем:

```bash
PID="$(cat /run/qemu-server/522.pid 2>/dev/null)"
ps -o pid,ppid,stat,etime,%cpu,%mem,wchan:32,cmd -p "$PID"
```

`stat` и `wchan` могут показать, что QEMU не нагружает CPU, а заблокирован в kernel I/O.

Не начинайте с debugger или signals. Сначала собирайте данные без изменения состояния VM.

## Проверьте историю задач Proxmox

Для недавней активности:

```bash
pvesh get /cluster/tasks --vmid 522 --limit 50
```

Ищите операции:

- `qmstart`;
- `qmstop`;
- `qmshutdown`;
- `qmreset`;
- migration;
- backup;
- snapshot;
- storage migration;
- replication.

Если задача выглядит связанной с инцидентом, сохраните UPID и её log до перезапуска гостя.

Корреляция по времени часто помогает обнаружить связь между freeze и backup/migration/storage activity.

## Проверьте systemd journal

Сначала работайте с узким окном.

```bash
journalctl \
  --since '2026-08-03 21:30:00' \
  --until '2026-08-03 23:00:00' \
  --no-pager | \
grep -Ei 'VM 522|:522:|qemu.?522|qm(stop|shutdown|reset|start).*522'
```

Затем ищите host-level failures:

```bash
journalctl \
  --since '2026-08-03 21:30:00' \
  --until '2026-08-03 23:00:00' \
  --no-pager | \
grep -Ei 'watchdog|oom|out of memory|hung task|blocked for more than|i/o error|input/output error|timeout|reset|nvme|scsi|rbd|ceph|nfs|zfs'
```

Узкий временной интервал уменьшает шум и упрощает повторный анализ.

## Отдельно проверьте kernel journal

```bash
journalctl -k \
  --since '2026-08-03 21:30:00' \
  --until '2026-08-03 23:00:00' \
  --no-pager
```

Или только вероятные признаки:

```bash
journalctl -k \
  --since '2026-08-03 21:30:00' \
  --until '2026-08-03 23:00:00' \
  --no-pager | \
grep -Ei 'oom|hung|blocked|i/o|timeout|reset|nvme|scsi|rbd|ceph|nfs|zfs'
```

Если host уже перезагружался после инцидента, при необходимости изучите предыдущую загрузку через `journalctl -b -1`.

## Проверьте OOM

```bash
journalctl \
  --since '2026-08-03 21:30:00' \
  --until '2026-08-03 23:00:00' \
  --no-pager | \
grep -Ei 'oom-killer|out of memory|killed process.*qemu|killed process.*kvm'
```

Если QEMU был убит OOM killer, проблема находится на host, а не обязательно внутри Windows.

При включённом ballooning учитывайте фактическое распределение памяти, а не только configured maximum.

## Ищите blocked I/O и hung tasks

Windows VM может выглядеть полностью зависшей, когда QEMU ждёт storage.

Характерные признаки:

- `task blocked for more than ...`;
- I/O timeout;
- SCSI/NVMe reset;
- RBD/Ceph timeout;
- `NFS server not responding`;
- filesystem или block-device errors.

Если похожие симптомы одновременно появились у нескольких VM на одном datastore, смещайте фокус с Windows на storage path.

## Проверьте пересечение с backup и storage activity

Для Proxmox storage:

```bash
pvesm status
```

Для Ceph:

```bash
ceph -s
```

Для NFS:

```bash
findmnt -t nfs,nfs4
```

Сам факт активного backup не доказывает причину. Но временную корреляцию нужно сохранить до reboot.

## QEMU Guest Agent — полезный сигнал, но не доказательство

Если guest agent включён:

```bash
qm guest cmd 522 ping
```

Интерпретация:

- agent отвечает — часть guest path всё ещё жива;
- agent не отвечает — guest может быть hung, agent service может быть остановлен или сломан communication path.

Отсутствие ответа Guest Agent само по себе не доказывает полный freeze VM.

## Разделяйте console, network и OS failure

До reboot проверьте:

- обновляется ли Proxmox console;
- отвечает ли ICMP;
- отвечает ли RDP port;
- отвечает ли application port;
- отвечает ли Guest Agent;
- активен ли CPU usage VM;
- здоровы ли другие VM на том же host/storage.

Это помогает разделить:

- отказ Windows service;
- hang Windows OS;
- guest network failure;
- проблему QEMU;
- проблему host/storage.

Не сводите все варианты к одному ярлыку «VM зависла».

## QEMU monitor — только при необходимости

При более глубоком расследовании можно открыть:

```bash
qm monitor 522
```

Используйте только read-only monitor commands, если они нужны для диагностики. Не выполняйте state-changing commands без отдельного recovery decision.

Для обычного инцидента journal, task history, process state и storage health обычно полезнее и безопаснее.

## Сохраните данные до recovery

Пример каталога:

```bash
mkdir -p /root/incidents/vm-522-20260803
```

Полезно сохранить:

- `qm config`;
- `qm status`;
- cluster/storage status;
- PID и process state QEMU;
- отфильтрованный host journal;
- kernel journal;
- task history;
- relevant task logs;
- точное recovery action и timestamp.

Не собирайте secrets или guest memory dump без необходимости.

## Выбирайте наименее разрушительное восстановление

Если Windows и Guest Agent ещё отвечают, сначала попробуйте штатный shutdown:

```bash
qm shutdown 522 --timeout 60
```

Если это не помогло, дальнейшее действие зависит от состояния и допустимого outage.

Hard stop или reset уничтожит runtime evidence внутри guest и может вызвать filesystem/application recovery. Иногда это необходимо, но такое действие должно быть осознанным и зафиксированным.

## После восстановления сохраните timeline

Запишите:

- время обнаружения freeze;
- окно сбора diagnostics;
- recovery command и timestamp;
- время загрузки VM;
- время восстановления приложения;
- были ли Windows Event Logs с crash, unexpected shutdown, storage или network errors;
- были ли похожие симптомы на том же host/storage.

Timeline часто ценнее одной отдельной строки log.

## Windows-side follow-up

После восстановления гостя соберите:

- System event log;
- Application event log;
- unexpected shutdown events;
- storage/controller warnings;
- NTFS/ReFS events;
- service-specific failures;
- Windows Error Reporting;
- crash dump, если настроен;
- performance monitoring data, если есть.

Сопоставляйте timestamps Windows и Proxmox. Даже небольшой clock drift может исказить последовательность событий.

## Если зависло несколько VM

Сравнивайте инциденты в таблице:

| Поле | Пример |
| --- | --- |
| VM ID | `522` |
| node | `pve-node09` |
| storage | `shared-rbd` |
| freeze time | `21:42` |
| QEMU alive | yes |
| guest agent | no response |
| host OOM | no |
| I/O warnings | yes/no |
| overlapping backup | yes/no |
| recovery action | reset |

Три зависших Windows VM на разных nodes, но на одном storage path, указывают на другое направление расследования, чем три независимых guest OS failures.

## Избегайте слабых выводов

Не делайте вывод «Windows зависла» только потому, что перестал отвечать RDP.

Не делайте вывод «проблема Proxmox» только потому, что VM восстановилась после reset.

Не делайте вывод «storage виноват» только потому, что одновременно выполнялся backup.

Это гипотезы. Сначала сохраняйте данные, затем сопоставляйте время, охват и общие признаки.

## Минимальный набор при дефиците времени

```bash
qm status 522
qm config 522
pvecm status
pvesm status
pgrep -af 'kvm.*-id 522|qemu-system.*-id 522'
pvesh get /cluster/tasks --vmid 522 --limit 30
journalctl --since '-30 min' --no-pager | grep -Ei '522|qemu|oom|hung|blocked|i/o|timeout'
```

После этого запишите recovery action и точное время.

## Условия остановки

Не продолжайте guest-level troubleshooting, если данные показывают более широкий infrastructure failure:

- пострадало несколько VM на одном host;
- пострадало несколько VM на одном datastore;
- зафиксирован host OOM;
- есть kernel hung-task или blocked-I/O warnings;
- Ceph в degraded/inactive state;
- есть NFS timeout или `server not responding`;
- повторяются QEMU I/O errors;
- cluster или Corosync нестабилен.

В такой ситуации VM freeze нужно рассматривать как симптом проблемы платформы.

## Эксплуатационный вывод

Лучший incident runbook — не тот, который собирает максимум данных, а тот, который инженер способен безопасно выполнить под давлением за несколько минут.

Держите команды короткими, используйте узкое временное окно и всегда отделяйте диагностику от действий, меняющих состояние VM.

Reboot может вернуть доступность и одновременно уничтожить единственные данные, объясняющие причину отказа.
