---
title: "Мониторинг Windows Server через windows_exporter и Prometheus"
description: "Production-backed схема мониторинга Windows Server через windows_exporter 0.31.8, Prometheus file_sd, recording rules и alerting."
category: "Мониторинг и безопасность"
tags: ["windows", "windows-exporter", "prometheus", "monitoring", "alerting"]
published: 2026-09-16
updated: 2026-09-16
status: current
testedOn: ["Windows Server 2022 Standard build 20348", "windows_exporter 0.31.8", "Prometheus file_sd"]
featured: true
translationKey: "monitoring/windows-exporter-prometheus-monitoring"
---

## Контекст

Production-схема мониторинга Windows намеренно остаётся простой:

```text
Windows Server
    -> windows_exporter
    -> Prometheus file_sd
    -> recording rules
    -> alerting / Grafana
```

Реальный Windows Server 2022 был проверен по всей цепочке вместе с runtime target в Prometheus и общим файлом правил Windows.

## Подтверждённый production baseline

Проверенный сервер:

```text
Windows Server 2022 Standard
build 20348
windows_exporter 0.31.8
сервис: Running
запуск: Automatic
учётная запись: LocalSystem
listener: TCP/9182
```

Сервис exporter запускается с параметрами:

```text
--config.file="C:\Program Files\windows_exporter\config.yaml"
--collectors.enabled cpu,logical_disk,memory,net,os,physical_disk,service,system,pagefile,time
```

Указанный YAML-файл сейчас пустой, поэтому набор collectors задаётся явно в командной строке сервиса.

На проверенном хосте все включённые collectors возвращали `success=1`.

## Сетевой доступ к exporter

windows_exporter слушает wildcard TCP/9182. Доступ ограничивается Windows Firewall, а не bind на конкретный адрес сервера.

Активное inbound-правило разрешает TCP/9182 только от адреса Prometheus.

Это важное различие:

```text
wildcard listener != неограниченный сетевой доступ
```

Фактическая доступность определяется одновременно listener и firewall scope.

## Discovery в Prometheus

Центральный Prometheus использует file-based service discovery:

```yaml
- job_name: windows
  scrape_interval: 30s
  scrape_timeout: 10s

  file_sd_configs:
    - files:
        - /etc/prometheus/targets/windows/servers.yml
      refresh_interval: 30s
```

Текущий inventory содержит семь Windows Server targets.

Для каждого target задаются labels:

```text
instance
site
role
platform
```

Один legacy terminal server дополнительно помечен label `legacy`.

Санитизированный пример target:

```yaml
- targets:
    - <windows-host>:9182
  labels:
    instance: <server-name>
    site: fm
    role: windows-server
    platform: windows
```

## Runtime-проверка

Недостаточно проверить только YAML. Нужно подтвердить, что Prometheus реально загрузил target.

Проверенный production target показал:

```text
scrape pool: windows
job: windows
health: up
last error: empty
scrape interval: 30s
scrape timeout: 10s
```

Это подтверждает рабочую цепочку Prometheus -> windows_exporter.

## Recording rules

Production-файл правил Windows нормализует базовые host metrics в:

```text
fm:windows:up
fm:windows:cpu_usage_percent
fm:windows:memory_usage_percent
fm:windows:disk_usage_percent
fm:windows:uptime_seconds
```

### CPU

CPU usage рассчитывается по idle-mode метрики `windows_cpu_time_total` на окне 5 минут.

Alert policy:

```text
warning:  90-97% в течение 15m
critical: >=97% в течение 5m
```

### Память

На проверенном windows_exporter 0.31.8 реально присутствуют:

```text
windows_memory_available_bytes
windows_memory_physical_total_bytes
```

Общий recording rule также сохраняет compatibility fallback на старое имя метрики физической памяти. На текущем exporter используется `windows_memory_physical_total_bytes`.

Alert policy:

```text
warning:  >85% used и <=92% в течение 15m
critical: >92% used в течение 5m
```

### Логические диски

В monitoring включены только volumes с буквами дисков:

```promql
volume=~"[A-Z]:"
```

Это сознательно исключает системные разделы вида `HarddiskVolume*`.

Alert policy:

```text
warning:  >85% used и <=93% в течение 15m
critical: >93% used в течение 5m
```

### Uptime

На проверенном exporter присутствует:

```text
windows_system_boot_time_timestamp
```

Rule-файл сохраняет compatibility fallback на старую uptime-метрику, но текущий production path использует boot-time timestamp.

## Контроль самого exporter

Monitoring path защищён тремя отдельными проверками.

Target-count contract ожидает ровно семь Windows targets. Несоответствие в течение двух минут считается critical.

`WindowsExporterDown` срабатывает, если Prometheus не может scrape target в течение трёх минут.

`WindowsCollectorFailed` контролирует:

```promql
windows_exporter_collector_success == 0
```

в течение пяти минут и показывает имя проблемного collector.

## Включённые collectors и реальная alert policy

Сейчас exporter включает:

```text
cpu
logical_disk
memory
net
os
physical_disk
service
system
pagefile
time
```

Общий Windows rule-файл использует CPU, memory, logical disk, system/uptime и exporter-integrity metrics.

Generic fleet-wide alerts для network, physical disk latency, pagefile usage, Windows services или time drift сейчас не определены. Collectors остаются доступны для dashboard и будущих role-specific rules, но эта заметка не добавляет несуществующую production policy.

## Проверка

На Windows:

```powershell
& "C:\Program Files\windows_exporter\windows_exporter.exe" --version
Get-CimInstance Win32_Service -Filter "Name='windows_exporter'"
Get-NetTCPConnection -State Listen -LocalPort 9182
```

Проверка collectors:

```powershell
$Metrics = (Invoke-WebRequest -UseBasicParsing http://127.0.0.1:9182/metrics).Content -split "`r?`n"
$Metrics | Where-Object { $_ -match '^windows_exporter_collector_success' }
```

На Prometheus отдельно проверяются syntax/config validation и runtime target health.

## Процедура добавления нового Windows Server

1. Установить утверждённую версию windows_exporter.
2. Настроить нужный набор collectors.
3. Проверить, что сервис Automatic и Running.
4. Разрешить TCP/9182 в Windows Firewall только от Prometheus.
5. Добавить host в file_sd inventory со стандартными labels.
6. Обновить expected target count.
7. Выполнить проверку конфигурации Prometheus.
8. Перезагрузить конфигурацию Prometheus.
9. Проверить runtime target = UP.
10. Убедиться, что recording rules возвращают данные для нового instance.

## Rollback

Перед изменениями нужно сохранить текущие exporter service parameters, firewall rule, target inventory и версию alert rules.

Rollback состоит в возврате этих настроек, повторной проверке Prometheus configuration и подтверждении, что target и recording rules вернулись в прежнее состояние.

## Что этот слой не доказывает

Нормальные Windows host metrics не означают, что Active Directory, RDP sessions, прикладные сервисы или бизнес-приложения работают корректно.

Host monitoring — это общий машинный слой. Service-specific checks должны добавляться отдельно только там, где они отражают реальные operational requirements.

## Ссылки

- windows_exporter: <https://github.com/prometheus-community/windows_exporter>
- Prometheus file-based service discovery: <https://prometheus.io/docs/prometheus/latest/configuration/configuration/#file_sd_config>
- Prometheus recording rules: <https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/>
- Prometheus alerting rules: <https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/>
