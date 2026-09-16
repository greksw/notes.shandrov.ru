---
title: "Мониторинг Asterisk 13 через node_exporter textfile collector, Prometheus и Grafana"
description: "Production-подход к мониторингу Asterisk 13 через systemd timer, custom CLI collector, node_exporter textfile metrics, Prometheus и Grafana."
category: "Мониторинг и безопасность"
tags: ["asterisk", "voip", "prometheus", "node-exporter", "grafana", "systemd", "chan-sip"]
published: 2026-09-16
updated: 2026-09-16
status: legacy
testedOn: ["AlmaLinux 8.10", "Asterisk 13.38.3", "chan_sip", "node_exporter textfile collector", "Prometheus", "Grafana"]
featured: true
lang: ru
translationKey: "monitoring/asterisk13-prometheus-textfile-monitoring"
---

## Контекст

Для PBX недостаточно обычного Linux-мониторинга.

CPU, память и disk metrics показывают состояние хоста, но не отвечают на прикладные вопросы:

```text
активен ли asterisk.service?
отвечает ли Asterisk CLI?
есть ли ожидаемый SIP listener?
сколько сейчас активных calls/channels?
сколько chan_sip peers online/offline?
доступны ли ожидаемые SIP trunks?
не перестал ли работать сам collector?
```

В production-схеме эти проверки выполняет короткоживущий collector, который раз в 30 секунд опрашивает локальный Asterisk CLI и публикует метрики через textfile collector `node_exporter`.

Цепочка выглядит так:

```text
Asterisk 13.38.3 / chan_sip
        |
        v
fm-asterisk-metrics.timer
        |
        v
fm-asterisk-metrics.service
        |
        v
/usr/local/sbin/fm-asterisk-metrics.sh
        |
        +--> fm_asterisk.prom
        +--> fm_asterisk_collector.prom
        |
        v
node_exporter textfile collector
        |
        v
Prometheus
        |
        v
Grafana / alerting
```

Статья помечена как **legacy**, потому что действующий сервер работает на Asterisk 13.38.3. Сам monitoring сейчас production и реально используется, но Asterisk 13 давно снят с upstream support.

Для будущего Asterisk 22 нужен отдельный PJSIP-aware monitoring, а не перенос текущего `chan_sip` parser без изменений.

## Подтверждённый production baseline

```text
OS: AlmaLinux 8.10
Asterisk: 13.38.3
SIP stack в collector: chan_sip
Asterisk service: asterisk.service
collector: /usr/local/sbin/fm-asterisk-metrics.sh
collector service: fm-asterisk-metrics.service
collector timer: fm-asterisk-metrics.timer
collection interval: 30 секунд
node_exporter listener: один внутренний management address, TCP/9100
textfile directory: /var/lib/node_exporter/textfile_collector
```

Текущие output files:

```text
fm_asterisk.prom
fm_asterisk_collector.prom
```

Разделение application data и collector state на два файла — важная часть схемы.

## Timer и oneshot service

Timer использует:

```ini
[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
AccuracySec=1s
Unit=fm-asterisk-metrics.service
```

Сам service — `Type=oneshot`:

```ini
[Service]
Type=oneshot
User=root
Group=root
ExecStart=/usr/local/sbin/fm-asterisk-metrics.sh
TimeoutStartSec=25s
Nice=10
```

Поэтому `inactive (dead)` между успешными запусками — нормальное состояние. Health определяется состоянием timer, последним exit status и свежестью метрик.

`TimeoutStartSec=25s` также не даёт зависшему collector пересекаться бесконечно со следующим 30-секундным запуском.

## systemd hardening

В production unit включены:

```ini
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
LockPersonality=true
RestrictSUIDSGID=true
RestrictRealtime=true
ReadWritePaths=/var/lib/node_exporter/textfile_collector
```

Collector сейчас работает от root, потому что ему нужны локальные process/socket checks и Asterisk CLI. При этом запись в filesystem ограничена каталогом textfile collector.

Перевод на отдельную service account возможен позже, но только после проверки доступа ко всем нужным локальным данным без расширения других прав.

## Host guard

В скрипте есть явная проверка hostname перед сбором метрик.

Логика выглядит так:

```bash
EXPECTED_HOST="pbx01"
HOST="$(hostname -s)"
[[ "$HOST" == "$EXPECTED_HOST" ]] || fail "wrong host"
```

