---
title: "Proxmox VE: сбор evidence перед перезагрузкой зависшей Windows VM"
description: "Production-runbook incident response для сохранения host, QEMU, task и storage evidence до reset или reboot неотвечающей Windows VM."
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

Зависшая Windows VM создаёт давление на инженера: сервис нужно вернуть как можно быстрее. Но немедленный reboot уничтожает часть наиболее полезных evidence.

Первый правильный вопрос — не «как её перезапустить?», а «что ещё можно зафиксировать до изменения состояния?».

Этот runbook сфокусирован на стороне Proxmox. Он рассчитан на ситуацию, когда Windows guest перестал отвечать полностью или частично, но сам Proxmox node всё ещё доступен.

Примеры используют обезличенные VMID и временные интервалы. Замените их фактическими данными инцидента.

## Цели

До reboot или reset гостя постарайтесь сохранить данные, позволяющие ответить на вопросы:

- проблема ограничена одной VM или host испытывал более широкую нагрузку;
- оставался ли QEMU process жив;
- зафиксировал ли Proxmox stop, reset, migration или backup tasks около времени инцидента;
- были ли на host OOM, hung task, blocked I/O, timeout или storage errors;
- продолжала ли VM потреблять CPU или QEMU был заблокирован в kernel I/O;
- совпал ли freeze по времени с backup, migration или storage activity;
- восстановился ли guest после clean shutdown или только после hard reset.

Не превращайте сбор evidence в длительный outage. Цель — компактный и повторяемый capture до уничтожения состояния.

## Первое правило: зафиксируйте окно инцидента

Запишите наиболее вероятное время начала и время подтверждения проблемы.

Пример:

```text
incident_start=2026-08-03 21:30
incident_end=2026-08-03 23:00
vmid=522
node=pve-node09
```

Даже приблизительный интервал полезен. Позже он позволит сопоставить сообщения пользователей, Proxmox tasks, QEMU logs и host-level warnings.

Используйте один и тот же временной интервал во всех этапах расследования.

## Подтвердите VM и node

С любого cluster node:

```bash
pvesh get /cluster/resources --type vm | grep -E '(^|[[:space:]])522([[:space:]]|$)'
```

На текущем hosting node:

```bash
qm status 522
qm config 522
```

Сохраните конфигурацию до любых изменений. Особенно важны:

- machine type;
- CPU type и количество vCPU;
- memory и ballooning settings;
- storage backend и disk format;
- выбранный VirtIO/SCSI controller;
- network model;
- QEMU Guest Agent configuration;
- watchdog configuration, если используется.

Не считайте, что VM находится на node, где она обычно работает. Сначала подтвердите текущего владельца.

## Зафиксируйте состояние cluster и node

Freeze гостя может быть симптомом host или storage problem, поэтому сначала сохраните состояние всей платформы.

```bash
pvecm status
pvesm status
```

Если используется Ceph:

```bash
ceph -s
```

Зафиксируйте базовую нагрузку host:

```bash
uptime
free -h
df -h
```

Для быстрого просмотра scheduler и I/O pressure:

```bash
vmstat 1 5
```

Если установлен `iostat`:

```bash
iostat -xz 1 5
```

Задача не в том, чтобы немедленно доказать root cause. Нужно сохранить факт: host выглядел нормально или был перегружен в тот же момент, когда завис guest.

## Убедитесь, что QEMU process существует

VM может отображаться как `running` в Proxmox, при этом её userspace process уже находится в ненормальном состоянии или ждёт нижележащий слой.

Найдите process:

```bash
pgrep -af 'kvm.*-id 522|qemu-system.*-id 522'
```

Или проверьте PID file:

```bash
cat /run/qemu-server/522.pid 2>/dev/null
```

Затем исследуйте process:

```bash
PID="$(cat /run/qemu-server/522.pid 2>/dev/null)"
ps -o pid,ppid,stat,etime,%cpu,%mem,wchan:32,cmd -p "$PID"
```

Process state и `wchan` особенно полезны, когда QEMU заблокирован в kernel I/O вместо обычного потребления CPU.

Не подключайте debugger и не отправляйте signals как первый шаг, если инцидент не требует более глубокого live analysis. Начинайте с read-only inspection.

## Сохраните историю Proxmox tasks

Найдите операции с VM около окна инцидента.

Для недавней активности удобен cluster task query:

```bash
pvesh get /cluster/tasks --vmid 522 --limit 50
```

Ищите:

- `qmstart`;
- `qmstop`;
- `qmshutdown`;
- `qmreset`;
- migration;
- backup;
- snapshot;
- storage migration;
- replication.

Если task выглядит связанным с инцидентом, зафиксируйте его UPID и сохраните task log до reboot гостя.

Корреляция tasks важна: кажущийся «случайным» freeze может совпасть по времени с backup, migration или storage operation, о которых после восстановления сервиса легко забыть.

