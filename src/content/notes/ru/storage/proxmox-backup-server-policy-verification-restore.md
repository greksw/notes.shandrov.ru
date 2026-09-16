---
title: "Proxmox Backup Server: backup policy, exclusions, verification и restore testing"
description: "Production-oriented framework для определения PBS backup coverage, retention, prune и GC jobs, verification, restore drills и явно принятых exclusions."
category: "Хранилища и резервное копирование"
tags: ["proxmox", "pbs", "backup", "restore", "retention", "verification"]
published: 2026-09-16
updated: 2026-09-16
status: current
testedOn: ["Proxmox VE 9.x", "Proxmox Backup Server 4.x", "VM and CT backups"]
featured: true
lang: ru
translationKey: "storage/proxmox-backup-server-policy-verification-restore"
---

## Контекст

Backup system не становится полноценной только потому, что scheduled jobs зелёные.

Production backup policy должна отвечать на более широкий набор вопросов:

- что обязательно должно резервироваться;
- что исключено намеренно;
- как часто выполняются backups;
- сколько хранятся recovery points;
- когда реально освобождается место от unreferenced data;
- читаются ли сохранённые backup data;
- выполнялся ли restore test;
- какой residual recovery risk принят осознанно.

Proxmox Backup Server даёт сильные primitives для deduplicated VM/CT backups, pruning, garbage collection и verification. Их ценность появляется, когда они объединены в явную policy, а не существуют как несвязанные jobs.

Примеры используют generic identifiers. Retention и scheduling должны соответствовать реальным RPO, RTO, storage capacity и criticality workloads.

## Начинайте с coverage policy

Не начинайте с retention string. Начинайте с классификации workloads.

Практичная модель — распределить все VM/CT по нескольким классам:

| Класс | Типичный workload | Ожидание по backup |
| --- | --- | --- |
| Critical | identity, databases, line-of-business services | scheduled backup, tighter RPO, frequent verification, restore drill |
| Standard | обычные production servers | scheduled backup и регулярная verification |
| Rebuildable | automation-managed или легко пересоздаваемые services | backup опционален в зависимости от rebuild cost |
| Excluded | disposable test systems, templates, archived или accepted-risk workloads | без регулярного backup, причина документирована |

Ключевой control — не названия классов, а наличие осознанного статуса у каждого guest.

Unclassified guest — это не accepted exclusion, а unknown.

## Ведите exclusion register

Некоторые guests действительно не оправдывают регулярное использование PBS. Это допустимо, если решение явное.

Примеры:

- краткоживущие test VM;
- templates, которые можно пересоздать из installation media и documented configuration;
- non-critical appliances с immutable configuration;
- abandoned/archive-only systems;
- workloads с намеренно manual recovery method.

Для каждого exclusion фиксируйте минимум:

| Поле | Пример |
| --- | --- |
| Workload | `vm-example-test` |
| Owner / service | infrastructure team |
| Причина | disposable test system |
| Recovery method | redeploy from automation |
| Maximum accepted data loss | all local state |
| Review date | quarterly |

Так «не входит в PBS job» превращается из случайности в risk decision.

## Успешный backup не равен application consistency

Успешная Proxmox backup task доказывает завершение hypervisor-level backup. Она не доказывает автоматически transactionally consistent recovery point для каждого приложения внутри guest.

QEMU Guest Agent может улучшить filesystem coordination для Windows и Linux, если он настроен и поддерживается guest. Databases и другие transactional systems всё равно могут требовать application-aware procedures, dumps, WAL/binlog retention или дополнительных recovery controls.

Разделяйте два вопроса:

1. можно ли восстановить VM/CT;
2. может ли приложение внутри неё чисто восстановиться к нужной точке.

Зелёная PBS task лучше отвечает на первый вопрос, чем на второй.

## Определяйте schedules через RPO

Не используйте один universal schedule для всех workload classes, если требования различаются.

Пример:

| Класс | Пример schedule | Approximate infrastructure RPO |
| --- | --- | --- |
| Critical | every 4 hours | up to 4 hours |
| Standard | nightly | up to 24 hours |
| Rebuildable | weekly or manual | accepted |
| Excluded | none | explicitly accepted |

Schedule должен отражать recovery requirements, а не только объём свободного storage.

Перед увеличением частоты backup убедитесь, что workload, network и storage выдержат её без overlapping jobs и contention.

## Разделяйте frequency и retention

Backup frequency и retention решают разные задачи.

Workload может резервироваться каждые четыре часа, но хранить только полезное подмножество historical points. PBS prune policy поддерживает, например:

- keep last;
- keep hourly;
- keep daily;
- keep weekly;
- keep monthly;
- keep yearly.

Пример retention policy:

```text
keep-last:    6
keep-daily:   14
keep-weekly:  8
keep-monthly: 12
```

Это пример, а не универсальная рекомендация. Retention должен соответствовать business recovery requirements и datastore capacity.