Это защищает от ситуации, когда environment-specific collector случайно копируют на другой сервер и он начинает публиковать правдоподобные, но неверные metrics.

Реальный production hostname в публичной статье не публикуется.

Минус такого подхода очевиден: перенос collector на другой PBX требует осознанно изменить ожидаемый hostname.

## Ограниченные по времени Asterisk CLI calls

Application metrics собираются Asterisk CLI-командами, обёрнутыми в `/usr/bin/timeout`.

В текущей реализации используются эквиваленты:

```bash
timeout 10 asterisk -rx 'core show uptime'
timeout 10 asterisk -rx 'core show channels count'
timeout 10 asterisk -rx 'sip show peers'
```

Это важная failure boundary: зависший CLI не может навсегда заблокировать timer-driven collector.

Collector завершает run как failed, если ожидаемая CLI-команда не выполнилась или её output не удалось корректно распарсить.

## Service и process health

Collector публикует:

```text
fm_asterisk_service_up
fm_asterisk_processes
fm_asterisk_cli_up
```

Эти метрики покрывают разные классы отказов.

Например:

- systemd может считать service active, но CLI уже не отвечать;
- процесс может существовать, а service unit быть unhealthy;
- CLI health даёт более сильный сигнал, чем простая проверка PID.

Их лучше показывать отдельно, а не сворачивать в один synthetic status.

## Проверка SIP listener

Production collector проверяет ожидаемый UDP/5060 socket и дополнительно убеждается, что им владеет процесс Asterisk.

Публично это можно представить так:

```bash
ss -H -lunp |
  grep -F '<pbx-management-ip>:5060' |
  grep -F 'asterisk'
```

и metric:

```text
fm_asterisk_sip_listener_up{transport="udp",port="5060"} 1
```

Реальный внутренний IP в публичной статье не публикуется.

Это лучше, чем обычный `ss | grep 5060`, потому что проверяется и bind address, и owner process.

## Uptime и время с последнего reload

Collector парсит `core show uptime` и публикует:

```text
fm_asterisk_uptime_seconds
fm_asterisk_reload_age_seconds
```

Shell helper переводит текст с weeks/days/hours/minutes/seconds в целое число секунд.

`fm_asterisk_reload_age_seconds` особенно полезен при расследовании: можно быстро увидеть, начался ли инцидент после reload конфигурации.

Parser зависит от формата CLI output Asterisk 13. При обновлении платформы его нужно regression-test'ить, а не считать автоматически совместимым.

## Channels и calls

`core show channels count` преобразуется в:

```text
fm_asterisk_active_channels
fm_asterisk_active_calls
fm_asterisk_calls_processed_total
```

`fm_asterisk_calls_processed_total` объявлен как Prometheus counter, потому что это число обработанных calls с момента старта Asterisk.

Для rate используйте:

```promql
rate(fm_asterisk_calls_processed_total[5m])
```

или:

```promql
increase(fm_asterisk_calls_processed_total[1h])
```

Не стоит alert'ить по raw cumulative value. После restart Asterisk counter закономерно сбрасывается, а Prometheus counter functions умеют учитывать resets.

## Состояние chan_sip peers

Production collector выполняет:

```text
sip show peers
```

и парсит summary в:

```text
fm_asterisk_sip_peers_total
fm_asterisk_sip_monitored_online
fm_asterisk_sip_monitored_offline
fm_asterisk_sip_unmonitored_online
fm_asterisk_sip_unmonitored_offline
```

В реальном production snapshot есть десятки monitored peers и ненулевое количество offline peers.

Это важный момент: **offline peer count не должен автоматически считаться аварией**. Телефон может быть выключен, пользователь отсутствовать, remote endpoint может быть отключён намеренно.

Alert должен учитывать ожидаемую population endpoints или конкретные critical peers, а не правило `offline > 0` для всех случаев.

Parser завязан на `chan_sip` summary format и не подходит для будущего PJSIP-based Asterisk 22.

## Мониторинг SIP trunks

Текущий collector фильтрует provider SIP peers по определённому prefix из `sip show peers` и публикует aggregate и per-trunk metrics.

Сейчас используются:

