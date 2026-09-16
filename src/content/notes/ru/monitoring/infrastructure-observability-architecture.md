---
title: "Архитектура мониторинга и observability: Prometheus, Grafana, Loki, Zabbix и Wazuh"
description: "Production-схема объединения метрик, проверок доступности, логов и security telemetry для Linux, Windows, виртуализации, storage, баз данных, телефонии и сетевой инфраструктуры."
category: "Мониторинг и безопасность"
tags: ["prometheus", "grafana", "loki", "zabbix", "wazuh", "rsyslog", "observability"]
published: 2026-09-16
updated: 2026-09-16
status: current
testedOn: ["Prometheus", "Grafana", "Loki", "Zabbix", "Wazuh", "rsyslog"]
featured: true
lang: ru
translationKey: "monitoring/infrastructure-observability-architecture"
---

## Контекст

Production-мониторинг становится сложным задолго до того, как самому серверу мониторинга перестаёт хватать CPU или RAM.

Основная сложность — разнообразие источников и типов сигналов:

- Linux- и Windows-серверы;
- Proxmox VE, backup и storage;
- PostgreSQL/Postgres Pro и прикладные метрики;
- 1С:Предприятие;
- Asterisk и VoIP;
- почтовая инфраструктура;
- MikroTik RouterOS и SwOS;
- Zyxel-коммутаторы и access-инфраструктура;
- централизованные логи;
- security events.

Один способ сбора не подходит для всех этих систем. Поэтому практическая архитектура — это не «Prometheus вместо Zabbix» и не «Grafana вместо всего остального», а разделение сигналов по назначению.

Эта заметка описывает архитектурную модель multi-site observability-платформы. Конкретные реализации по классам систем выносятся в отдельные runbook'и.

## Эксплуатационная модель

Базовая цепочка выглядит так:

```text
observe -> detect -> correlate -> diagnose -> act
```

Ключевая часть — корреляция. Для нормального разбора инцидента часто одновременно нужны:

```text
метрики хоста
состояние сети
доступность сервиса
прикладные метрики
логи
security events
```

Один график CPU редко объясняет инфраструктурный инцидент.

## Общая архитектура

```text
                     инфраструктура и сервисы
                                |
           +--------------------+--------------------+
           |                    |                    |
           v                    v                    v
        метрики              проверки              логи
           |                    |                    |
           v                    v                    v
      Prometheus             Zabbix          Loki / rsyslog
           |                    |                    |
           +--------------------+--------------------+
                                |
                                v
                             Grafana
                                |
                                v
                      dashboards / диагностика

security telemetry ---------------------------------> Wazuh
                                                         |
                                                         v
                                               контекст расследования
```

Схема функциональная, а не привязанная к конкретным серверам. В production разные collectors и storage-компоненты могут жить отдельно, а площадки — использовать разные пути доставки данных.

## Зачем несколько систем мониторинга

### Prometheus: временные ряды

Prometheus удобен там, где нужно собирать числовые значения и анализировать их во времени:

```text
CPU
RAM
filesystem
interface counters
latency
queue depth
PostgreSQL statistics
application counters
virtualization state
```

Exporters и API integrations приводят эти данные к общей time-series модели.

### Grafana: визуализация и расследование

Grafana — операторский слой для dashboards и сопоставления сигналов. Это не сам источник истины.

Полезный dashboard должен помогать отвечать на эксплуатационные вопросы:

- проблема на одном хосте или на всей площадке;
- деградация началась до или после события приложения;
- связана ли деградация VM со storage latency;
- росли ли interface errors до появления packet loss.

### Zabbix: проверки инфраструктуры и зрелая host/service-модель

Zabbix остаётся удобным для классического инфраструктурного мониторинга, availability checks, сетевого оборудования и сред, где уже есть agent/SNMP/template-модель.

Prometheus рядом с Zabbix — не обязательно дублирование. Они могут собирать разные классы сигналов с одной инфраструктуры.

### Loki и rsyslog: контекст из логов

Метрики хорошо отвечают на вопрос «что изменилось?», но хуже — «почему?».

Централизованные логи помогают связать отказ с:

```text
systemd/service events
kernel/storage messages
network events
application errors
mail delivery events
authentication events
```

rsyslog может выполнять роль collection/forwarding-слоя, а Loki — давать поиск и привязку логов к observability workflow.

### Wazuh: security telemetry