## Prune и garbage collection — разные операции

**Prune** удаляет backup snapshots согласно retention policy.

**Garbage collection** сканирует datastore и освобождает chunks, которые больше не referenced ни одним retained snapshot, с учётом safety rules PBS.

Следовательно:

```text
prune != immediate space reclamation
```

Snapshots могут быть уже удалены prune job, а physical usage почти не изменится до завершения GC.

Это особенно важно во время capacity incident.

## Проверяйте PBS jobs через CLI

На PBS host текущую конфигурацию можно посмотреть так:

```bash
proxmox-backup-manager datastore list
proxmox-backup-manager prune-job list
proxmox-backup-manager garbage-collection list
proxmox-backup-manager verify-job list
```

Эти job families разделены и operationally: retention, space reclamation и integrity checking — независимые controls.

Review job configuration должен быть частью change control, а не предположением, что GUI спустя месяцы всё ещё соответствует первоначальному design.

## Проектируйте prune jobs осознанно

Prune policy должна соответствовать backup frequency.

Если standard VM резервируется nightly, но после pruning остаётся только одна точка в неделю, практическая restore-point density становится weekly независимо от того, сколько backup jobs запускалось между prune runs.

При изменении retention:

1. оцените, сколько snapshots останется;
2. найдите protected/manually important recovery points;
3. при крупных изменениях сначала проверьте policy на non-critical data;
4. review prune task result;
5. дождитесь или запустите controlled GC до оценки reclaimed capacity.

Не меняйте prune и GC policy во время storage emergency, пока не ясно, какие recovery points исчезнут.

## Планируйте GC после prune

GC наиболее полезен после того, как prune сделал chunks unreferenced.

Типичная последовательность:

```text
backup jobs -> prune -> garbage collection -> verification window
```

Точный timing зависит от backup duration и datastore performance. Не запускайте все тяжёлые maintenance tasks одновременно на одном storage, если они конкурируют за I/O.

Проверьте GC jobs:

```bash
proxmox-backup-manager garbage-collection list
```

Для конкретного datastore:

```bash
proxmox-backup-manager garbage-collection status <datastore>
proxmox-backup-manager garbage-collection start <datastore>
```

Manual GC должен быть controlled operation, а не рефлексом при каждом изменении free space.

## Verification — integrity control

PBS verify jobs проверяют stored backup data, чтобы corruption обнаруживалась до дня восстановления.

```bash
proxmox-backup-manager verify-job list
```

Manual run по job ID:

```bash
proxmox-backup-manager verify-job run <job-id>
```

Verification особенно важна для long-lived recovery points, которые могут не читаться месяцами.

Практичная policy — регулярно проверять новые snapshots и повторно верифицировать старые до того, как их предыдущая verification станет operationally stale.

## Verification не заменяет restore test

Verified backup сильнее backup, который ни разу не перечитывался, но он не доказывает, что restored OS/application реально стартует.

Restore test отвечает на другие вопросы:

- можно ли быстро найти нужный backup;
- доступны ли permissions/credentials;
- принимает ли target storage restore;
- загружается ли guest;
- безопасно ли поднимается networking в isolated environment;
- запускается ли application;
- пригодны ли recovered data.

Verification и restore drills — взаимодополняющие controls.

## Делайте restore drills representative workloads

Не ждите реального outage, чтобы впервые выяснять restore procedure.

Выбирайте representative workloads из critical classes:

- один Windows server;
- одну Linux VM;
- один container;
- workload с крупными virtual disks;
- workload со своими application-consistency requirements.

Восстанавливайте под временным VMID/CTID и изолируйте network перед boot, если duplicate addresses, domain membership или production services могут создать конфликт.

Для VM restore Proxmox VE поддерживает `qmrestore`:

```bash
qmrestore <backup-volume> <temporary-vmid> --storage <target-storage>
```

Точный backup-volume identifier лучше копировать из реального storage content view, а не собирать вручную.

Удаляйте temporary guest только после фиксации recovery evidence.

## Проверяйте recovery path, а не только data

Полезный restore drill фиксирует timestamps:

```text
T0  incident declared
T1  correct backup identified
T2  restore started
T3  VM/CT restore completed
T4  guest booted
T5  application validated
```

Так появляется observed recovery time вместо предположительного RTO.

Если restore слишком медленный, причина может быть в network throughput, target storage, datastore contention, large disk size или просто нереалистичном RTO.

## Проверяйте coverage после инфраструктурных изменений

Backup coverage часто ломается потому, что infrastructure меняется быстрее backup schedule.

Review нужен, когда:

- создана новая VM/CT;
- workload перешёл из test в production;
- template стал long-lived server;
- VM мигрировала в другой cluster;
- изменились storage/PBS credentials;
- старый exclusion больше не оправдан.

После каждого существенного изменения проверьте, находится ли guest в правильной backup class и job.

Не рассчитывайте «добавить потом по памяти».

## Failed backup для critical workload — service failure

