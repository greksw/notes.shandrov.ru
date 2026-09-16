---
title: "Мониторинг 1С:Предприятия через node_exporter textfile collector, Prometheus и Grafana"
description: "Production-схема мониторинга 1С:Предприятие 8 через systemd timer, собственный shell-collector, textfile collector node_exporter, Prometheus и Grafana."
category: "Мониторинг и безопасность"
tags: ["1c", "prometheus", "node-exporter", "grafana", "systemd", "monitoring"]
published: 2026-09-16
updated: 2026-09-16
status: current
testedOn: ["AlmaLinux 9.8", "1C:Enterprise 8.3.27.2325", "node_exporter textfile collector", "Prometheus", "Grafana"]
featured: true
lang: ru
translationKey: "monitoring/1c-enterprise-prometheus-textfile-monitoring"
---

## Контекст

Обычный мониторинг Linux хорошо показывает CPU, память, файловые системы и сеть, но не отвечает на базовые вопросы по серверу 1С:

```text
активен ли нужный systemd-сервис 1С?
есть ли процессы ragent/rmngr/rphost?
слушаются ли ожидаемые порты кластера?
не перестал ли обновляться сам collector?
```

В production для этих проверок используется небольшой локальный collector, который формирует метрики Prometheus и передаёт их через уже работающий `node_exporter` textfile collector.

Фактическая цепочка:

```text
1С:Предприятие 8.3.27.2325
        |
        v
/usr/local/sbin/fm-1c-metrics.sh
        |
        v
/var/lib/node_exporter/textfile_collector/fm_1c.prom
        |
        v
node_exporter
        |
        v
Prometheus
        |
        v
Grafana / alerting
```

Для локального состояния одного хоста это проще и надёжнее, чем отдельный постоянно работающий exporter.

## Подтверждённый production baseline

```text
OS: AlmaLinux 9.8
1С: 8.3.27.2325
systemd instance: srv1cv8-8.3.27.2325@default.service
collector service: fm-1c-metrics.service
collector timer: fm-1c-metrics.timer
collector script: /usr/local/sbin/fm-1c-metrics.sh
output: /var/lib/node_exporter/textfile_collector/fm_1c.prom
interval: 30 секунд
```

`fm-1c-metrics.service` имеет `Type=oneshot`, поэтому состояние `inactive (dead)` между запусками нормально. Для этой схемы важнее:

- последний запуск завершился с кодом 0;
- timer активен;
- файл метрик обновляется;
- Prometheus успешно scrape'ит node_exporter.

## Почему textfile collector

node_exporter умеет читать `*.prom` из каталога, указанного через:

```bash
--collector.textfile.directory=/var/lib/node_exporter/textfile_collector
```

Поэтому custom collector не требует отдельного TCP listener. Он только генерирует локальный файл в формате Prometheus exposition.

Это удобно для коротких host-local checks, которые можно выполнить за доли секунды.

## systemd timer

Реальный timer:

```ini
[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
AccuracySec=5s
Unit=fm-1c-metrics.service
```

То есть collector запускается примерно раз в 30 секунд.

Проверка:

```bash
systemctl status fm-1c-metrics.timer --no-pager
systemctl list-timers fm-1c-metrics.timer --all
```

Timer здесь удобнее бесконечного shell-loop:

- каждый запуск имеет отдельный exit status;
- ошибки видны в journal;
- процесс не висит постоянно;
- collector и schedule можно проверять отдельно.

## fm-1c-metrics.service

Реальный unit:

```ini
[Unit]
Description=FM 1C metrics collector for node_exporter
After=srv1cv8-8.3.27.2325@default.service node_exporter.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/fm-1c-metrics.sh
User=root
Group=root

NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/var/lib/node_exporter/textfile_collector
```

Collector сейчас запускается от root, но запись ограничена каталогом textfile collector через `ProtectSystem=strict` и `ReadWritePaths`.

Самой модели мониторинга root не обязателен. В дальнейшем collector можно перевести на отдельную учётку, если `systemctl`, `pgrep`, `ss` и работа с output-файлом будут доступны без privilege escalation.

## Какие метрики собираются

Сейчас публикуются:

```text
fm_1c_info
fm_1c_service_up
fm_1c_ragent_processes
fm_1c_rmngr_processes
fm_1c_rphost_processes
fm_1c_ras_processes
fm_1c_listener_up
fm_1c_collector_timestamp_seconds
fm_1c_collector_success
```

### Версия платформы

```text
fm_1c_info{version="8.3.27.2325"} 1
```

Это полезно при параллельной эксплуатации нескольких версий 1С.

### Состояние systemd-сервиса

Collector проверяет конкретный production instance:

```text
srv1cv8-8.3.27.2325@default.service
```

и отдаёт:

```text
fm_1c_service_up 1
```

Так проверяется именно нужная версия 1С, а не просто наличие какого-то процесса `ragent`.

### Количество процессов

Через точные `pgrep -x` проверки собираются:

```text
ragent
rmngr
rphost
ras
```

Пример реального snapshot:

```text
fm_1c_ragent_processes 1
fm_1c_rmngr_processes 1
fm_1c_rphost_processes 2
fm_1c_ras_processes 0
```

Нулевое значение не всегда означает проблему. Например, `ras` нужен только если Remote Administration Server используется в конкретной схеме.

Alert должен учитывать реальную архитектуру, а не универсальное правило «все процессы всегда > 0».

## Проверка listener'ов

Через `ss` проверяются ожидаемые TCP-порты:

```text
fm_1c_listener_up{port="1540",component="ragent"} 1
fm_1c_listener_up{port="1541",component="rmngr"} 1
fm_1c_listener_up{port="1576",component="fts"} 1
```

Для текущего production именно эти listener'ы считаются ожидаемыми.

В документации 1С базовая схема серверного кластера включает:

```text
1540       server agent
1541       cluster manager
1560-1591  диапазон рабочих процессов
```

Поэтому `1576` — это environment-specific порт внутри диапазона рабочих процессов, а не обязательный порт для любой 1С.

При переносе схемы на другой сервер список портов нужно брать из фактической конфигурации 1С.

## Freshness collector'а

Collector публикует:

```text
fm_1c_collector_timestamp_seconds <unix-time>
```

Эта метрика критически важна.

Новый `fm_1c.prom` заменяет старый только после успешного завершения collector. Если следующий запуск упадёт, старый файл останется на месте. Поэтому:

```text
fm_1c_collector_success 1
```

может продолжать отображаться из прошлого успешного запуска.

Для обнаружения зависшего/сломавшегося collector лучше alert'ить по возрасту данных:

```promql
time() - fm_1c_collector_timestamp_seconds > 120
```

При интервале 30 секунд это даёт несколько пропущенных запусков до alarm. Порог следует подбирать под реальный sampling interval.

## Атомарное обновление `.prom`

Скрипт сначала пишет данные во временный файл:

```bash
TMP="${OUT}.tmp.$$"
```

проверяет содержимое, выставляет права и только потом делает:

```bash
mv -f "$TMP" "$OUT"
```

Это важная деталь.

node_exporter читает `*.prom`. Временный файл не имеет суффикса `.prom`, поэтому node_exporter не увидит наполовину записанный набор метрик.

Финальный `mv` атомарно заменяет старый файл новым.

## Проверка формата

В скрипте есть две защитные проверки.

Сначала все вычисленные значения проверяются как числовые:

```bash
[[ "$VALUE" =~ ^[0-9]+$ ]]
```

Затем `awk` отбрасывает строки без имени metric/value pair.

Это защищает от ошибки вида:

```text
fm_1c_ras_processes 0
0
```

Текущая проверка лёгкая и не является полным parser'ом Prometheus format.

Для ручной проверки после изменения collector можно дополнительно использовать:

```bash
cat /var/lib/node_exporter/textfile_collector/fm_1c.prom |
  promtool check metrics
```

## Права на output

Финальный файл получает:

```text
owner: node_exporter
mode: 0644
```

Каталог принадлежит `node_exporter`, а collector является единственным writer'ом `fm_1c.prom` в текущей схеме.

## node_exporter

Подтверждённый unit запускает:

```bash
/usr/local/bin/node_exporter \
  --web.listen-address=0.0.0.0:9100 \
  --collector.textfile.directory=/var/lib/node_exporter/textfile_collector
```

и использует systemd hardening:

```ini
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
CapabilityBoundingSet=
AmbientCapabilities=
```

Отдельно нужно учитывать, что node_exporter слушает `0.0.0.0:9100`.

Это не означает автоматически Internet exposure: доступ зависит от firewall и routing. Но TCP/9100 должен быть доступен только monitoring-сети/Prometheus.

Если архитектура позволяет, bind на конкретный management IP уже, чем `0.0.0.0`.

## Проверка всей цепочки

### 1. Запустить collector вручную

```bash
systemctl start fm-1c-metrics.service
systemctl status fm-1c-metrics.service --no-pager
```

Для `Type=oneshot` успешный запуск закончится `inactive (dead)` с exit code 0.

### 2. Проверить файл

```bash
cat /var/lib/node_exporter/textfile_collector/fm_1c.prom
```

И при наличии `promtool`:

```bash
cat /var/lib/node_exporter/textfile_collector/fm_1c.prom |
  promtool check metrics
```