События безопасности лучше держать отдельным классом сигналов.

Wazuh добавляет host security events, agent telemetry и SCA, не превращая обычные performance dashboards в SIEM-интерфейс.

При расследовании operational и security signals при этом можно сопоставлять.

## Классы систем

Эксплуатировать платформу проще, если группировать targets по тому, что нужно наблюдать, а не только по ОС.

### Linux-серверы

Типовой baseline:

```text
CPU / load
memory / swap
filesystem capacity
inode usage
network interfaces
systemd services
kernel/storage signals
availability
```

Prometheus/node exporter хорошо подходит для метрик, а Zabbix может продолжать отвечать за availability и существующие templates.

### Windows Server

Windows требует отдельной модели сбора, а не подхода «Linux с другими labels».

Обычно полезны:

```text
CPU и RAM
logical disks
network interfaces
Windows services
uptime
выбранные performance counters
состояние role-specific сервисов
```

Детали windows_exporter и service monitoring лучше держать в отдельном runbook.

### Proxmox VE, backup и storage

Для гипервизоров нужны и host-level, и platform-level сигналы.

Одних метрик ОС недостаточно для:

```text
cluster state
node state
VM / CT state
storage state
backup platform health
API-level resource information
```

Для Proxmox VE API exporter дополняет node_exporter. API-доступ лучше давать через read-only account/token и нормальную TLS verification, без administrator password и отключения проверки сертификатов.

PBS и TrueNAS стоит считать отдельными классами сервисов, даже если они основаны на Linux.

## Прикладной мониторинг

Общий Linux dashboard не должен объяснять все проблемы БД, АТС или почты.

### PostgreSQL / Postgres Pro

Для БД нужны database-native сигналы:

```text
connections
transactions
locks
cache/activity statistics
database size
replication state, если используется
query/workload indicators
```

В текущем окружении для Prometheus используется `postgres_exporter`. На 1С-сервере он дополняется отдельными 1С-метриками, а не попыткой определять здоровье приложения только по процессу PostgreSQL.

### 1С:Предприятие

Здесь важны другие вопросы:

```text
доступен ли сервис 1С;
работает ли ожидаемый instance платформы;
отвечает ли приложение;
нормальны ли прикладные counters.
```

На production-сервере 1С отдельный metrics service/timer отделяет прикладной сбор от общего мониторинга ОС.

### Asterisk

Для PBX нужны service-level и telephony-level сигналы.

Отдельный Asterisk-runbook должен как минимум различать:

```text
process/service health
channels/calls
trunks/registrations
endpoint state
call-path failures
system resource usage
logs
```

Запущенный процесс `asterisk` не доказывает, что входящие и исходящие звонки реально работают.

### Почтовая инфраструктура

Мониторинг почты должен сочетать состояние платформы и поведение приложения:

```text
SMTP reachability
queue/deferred growth
container/service health
disk capacity
TLS/certificate state
delivery errors
mail logs
```

Проблемы доставки часто требуют одновременно метрик и анализа логов.

## Сетевой мониторинг

Сетевое оборудование нельзя считать одним однородным классом targets.

### MikroTik RouterOS

RouterOS позволяет собирать гораздо больше, чем ICMP availability:

```text
interface state и counters
errors / drops
CPU / RAM
board temperature, где доступно
uplink state
routing/VPN state, если нужно
```

Способ сбора лучше выбирать по классу устройства и firmware, а не навязывать один механизм всем RouterOS-системам.

### MikroTik SwOS / RB260-class

SwOS лучше вынести в отдельный runbook, потому что у него нет management-модели RouterOS.

Для облегчённых коммутаторов уровня RB260 логичный общий знаменатель — SNMP.

Типовой baseline:

```text
port link state
traffic counters
errors
доступные hardware health metrics
```

Набор метрик зависит от модели и версии SwOS, поэтому dashboard не должен предполагать наличие RouterOS-specific counters.

### Zyxel

Zyxel switches и access-инфраструктуру также нужно строить вокруг реально доступных OID конкретной модели и firmware.

Полезный SNMP baseline:

```text
interface state
traffic
errors/discards
CPU / RAM, если экспортируются
temperature/PoE state, если экспортируются
uptime и device availability
```

Model-specific OID лучше хранить в отдельных notes/templates, а не в архитектурной статье.

## Идентичность и labels

Multi-site мониторинг быстро становится неудобным, если один сервер по-разному называется в Prometheus, Grafana, Zabbix и логах.