## Проверьте host journal по VM и QEMU

Начинайте с узкого временного окна.

```bash
journalctl \
  --since '2026-08-03 21:30:00' \
  --until '2026-08-03 23:00:00' \
  --no-pager | \
grep -Ei 'VM 522|:522:|qemu.?522|qm(stop|shutdown|reset|start).*522'
```

Затем в том же интервале ищите host-level failure indicators:

```bash
journalctl \
  --since '2026-08-03 21:30:00' \
  --until '2026-08-03 23:00:00' \
  --no-pager | \
grep -Ei 'watchdog|oom|out of memory|hung task|blocked for more than|i/o error|input/output error|timeout|reset|nvme|scsi|rbd|ceph|nfs|zfs'
```

Не начинайте с поиска по всему journal. Узкое окно уменьшает нерелевантный шум и делает последующий incident review воспроизводимым.

## Отдельно исследуйте kernel messages

Kernel-level симптомы особенно важны для storage stalls, driver problems и OOM events.

Для текущей загрузки:

```bash
journalctl -k \
  --since '2026-08-03 21:30:00' \
  --until '2026-08-03 23:00:00' \
  --no-pager
```

Или отфильтруйте вероятные признаки:

```bash
journalctl -k \
  --since '2026-08-03 21:30:00' \
  --until '2026-08-03 23:00:00' \
  --no-pager | \
grep -Ei 'oom|hung|blocked|i/o|timeout|reset|nvme|scsi|rbd|ceph|nfs|zfs'
```

Если после инцидента reboot выполнялся уже на самом host, при необходимости исследуйте предыдущую загрузку через `journalctl -b -1`.

## Проверьте OOM evidence

Если QEMU process был убит host OOM killer, внешне это может выглядеть как guest-side outage, хотя реальная причина — memory pressure на host.

```bash
journalctl \
  --since '2026-08-03 21:30:00' \
  --until '2026-08-03 23:00:00' \
  --no-pager | \
grep -Ei 'oom-killer|out of memory|killed process.*qemu|killed process.*kvm'
```

Также сопоставьте memory configuration VM с фактическим состоянием host.

Если используется ballooning, зафиксируйте это. Не считайте настроенный maximum memory единственным значимым параметром памяти для инцидента.

## Проверьте blocked I/O и hung tasks

Windows guest может выглядеть полностью зависшим, когда QEMU ждёт storage, а не когда сама Windows crashed.

Host evidence может содержать сообщения вида:

- task blocked for more than N seconds;
- I/O timeout;
- SCSI/NVMe reset;
- RBD/Ceph timeout;
- NFS server not responding;
- filesystem или block-device errors.

Ищите эти признаки в окне инцидента до reset VM.

Если похожие симптомы одновременно видны у нескольких VM на одном datastore, переносите фокус расследования на storage path, а не рассматривайте каждый guest как отдельную Windows problem.

## Проверьте пересечение со storage и backup activity

Если VM disks находятся на shared storage, сохраните состояние backend, пока freeze ещё воспроизводится.

Для Proxmox storage:

```bash
pvesm status
```

Для Ceph:

```bash
ceph -s
```

Для mounted NFS datastore:

```bash
findmnt -t nfs,nfs4
```

Проверьте, не совпал ли инцидент с backup или migration task. Высокая I/O activity сама по себе не доказывает causation, но потеря временной корреляции сильно ослабляет дальнейший analysis.

## Проверяйте QEMU Guest Agent, но не полагайтесь только на него

Если guest agent включён, его responsiveness — полезный signal:

```bash
qm guest cmd 522 ping
```

Интерпретируйте результат осторожно:

- agent отвечает: Windows или хотя бы agent path ещё частично жив;
- agent не отвечает: guest может быть hung, agent service может быть остановлен или communication path может быть нарушен.

Отсутствие ответа Guest Agent само по себе не доказывает полный freeze VM.

## Разделяйте console, network и OS failure

До reboot определите, что именно недоступно.

Полезно проверить:

- обновляется ли Proxmox console или картинка замерла;
- отвечает ли ICMP;
- отвечает ли RDP port;
- отвечает ли application port;
- отвечает ли QEMU Guest Agent;
- CPU usage VM активен, idle или застрял;
- здоровы ли другие VM на том же host/storage.

Такая классификация помогает разделить:

- Windows service failure;
- Windows OS hang;
- guest network failure;
- QEMU process problem;
- host/storage problem.

Не сводите все эти варианты к одному ярлыку «VM freeze».

## Опционально: сохраните текущий QEMU status

В более сложных инцидентах дополнительное состояние можно получить через QEMU monitor, но на production используйте его осторожно.

```bash
qm monitor 522
```