### 3. Проверить node_exporter

```bash
curl -fsS http://127.0.0.1:9100/metrics |
  grep '^fm_1c_'
```

### 4. Проверить Prometheus

Полезные запросы:

```promql
fm_1c_service_up
```

и:

```promql
time() - fm_1c_collector_timestamp_seconds
```

Второе значение должно оставаться близким к интервалу запуска, а не постоянно расти.

## Alerts

### Основной сервис 1С недоступен

```promql
fm_1c_service_up == 0
```

### Collector перестал обновляться

```promql
time() - fm_1c_collector_timestamp_seconds > 120
```

### Нет обязательного ragent/rmngr

```promql
fm_1c_ragent_processes < 1
```

```promql
fm_1c_rmngr_processes < 1
```

### Нет обязательного listener

```promql
fm_1c_listener_up{port="1540"} == 0
```

```promql
fm_1c_listener_up{port="1541"} == 0
```

Не нужно делать alert вида `rphost != 2` только потому, что текущий snapshot показывает два процесса. Количество рабочих процессов зависит от конфигурации и нагрузки.

## Структура Grafana dashboard

Практичная схема:

```text
1С
  -> service state
  -> collector freshness
  -> ragent/rmngr/rphost
  -> expected listeners

Linux
  -> CPU
  -> RAM
  -> filesystem
  -> network

PostgreSQL / Postgres Pro
  -> connections
  -> long-running transactions
  -> locks/activity
  -> checkpoints
```

Так получается вертикальная диагностика от ОС через 1С до СУБД.

## Что этот collector не доказывает

Текущие метрики показывают локальное инфраструктурное состояние, но не доказывают, что:

```text
пользователь реально может открыть конкретную ИБ
бизнес-операция завершается успешно
web-публикация отвечает корректно
все сессии кластера в норме
response time приложения приемлем
```

Для этого нужны более высокоуровневые проверки: 1С administration interfaces, synthetic checks или application-specific telemetry.

Не стоит превращать простой textfile collector в универсальный monitoring API без реальной необходимости.

## Типовые отказовые сценарии

### Остановился timer

Старый `.prom` останется на диске, и Prometheus продолжит читать устаревшие значения.

Поэтому нужен freshness alert.

### Collector упал до `mv`

Старый файл останется целым. Это защищает от partial metrics, но снова требует контроля timestamp.

### Упал node_exporter

Исчезнут и host metrics, и `fm_1c_*`. Нужен обычный alert на Prometheus target availability независимо от custom rules.

### Обновили версию 1С

Скрипт сейчас жёстко фиксирует:

```text
VERSION=8.3.27.2325
UNIT=srv1cv8-8.3.27.2325@default.service
```

При upgrade платформы collector нужно обновить одновременно. Это полезное свойство: monitoring должен явно следовать за активной версией 1С, а не молча проверять старый unit.

## Backup и rollback

Перед изменением collector сохраняйте:

```text
/etc/systemd/system/fm-1c-metrics.service
/etc/systemd/system/fm-1c-metrics.timer
/usr/local/sbin/fm-1c-metrics.sh
node_exporter unit/drop-ins
Prometheus rules
Grafana dashboard/provisioning
```

Rollback: вернуть предыдущие файлы, выполнить `systemctl daemon-reload`, перезапустить timer при необходимости и убедиться, что timestamp `fm_1c.prom` снова обновляется.

Сам monitoring collector не требует менять конфигурацию 1С.

## Checklist

```text
[ ] monitoring привязан к активной версии 1С
[ ] fm-1c-metrics.timer active
[ ] последний oneshot завершился exit 0
[ ] fm_1c.prom обновляется в ожидаемом интервале
[ ] promtool check metrics проходит при наличии promtool
[ ] node_exporter отдаёт fm_1c_* metrics
[ ] Prometheus target = UP
[ ] freshness query ниже alert threshold
[ ] process/listener alerts соответствуют реальной конфигурации
[ ] TCP/9100 ограничен bind/firewall/routing policy
```

## Ссылки

- node_exporter textfile collector: <https://github.com/prometheus/node_exporter#textfile-collector>
- Prometheus exposition format: <https://prometheus.io/docs/instrumenting/exposition_formats/>
- `promtool check metrics`: <https://github.com/prometheus/prometheus/blob/main/docs/command-line/promtool.md>
- порты серверного кластера 1С: <https://kb.1ci.com/1C_Enterprise_Platform/FAQ/Administration/Server/Ports_setup_for_1C_Enterprise_server/>
- Prometheus: <https://prometheus.io/docs/>
- Grafana: <https://grafana.com/docs/grafana/latest/>