Стоит держать небольшой стабильный набор измерений:

```text
site
host
role
platform
service
environment
```

Например, один database host может одновременно описываться так:

```text
site=office
platform=linux
role=database
service=postgresql
```

Конкретные labels зависят от среды, но важна единообразность.

Не стоит помещать в Prometheus labels быстро меняющиеся или практически неограниченные значения. High-cardinality labels ухудшают хранение и запросы.

## Метрики и логи — разные сигналы

Не нужно пытаться заменить одно другим.

Метрики лучше подходят для:

```text
rates
thresholds
trends
capacity
SLO-style measurements
alert conditions
```

Логи — для:

```text
error details
state transitions
rare events
stack traces
protocol/application context
forensic timelines
```

Dashboard может связывать оба типа данных, но retention и query-модель у них разные.

## Alerting

Цель — не создать alert для каждой метрики.

Нормальный alert должен отвечать минимум на три вопроса:

```text
что сломалось;
где сломалось;
что проверить дальше.
```

Полезные примеры:

```text
service недоступен значимое время
filesystem приближается к заполнению
устойчивый packet loss / interface errors
database connectivity/health failure
cluster/node degradation
backup failure
рост mail queue выше обычного уровня
```

Кратковременный шум не стоит превращать в постоянные оповещения. Alert fatigue снижает доверие даже к хорошим alerts.

## Dashboards

Лучше строить dashboards по эксплуатационным вопросам, а не по имени exporter.

Удобная иерархия:

```text
все площадки
  -> класс платформы
     -> класс сервиса
        -> отдельный host/device
```

Например:

```text
All sites
Linux servers
Windows servers
Proxmox clusters
Storage / backup
PostgreSQL / 1C
Asterisk
Mail
Network devices
```

Это удобнее при инциденте, чем плоский список exporter-specific dashboards.

## Проверка мониторинга

Мониторинг тоже нужно проверять.

Для каждого нового класса targets полезно подтвердить:

```text
collector/exporter доступен
scrape/check успешен
labels корректно идентифицируют target
ключевые метрики меняются вместе с реальной системой
dashboards не показывают молча устаревшие данные
alert можно безопасно протестировать
логи приходят с правильным host/site identity
```

Зелёный exporter endpoint доказывает только работоспособность сбора. Он не доказывает, что выбранные метрики корректно отражают здоровье приложения.

## Отказы самой observability-платформы

Monitoring stack не должен создавать новый blind spot.

Нужно учитывать, например:

```text
Prometheus unavailable
Grafana unavailable
Loki unavailable
site-to-site link down
collector/exporter down
SNMP blocked
token/credentials expired
certificate validation failure
time drift
```

Где возможно, один путь мониторинга должен помогать заметить отказ другого. Например, availability check может увидеть, что exporter перестал отвечать, хотя сам host ещё доступен.

## Public bootstrap и production-платформа — не одно и то же

Публичный репозиторий `prometheus-monitoring-stack` — компактный bootstrap/reference implementation для Prometheus, node exporter и Grafana на небольшом Debian/Ubuntu monitoring node:

<https://github.com/greksw/prometheus-monitoring-stack>

Это намеренно не копия полной production observability topology. Production-среда включает больше классов systems, collection methods и operational tooling, чем должен повторять публичный bootstrap installer.

## Серия runbook'ов

Эта статья — родительская для более конкретных материалов:

```text
Linux server monitoring
Windows Server monitoring
PostgreSQL / Postgres Pro monitoring
1C:Enterprise monitoring
Asterisk monitoring
Proxmox VE monitoring
PBS monitoring
TrueNAS / storage monitoring
MikroTik RouterOS monitoring
MikroTik SwOS monitoring
Zyxel monitoring
mail-service monitoring
centralized logs with Loki
```

В каждом дочернем runbook имеет смысл показывать реальный collection method, target configuration, validation, alerting и ограничения конкретного класса систем.

## References

- Prometheus documentation: <https://prometheus.io/docs/>
- Grafana documentation: <https://grafana.com/docs/grafana/latest/>
- Loki documentation: <https://grafana.com/docs/loki/latest/>
- Zabbix documentation: <https://www.zabbix.com/documentation/current/en/manual>
- Wazuh documentation: <https://documentation.wazuh.com/current/>
- rsyslog documentation: <https://www.rsyslog.com/doc/>