```text
fm_asterisk_multifon_peers
fm_asterisk_multifon_ok
fm_asterisk_multifon_problem
fm_asterisk_trunk_up{trunk="<sanitized-trunk-name>"}
```

Реальные имена production trunks в публичную статью лучше не выносить.

Collector считает peer healthy, если строка `sip show peers` содержит status `OK (...)`.

Это нужно трактовать правильно: это **reachability/qualify-style signal**, а не доказательство полноценной телефонии.

Trunk может отвечать на SIP OPTIONS, но реальный call path всё равно может не работать из-за authentication, routing, dialplan, provider или RTP.

Synthetic calls — отдельный monitoring layer.

## Разделение collector state и application data

Сильная сторона текущей реализации — разделение:

```text
fm_asterisk.prom
fm_asterisk_collector.prom
```

Основной data file содержит последнюю валидную application snapshot.

State file содержит:

```text
fm_asterisk_collector_success
fm_asterisk_collector_timestamp_seconds
```

При любой ошибке fail-handler записывает:

```text
fm_asterisk_collector_success 0
```

с новым collector timestamp.

Старый application data file при этом остаётся нетронутым.

Так различаются три состояния:

```text
collector вообще перестал запускаться
collector запускается, но падает
collector здоров и application data свежие
```

## Freshness данных

В успешный application snapshot также пишется:

```text
fm_asterisk_data_timestamp_seconds
```

Получается два независимых timestamp:

- `collector_timestamp` — последний run скрипта, включая failed run;
- `data_timestamp` — время последней успешной публикации данных Asterisk.

Полезные проверки:

```promql
time() - fm_asterisk_collector_timestamp_seconds > 120
```

означает, что collector/timer устарел.

```promql
fm_asterisk_collector_success == 0
```

означает, что последний run collector завершился ошибкой.

```promql
time() - fm_asterisk_data_timestamp_seconds > 120
```

означает, что валидные application metrics перестали обновляться.

Это устойчивее, чем один `success` gauge.

## Atomic publication

Оба output file создаются через `mktemp` в target directory и публикуются через `mv -f`.

Принцип:

```bash
TMP="$(mktemp /var/lib/node_exporter/textfile_collector/.fm_asterisk.XXXXXX)"
# complete write
mv -f "$TMP" /var/lib/node_exporter/textfile_collector/fm_asterisk.prom
```

Temporary names не заканчиваются на `.prom`, поэтому node_exporter не пытается читать частично записанный файл.

Это соответствует рекомендованному atomic-write pattern для textfile collector.

## Интеграция с node_exporter

Production node_exporter работает под отдельной account и явно использует textfile directory:

```bash
/usr/local/bin/node_exporter \
  --web.listen-address=<pbx-management-ip>:9100 \
  --collector.textfile.directory=/var/lib/node_exporter/textfile_collector
```

В отличие от ранее разобранного 1С-host, здесь node_exporter уже bind'ится на один внутренний management address, а не на `0.0.0.0`.

Firewall/routing всё равно должен разрешать TCP/9100 только monitoring path.

## Проверка полной цепочки

Проверяем timer:

```bash
systemctl status fm-asterisk-metrics.timer --no-pager
systemctl list-timers fm-asterisk-metrics.timer --all
```

Делаем один ручной run:

```bash
systemctl start fm-asterisk-metrics.service
systemctl status fm-asterisk-metrics.service --no-pager
```

Для успешного oneshot ожидается exit status 0, после чего unit вернётся в `inactive (dead)`.

Проверяем files:

```bash
cat /var/lib/node_exporter/textfile_collector/fm_asterisk_collector.prom
cat /var/lib/node_exporter/textfile_collector/fm_asterisk.prom
```

При наличии `promtool` проверяем exposition syntax:

```bash
cat /var/lib/node_exporter/textfile_collector/fm_asterisk.prom |
  promtool check metrics
```

И затем node_exporter:

```bash
curl -fsS http://<pbx-management-ip>:9100/metrics |
  grep '^fm_asterisk_'
```

## Полезные alert rules

Точные durations и ожидания зависят от роли PBX, но структура может быть такой.

### Collector перестал запускаться

```promql
time() - fm_asterisk_collector_timestamp_seconds > 120
```

### Последний run failed

```promql
fm_asterisk_collector_success == 0
```

### Application data устарели

```promql
time() - fm_asterisk_data_timestamp_seconds > 120
```