Регулярно падающий scheduled backup нельзя считать обычным noise.

Разделяйте возможные причины:

- guest lock или другая active task;
- storage unavailable;
- network interruption;
- PBS authentication/permission issue;
- snapshot/guest-agent problem;
- datastore capacity pressure;
- overlapping maintenance;
- unhealthy source storage.

Исправляйте cause, а не просто rerun task до первого green result.

## Capacity planning при deduplication

PBS deduplication означает, что logical backup size и physical datastore growth не равны.

Это усложняет простые capacity formulas, особенно для похожих VM, но deduplication не означает unlimited capacity.

Отслеживайте:

- datastore physical usage;
- recent growth rate;
- GC reclaimed bytes;
- количество protected snapshots;
- крупные новые workloads;
- retention-policy changes.

Если datastore регулярно спасается только «героическим» GC, это уже capacity-planning problem.

## Защищайте сам backup server

PBS — часть recovery path и не должен полностью разделять failure domains защищаемого cluster.

Минимально стоит разделять:

- management credentials;
- storage failure domain;
- network path;
- administrative access;
- monitoring/alerting.

Если risk model требует, добавьте второй PBS, remote sync или offline/offsite copy. Один PBS остаётся single backup-system failure domain даже при deduplicated и verified data.

## Offsite или second copy

Local PBS хорошо защищает от многих guest/cluster failures, но не обязательно от site loss, ransomware с administrative reach или одновременной гибели storage.

PBS поддерживает datastore synchronization на другой backup server. Нужна ли она — зависит от business impact и threat model.

Ключевое различие:

```text
backup copy != independent disaster-recovery copy
```

Документируйте наличие offsite recovery. Если его нет — фиксируйте residual risk явно.

## Accepted-risk exclusions

Exclusion допустим только если:

- workload идентифицирован;
- причина документирована;
- recovery method известен;
- maximum data loss понятен;
- у решения есть owner;
- exclusion периодически пересматривается.

Нормальные примеры — disposable test VM или services, полностью rebuildable из version-controlled automation.

Плохие примеры — «backup job переполнен» или «никто не добавил».

## Templates и archive systems

Templates и archive-only VM часто требуют иного подхода.

Если template воспроизводим из installation media, cloud-init, automation и packages, manual/infrequent backup может быть достаточен.

Если archive VM содержит unique historical data, её низкая runtime criticality не делает автоматически низкой backup importance.

Классифицируйте по recoverability и data value, а не CPU usage.

## Application-specific backup layers

PBS должен сосуществовать с application-native backup там, где это действительно улучшает recovery.

Примеры:

- PostgreSQL base backup + WAL strategy;
- logical database dumps;
- Mailcow/application-level configuration exports, если позволяют ресурсы;
- directory-service-aware recovery procedures;
- file-level copy с отдельной retention policy.

Это defense in depth, а не требование дублировать backup mechanisms для каждого workload.

## Минимальный operational review

Периодический PBS review должен отвечать на вопросы:

```text
Все ли production workloads классифицированы?
Exclusions всё ещё намеренные?
Scheduled backup jobs проходят?
Prune jobs сохраняют нужную историю?
Garbage collection завершается нормально?
Verify jobs успешны?
Недавно выполнялся representative restore?
Datastore growth находится в ожидаемых пределах?
Offsite/second-copy risk явно рассмотрен?
```

Это полезнее простого просмотра last backup timestamp.

## Stop conditions

Не меняйте retention и не удаляйте recovery points, если:

- business owner не может подтвердить, какие historical points ещё нужны;
- verification даёт необъяснимые failures;
- datastore/filesystem unhealthy;
- active backup jobs продолжают писать в affected datastore;
- prune change удалит единственный known-good recovery point;
- recovery path никогда не тестировался, а workload critical.

Во время storage-capacity incident освобождение места не всегда важнее сохранения единственной рабочей restore point.

## Какие recovery evidence сохранять

Для critical restore drills и реальных recoveries фиксируйте:

- source backup timestamp;
- PBS datastore и namespace;
- restore target;
- restore start/end time;
- boot result;
- application validation result;
- manual steps;
- observed RTO;
- data gap относительно required RPO.

Так recovery превращается из tribal knowledge в operational procedure.

## Production pattern

Практичный PBS design прост:

```text
classify workloads
  -> schedule backups
  -> document exclusions
  -> prune intentionally
  -> run GC
  -> verify stored backups
  -> perform restore drills
  -> review accepted risk
```

Сильный признак зрелости — не «все backup jobs green», а понимание того, что защищено, что намеренно не защищено и сколько реально занимает tested recovery.

## References

- Proxmox Backup Server documentation: <https://pbs.proxmox.com/docs/>
- Proxmox Backup Server Administration Guide: <https://pbs.proxmox.com/docs/proxmox-backup.pdf>
- Proxmox VE backup and restore documentation: <https://pve.proxmox.com/pve-docs/chapter-vzdump.html>
