---
title: "Мониторинг сетевого оборудования через SNMP Exporter и Prometheus"
description: "Production-backed схема SNMP-мониторинга MikroTik и Zyxel через snmp_exporter 0.30.1 и Prometheus file-based discovery."
category: "Monitoring & Security"
tags: ["snmp", "prometheus", "snmp-exporter", "mikrotik", "zyxel", "networking"]
published: 2026-09-16
updated: 2026-09-16
status: current
testedOn: ["snmp_exporter 0.30.1", "Prometheus file_sd"]
featured: true
translationKey: "monitoring/snmp-exporter-network-monitoring"
---

## Контекст

Production-слой сетевого мониторинга использует один локальный SNMP Exporter и file-based inventory. Prometheus передаёт exporter'у адрес устройства и набор модулей для каждого target.

```text
Prometheus file_sd
    -> SNMP Exporter на 127.0.0.1:9116
    -> маршрутизаторы / коммутаторы / точки доступа
```

В подтверждённом production inventory находится 19 SNMP-устройств на нескольких площадках. На момент проверки все 19 device targets и self-target самого exporter были `UP`.

## Подтверждённый baseline

```text
snmp_exporter: 0.30.1
platform: linux/amd64
service account: snmp_exporter
listener: 127.0.0.1:9116
```

Exporter работает как отдельный systemd-сервис и доступен только через loopback с хоста Prometheus.

## Prometheus job

Общий job для сетевых устройств использует:

```yaml
- job_name: snmp
  scrape_interval: 60s
  scrape_timeout: 50s
  metrics_path: /snmp

  file_sd_configs:
    - files:
        - /etc/prometheus/targets/snmp/*.yml
      refresh_interval: 30s
```

Relabeling передаёт exporter'у реальный target и выбранный набор модулей, после чего адрес устройства сохраняется в Prometheus как label `instance`.

## Inventory contract

Для каждого устройства используются labels уровня:

```text
site
vendor
model
role
module set
```

Санитизированный пример:

```yaml
- targets:
    - <management-ip>
  labels:
    site: <site>
    vendor: mikrotik
    model: RB5009UG+S+
    role: gateway
    snmp_module: if_mib,mikrotik
```

Inventory разбит по отдельным файлам, поэтому исключения по моделям и ролям остаются явно видимыми.

## Подтверждённые классы устройств

Текущие RouterOS gateway и access point используют:

```text
if_mib,mikrotik
```

RouterOS-устройство, используемое как switch, опрашивается через:

```text
if_mib,hrDevice,hrStorage,mikrotik_switch_system
```

Подтверждённый SwOS target использует только:

```text
if_mib
```

Несколько Zyxel GS1920 используют:

```text
if_mib,zyxel_gs1920_system
```

Часть GS1900 сейчас использует только `if_mib`.

То есть module set определяется конкретной моделью и ролью, а не только vendor.

## Общий интерфейсный слой

`if_mib` является переносимым baseline между vendor'ами и даёт общие сигналы:

```text
administrative state
operational state
speed
traffic counters
errors
discards
interface identity
```

Vendor-specific modules добавляют системные метрики только там, где устройство действительно их поддерживает.

## Верхние уровни мониторинга

Production rules отделяют транспорт SNMP от предметной логики.

Switch alerts покрывают availability, состояние и скорость trunk, CPU, memory, temperature, voltage, system storage, errors/discards и VLAN contract checks.

AP rules покрывают uplink, WLAN state, radio metrics и часть RouterOS wireless-метрик. CAPsMAN и MikroTik IPsec вынесены в отдельные rule groups.

Такое разделение позволяет не смешивать generic SNMP transport с конкретными операционными правилами.

## Runtime validation

Подтверждённое состояние:

```text
19 job="snmp" targets: UP
1 job="snmp_exporter" target: UP
```

Это подтверждает полный путь от Prometheus discovery через exporter до сетевого оборудования.

## Модель диагностики

При падении target нужно разделять возможные failure domains:

```text
недоступен exporter
нет сетевой доступности до устройства
не подходит профиль опроса
module set не поддерживается или слишком тяжёлый
устройство отвечает слишком медленно
```

Рабочий self-target exporter не гарантирует, что все устройства доступны. И наоборот, падение одного device target не означает отказ самого exporter.

## Добавление нового устройства

Безопасная последовательность:

1. определить vendor, model и role;
2. выбрать минимальный module set, который покрывает нужные метрики;
3. добавить target со стандартными inventory labels;
4. дождаться file_sd refresh;
5. проверить, что runtime target стал `UP`;
6. посмотреть реальные метрики;
7. только после этого добавлять role-specific recording и alert rules.

Изменение только target-файла не требует restart Prometheus, потому что используется периодическое file_sd discovery.

## Backup и rollback

Перед изменениями сохраняй exporter unit, SNMP module configuration, Prometheus target inventory и связанные rule files.

После rollback проверь и self-target exporter, и затронутые device targets.

## Чек-лист валидации

```text
[ ] версия exporter известна
[ ] exporter работает от отдельного пользователя
[ ] exporter слушает только ожидаемый адрес
[ ] target содержит site/vendor/model/role metadata
[ ] module set соответствует модели и роли
[ ] Prometheus обнаружил target
[ ] runtime target = UP
[ ] self-target exporter = UP
[ ] реальные метрики просмотрены до создания alerts
```

## References

- SNMP Exporter: <https://github.com/prometheus/snmp_exporter>
- Prometheus file-based service discovery: <https://prometheus.io/docs/prometheus/latest/configuration/configuration/#file_sd_config>
- Prometheus relabeling: <https://prometheus.io/docs/prometheus/latest/configuration/configuration/#relabel_config>