### Asterisk service или CLI недоступен

```promql
fm_asterisk_service_up == 0
```

```promql
fm_asterisk_cli_up == 0
```

### SIP listener отсутствует

```promql
fm_asterisk_sip_listener_up{transport="udp",port="5060"} == 0
```

### Критичный provider trunk недоступен

```promql
fm_asterisk_trunk_up{trunk="<critical-trunk>"} == 0
```

Не стоит использовать универсальное правило:

```promql
fm_asterisk_sip_monitored_offline > 0
```

если не гарантировано, что каждый monitored endpoint обязан быть online постоянно.

## Структура Grafana dashboard

Практичный dashboard можно построить так:

```text
PBX overview
  -> service / process / CLI state
  -> collector state и freshness
  -> uptime / reload age
  -> active calls / channels
  -> call processing rate

SIP
  -> listener state
  -> peer totals и online/offline split
  -> provider trunk aggregate state
  -> critical per-trunk state

Host
  -> CPU / RAM / filesystem / network
  -> node_exporter availability
```

Так application signals остаются рядом с host metrics, но не смешиваются в одну модель.

## Что этот monitoring не доказывает

Collector даёт полезное состояние PBX, но не подтверждает end-to-end telephony service.

Он не доказывает, что:

```text
входящий DID доходит до нужного extension
исходящий call реально проходит через provider
RTP audio работает в обе стороны
dialplan корректно маршрутизирует каждый call
DTMF работает
IVR/application flow проходит полностью
```

Для этого нужны synthetic calls, provider-side monitoring, RTP/media checks или application-specific tests.

## Граница миграции Asterisk 13 -> Asterisk 22

Этот collector нельзя просто перенести на Asterisk 22 без изменений.

Текущая реализация зависит от:

```text
chan_sip
sip show peers
формата CLI output Asterisk 13
provider rows со status OK (...)
```

Asterisk 22 — LTS release, а Asterisk 13 уже upstream EOL. Поэтому для Asterisk 22 monitoring нужно проектировать вокруг реальных PJSIP objects после миграции.

При переносе надо сохранить monitoring intent, а не exact command syntax:

```text
service health
CLI health
SIP/PJSIP transport state
endpoint/AOR/contact state
trunk state
active channels/calls
call throughput
collector freshness
```

Новый collector должен быть проверен на реальном Asterisk 22 CLI output до замены legacy source.

## Rollback и обслуживание

Перед изменением collector сохраняйте:

```text
/etc/systemd/system/fm-asterisk-metrics.service
/etc/systemd/system/fm-asterisk-metrics.timer
/usr/local/sbin/fm-asterisk-metrics.sh
node_exporter unit / drop-ins
Prometheus rules
Grafana dashboards/provisioning
```

Изменение monitoring collector не должно требовать изменения самой Asterisk configuration.

После Asterisk update или изменения CLI behavior перепроверьте:

```text
core show uptime parser
core show channels count parser
sip show peers summary parser
provider-trunk row parser
metric exposition syntax
collector/data timestamps
```

## Проверочный список

```text
[ ] fm-asterisk-metrics.timer active
[ ] latest oneshot run exited 0
[ ] collector success = 1
[ ] collector timestamp свежий
[ ] data timestamp свежий
[ ] Asterisk service/process/CLI metrics совпадают с реальностью
[ ] SIP listener соответствует реальному socket
[ ] channel/call counters меняются во время реальных calls
[ ] peer summary совпадает с Asterisk CLI
[ ] critical trunk states совпадают с ожидаемыми peers
[ ] node_exporter публикует fm_asterisk_* только по monitoring path
[ ] alerts различают failure collector и failure PBX
```

## Ссылки

- Asterisk release lifecycle: <https://docs.asterisk.org/About-the-Project/Asterisk-Versions/>
- Asterisk CLI syntax: <https://docs.asterisk.org/Operation/Asterisk-Command-Line-Interface/CLI-Syntax-and-Help-Commands/>
- node_exporter textfile collector: <https://github.com/prometheus/node_exporter#textfile-collector>
- Prometheus text exposition format: <https://prometheus.io/docs/instrumenting/exposition_formats/>
- Prometheus documentation: <https://prometheus.io/docs/>
- Grafana documentation: <https://grafana.com/docs/grafana/latest/>