Read-only monitor commands могут помочь понять, отвечает ли сам QEMU. Не выполняйте state-changing monitor commands, пока они не стали частью осознанного recovery decision.

Для обычных инцидентов host journal, task history, process state и storage health обычно дают больше полезной информации при меньшем operational risk.

## Сохраните evidence до recovery

Небольшой каталог для инцидента обычно достаточен.

Пример:

```bash
mkdir -p /root/incidents/vm-522-20260803
```

Сохраните туда relevant command outputs или перенесите их в incident record до reboot.

Полезные artifacts:

- `qm config`;
- `qm status`;
- cluster и storage status;
- QEMU PID/process state;
- filtered host journal;
- filtered kernel journal;
- task history;
- relevant task logs;
- точный recovery action и timestamp.

Не собирайте secrets, guest memory dumps или нерелевантную конфигурацию, если конкретное расследование этого не требует.

## Выберите между shutdown, stop и reset

Используйте наименее разрушительный recovery action, который всё ещё способен восстановить сервис.

Если guest agent и Windows достаточно responsive, сначала попробуйте normal shutdown:

```bash
qm shutdown 522 --timeout 60
```

Если он не сработал, а impact требует восстановления, следующий шаг зависит от состояния и operational risk.

Hard stop или reset уничтожает guest-side runtime evidence и может вызвать filesystem/application recovery. Иногда это необходимо, но решение должно быть осознанным, а не первым диагностическим действием.

Точно зафиксируйте, какая команда использовалась.

## После recovery сохраните timeline

Когда VM снова работает, расследование не должно заканчиваться фразой «сервис восстановлен».

Запишите:

- время обнаружения freeze;
- окно сбора evidence;
- recovery command и timestamp;
- VM boot time;
- application recovery time;
- есть ли в Windows Event Logs crash, unexpected shutdown, storage или network event;
- были ли связанные симптомы на том же host/storage.

Timeline часто полезнее любой одной строки log.

## Follow-up внутри Windows

После восстановления guest соберите Windows evidence до того, как normal event retention его перезапишет.

Полезные источники:

- System event log;
- Application event log;
- unexpected shutdown events;
- storage/controller warnings;
- NTFS/ReFS events;
- service-specific failures;
- Windows Error Reporting или crash dump data, если настроены;
- performance monitoring data, если доступны.

Сопоставляйте timestamps Windows с timeline Proxmox host. Time synchronization важен: несколько минут drift могут создать ложную последовательность событий.

## Сравнивайте несколько пострадавших VM

Если в одном временном интервале зависло несколько VM, делайте comparison table, а не исследуйте каждый случай изолированно.

Полезные столбцы:

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

Паттерны становятся заметны значительно быстрее.

Три зависших Windows VM на разных nodes, но на одном storage path, указывают в другую сторону, чем три независимых guest OS failures.

## Избегайте слабых выводов

Не делайте вывод «Windows зависла» только потому, что перестал отвечать RDP.

Не делайте вывод «проблема Proxmox» только потому, что VM восстановилась после `qm reset`.

Не делайте вывод «storage problem» только потому, что одновременно выполнялся backup.

Всё это гипотезы. Сначала сохраняйте evidence, затем сопоставляйте timing и scope.

## Минимальный fast-response checklist

Когда outage требует быстрых действий, до reboot сохраните хотя бы это:

```bash
qm status 522
qm config 522
pvecm status
pvesm status
pgrep -af 'kvm.*-id 522|qemu-system.*-id 522'
pvesh get /cluster/tasks --vmid 522 --limit 30
journalctl --since '-30 min' --no-pager | grep -Ei '522|qemu|oom|hung|blocked|i/o|timeout'
```

Затем запишите recovery action и точный timestamp.

Это занимает минуты и сохраняет существенно больше диагностической ценности, чем немедленный reset.

## Stop conditions

Не продолжайте guest-level troubleshooting, если evidence указывает на более широкий infrastructure failure, например:

- пострадало несколько VM на одном host;
- пострадало несколько VM на одном datastore;
- зафиксирован host OOM;
- есть kernel hung-task или blocked-I/O warnings;
- Ceph находится в degraded/inactive state;
- присутствуют NFS timeout или server-not-responding messages;
- повторяются QEMU I/O errors;
- cluster или Corosync нестабилен.

В этот момент защищайте платформу в целом и рассматривайте VM freeze как симптом.

## Эксплуатационные заметки

Лучший incident script — не тот, который собирает максимум данных. Лучший — тот, который оператор способен безопасно выполнить под давлением без изменения состояния системы.

Держите command blocks короткими, работайте с узким временным диапазоном и отделяйте evidence collection от recovery actions.

Reboot может восстановить доступность и одновременно уничтожить единственное evidence, объясняющее причину отказа. Несколько минут на фиксацию host-side state до recovery обычно оправданы.
