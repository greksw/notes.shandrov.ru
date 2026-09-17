---
title: "Мониторинг Linux-хостов через node_exporter, Prometheus file_sd и alert rules"
description: "Production-подтверждённая схема мониторинга Linux через node_exporter 1.12.1, Prometheus file_sd, recording rules и многоуровневые алерты."
category: "Monitoring & Security"
tags: ["linux", "prometheus", "node-exporter", "file-sd", "alerting", "monitoring"]
published: 2026-09-16
updated: 2026-09-16
status: current
testedOn: ["AlmaLinux 9.8", "node_exporter 1.12.1", "Prometheus file_sd", "Prometheus recording and alerting rules"]
featured: true
lang: ru
translationKey: "monitoring/linux-node-exporter-prometheus-monitoring"
---

## Контекст

Мониторинг Linux имеет смысл рассматривать не как набор стандартных графиков, а как инфраструктурный контракт.

В текущей production-схеме есть четыре уровня:

```text
Linux-хосты
    |
    v
node_exporter
    |
    v
Prometheus file_sd inventory
    |
    v
recording rules
    |
    v
alert rules / dashboards
```

Мониторится смешанный Linux-парк: почтовые, monitoring, observability, security, 1C и telephony серверы. На части систем дополнительно используются application-specific textfile metrics, но Linux-слой остаётся отдельным от прикладных проверок.

## Подтверждённый production baseline

На репрезентативном production-хосте подтверждено:

```text
OS: AlmaLinux 9.8
node_exporter: 1.12.1
architecture: linux/amd64
service account: node_exporter
listener: внутренний management IP, TCP/9100
textfile collector: enabled
service state: enabled + active
```

На центральном Prometheus подтверждено:

```text
node scrape interval: 30s
node scrape timeout: 10s
target discovery: file_sd
file_sd refresh interval: 30s
promtool config validation: SUCCESS
rule files: 12
Linux rule file: fm-linux.yml
Linux rules: 22
```

Runtime target, использованный для проверки, имеет:

```text
job: node
health: up
scrape interval: 30s
scrape timeout: 10s
```

## systemd unit node_exporter

node_exporter работает от отдельного пользователя и слушает конкретный management IP:

```ini
[Service]
Type=simple
User=node_exporter
Group=node_exporter

ExecStart=/usr/local/bin/node_exporter \
  --web.listen-address=<node-management-ip>:9100 \
  --collector.textfile.directory=/var/lib/node_exporter/textfile_collector

Restart=on-failure
RestartSec=5s
```

Используется systemd hardening:

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
CapabilityBoundingSet=
AmbientCapabilities=
```

Привязка к внутреннему IP уменьшает поверхность доступа, но TCP/9100 всё равно должен быть ограничен firewall/routing только monitoring path.

## Проверка версии

Версию лучше проверять непосредственно у бинарника:

```bash
/usr/local/bin/node_exporter --version
```

На проверенном хосте:

```text
node_exporter 1.12.1
```

Та же версия видна в:

```text
node_exporter_build_info{version="1.12.1",...} 1
```

Это удобно для контроля разнобоя версий между серверами.

## Collectors

На production-хосте доступны стандартные Linux collectors, в том числе:

```text
cpu
filesystem
loadavg
meminfo
netclass
netdev
netstat
pressure
sockstat
stat
textfile
time
timex
uname
vmstat
xfs
```

и другие collectors, включённые node_exporter по умолчанию.

Нет необходимости отключать collector только потому, что на конкретном сервере отсутствует соответствующее оборудование. Единый стандартный набор уменьшает drift между хостами.

Проверка состояния collectors:

```promql
node_scrape_collector_success
```

## File-based service discovery

Linux targets не зашиты напрямую в основной `prometheus.yml`.

Job `node` использует:

```yaml
- job_name: node
  scrape_interval: 30s
  scrape_timeout: 10s

  file_sd_configs:
    - files:
        - /etc/prometheus/targets/node/*.yml
      refresh_interval: 30s
```

Target-файлы разделены по ролям и содержат унифицированные labels.

Обезличенный пример:

```yaml
- targets:
    - "<node-ip>:9100"
  labels:
    instance: "<node-name>"
    site: "fm"
    role: "mail"
    os: "linux"
```

Ключевые labels:

```text
instance
site
role
os
```

Recording/alert rules завязаны на них, поэтому просто добавить IP в target list недостаточно.

## Зачем здесь file_sd

Для небольшого или среднего статического парка `file_sd` даёт несколько преимуществ:

- inventory можно разделять по ролям;
- основной Prometheus config остаётся компактным;
- изменение targets не требует переписывать job;
- labels явно видны при review;
- inventory drift можно контролировать отдельно.

Текущий production-контракт ожидает ровно **9** Linux targets на площадке FM.

## Проверка runtime targets

Одного YAML недостаточно. Нужно проверять фактически загруженный target:

```bash
curl -fsS "http://<prometheus-ip>:9090/api/v1/targets?state=active" |
  jq '.data.activeTargets[] | select(.labels.job == "node")'
```

Для здорового target проверяются:

```text
job=node
health=up
lastError=""
scrapeInterval=30s
scrapeTimeout=10s
```

## Recording rules

`fm-linux.yml` сначала нормализует основные host metrics:

```text
fm:linux:up
fm:linux:cpu_usage_percent
fm:linux:memory_usage_percent
fm:linux:swap_usage_percent
fm:linux:filesystem_usage_percent
fm:linux:inode_usage_percent
fm:linux:uptime_seconds
fm:linux:load1_per_cpu
```

Это упрощает dashboard и alert expressions и делает поведение единообразным между хостами.

## Availability

Базовая доступность строится из:

```promql
up{job="node",site="fm",os="linux"}
```

и записывается как:

```text
fm:linux:up
```

Для большинства Linux-хостов node_exporter-down становится critical через 2 минуты.

Часть инфраструктурных серверов исключена из generic availability rule, потому что для них уже есть отдельные алерты в других rule-файлах. Это предотвращает дублирование уведомлений.

## Target-count contract

Текущее правило:

```promql
(
  count(up{job="node",site="fm",os="linux"})
  or vector(0)
) != 9
```

с `for: 2m`.

Это не capacity alert, а detector изменения monitoring inventory.

Плановое добавление или удаление Linux-сервера должно сопровождаться изменением expected count.

## CPU

CPU usage вычисляется через idle CPU time за 5 минут:

```promql
100 * (
  1 - avg without (cpu, mode) (
    rate(node_cpu_seconds_total{
      job="node",
      site="fm",
      os="linux",
      mode="idle"
    }[5m])
  )
)
```

Production thresholds:

```text
warning:  > 90% и < 97% в течение 15m
critical: >= 97% в течение 5m
```

Так кратковременные CPU spikes не превращаются в аварийные уведомления.

Для security-host используется отдельная политика CPU и он исключён из generic rule.

## Memory

Memory usage рассчитывается через `MemAvailable`, а не `MemFree`:

```promql
100 * (
  1 -
  node_memory_MemAvailable_bytes
  /
  node_memory_MemTotal_bytes
)
```

Production thresholds:

```text
warning:  > 85% и <= 92% в течение 15m
critical: > 92% в течение 5m
```

Для Linux это корректнее, поскольку page cache является reclaimable memory и сам по себе не означает memory pressure.

## Swap

Swap percentage записывается только если `SwapTotal > 0`.

Базовая формула:

```promql
100 * (1 - node_memory_SwapFree_bytes / node_memory_SwapTotal_bytes)
```

с guard condition:

```promql
node_memory_SwapTotal_bytes > 0
```

В текущем `fm-linux.yml` swap usage — recording metric, но generic fleet-wide swap alert отсутствует. Не стоит придумывать его в публичной статье как будто он уже используется.

## Filesystem space

Filesystem usage:

```promql
100 * (
  1 - node_filesystem_avail_bytes / node_filesystem_size_bytes
)
```

Из расчёта исключаются pseudo/transient filesystems:

```text
tmpfs
devtmpfs
overlay
squashfs
nsfs
tracefs
debugfs
securityfs
proc
sysfs
cgroup / cgroup2
```

Пороги:

```text
warning:  > 85% и < 93% в течение 15m
critical: >= 93% в течение 5m
```

Один observability datastore mount исключён из generic rule, потому что для него уже есть специализированный storage alert.

## Read-only filesystem

Отдельный critical rule проверяет:

```promql
node_filesystem_readonly == 1
```

для реальных filesystem types с `for: 1m`.

Это отдельный failure mode: файловая система может перейти в read-only из-за storage/filesystem ошибок задолго до заполнения.

## Inodes

Inode usage:

```promql
100 * (
  1 - node_filesystem_files_free / node_filesystem_files
)
```

с теми же pseudo-filesystem exclusions.

Пороги:

```text
warning:  > 90% и < 97% в течение 15m
critical: >= 97% в течение 5m
```

Особенно это важно для mail/logging workloads с большим количеством мелких файлов.

## OOM killer

Critical alert:

```promql
increase(
  node_vmstat_oom_kill{
    job="node",
    site="fm",
    os="linux"
  }[10m]
) > 0
```

Факт OOM kill — более сильный сигнал memory exhaustion, чем просто высокий процент занятой памяти.

## Time synchronization

Проверяется kernel synchronization status:

```promql
node_timex_sync_status == 0
```

в течение 5 минут.

Это важно для корреляции логов, TLS, authentication и incident timelines. При срабатывании уже отдельно диагностируется chrony/NTP.

## Textfile collector integrity

Некоторые application runbooks используют node_exporter textfile collector.

Linux-layer контролирует:

```promql
node_textfile_scrape_error > 0
```

в течение 5 минут.

Так malformed `.prom` file обнаруживается независимо от конкретной application metric.

Для отдельных observability/security hosts этот generic alert исключён, поскольку там уже есть специализированные проверки.

## Docker-hosts

Проверенный mail-host работает с приложениями в Docker, но node_exporter остаётся нормальным источником host metrics.

Он показывает host kernel, CPU, memory, filesystem и host-visible network interfaces.

На проверенном хосте в filesystem metrics были только:

```text
xfs
tmpfs
```

То есть Docker overlay не создавал значимого мусора в наблюдаемом `node_filesystem_*` наборе.

В network metrics присутствовали:

```text
основной NIC
docker0
application bridge
veth*
loopback
```

Для host-level dashboard можно фильтровать:

```promql
node_network_receive_bytes_total{
  device!~"lo|docker0|br-.*|veth.*"
}
```

и аналогично для transmit/errors/drops.

Удалять эти интерфейсы на exporter-level только ради более чистого dashboard не нужно: при incident analysis они могут быть полезны.

Текущий `fm-linux.yml` не содержит generic network saturation/error alerts, поэтому в статье они не выдаются за production-правила.

## Load per CPU

Записывается one-minute load, нормализованный на CPU count:

```promql
node_load1
/
count by (instance, site, role, os) (
  node_cpu_seconds_total{mode="idle"}
)
```

как:

```text
fm:linux:load1_per_cpu
```

Это позволяет сравнивать хосты разного размера.

Сейчас это recording metric, а не generic alert condition.

## Uptime

Uptime вычисляется как:

```promql
time() - node_boot_time_seconds
```

и используется как контекст на dashboard и после maintenance.

Сам по себе недавний reboot не трактуется как ошибка.

## Prometheus-side validation

Основной config проверяется:

```bash
/usr/local/bin/promtool check config /etc/prometheus/prometheus.yml
```

Проверенный запуск успешно провалидировал основной config и все 12 rule files, включая `fm-linux.yml` с 22 rules.

После изменений дополнительно проверяется runtime target state и recording rules.

Полезные запросы:

```promql
count(up{job="node",site="fm",os="linux"})
```

```promql
fm:linux:cpu_usage_percent
```

```promql
fm:linux:memory_usage_percent
```

```promql
fm:linux:filesystem_usage_percent
```

```promql
node_textfile_scrape_error{job="node",site="fm",os="linux"}
```

## Сводка alert policy

Production Linux layer сейчас контролирует:

```text
inventory count drift       critical after 2m
node_exporter unavailable   critical after 2m
CPU high                    warning after 15m
CPU critical                critical after 5m
memory high                 warning after 15m
memory critical             critical after 5m
filesystem high             warning after 15m
filesystem critical         critical after 5m
filesystem read-only        critical after 1m
inode high                  warning after 15m
inode critical              critical after 5m
textfile parse error        warning after 5m
OOM kill detected           critical
kernel time unsynchronized  warning after 5m
```

Эти thresholds — часть конкретной operational policy, а не универсальные defaults для всех Linux-парков.

## Исключение дублей

В текущей схеме некоторые specialized hosts исключены из generic rules, если более точный alert уже существует в другом rule-файле.

Например:

```text
security monitoring CPU/memory/filesystems
observability datastore capacity
selected exporter availability
selected textfile collector integrity
```

Получается понятная иерархия:

```text
generic Linux layer
        +
role-specific layer
        +
application-specific layer
```

Role-specific alert должен заменять дублирующий generic condition, а не создавать второе уведомление об одном событии.

## Что этот слой не проверяет

Нормальные host metrics не доказывают корректную работу приложения.

Linux-хост может выглядеть здоровым, пока:

```text
mail delivery не работает
Asterisk trunk недоступен
PostgreSQL transaction заблокирована
1C application service неисправен
Loki ingestion остановлен
```

Это относится к application-specific runbooks.

Linux layer — общий фундамент под ними.

## Процедура добавления Linux-хоста

1. Установить и проверить утверждённую версию node_exporter.
2. Привязать TCP/9100 к нужному management IP.
3. Применить hardened systemd unit.
4. Добавить `file_sd` target с `instance`, `site`, `role`, `os`.
5. Изменить target-count contract, если меняется inventory.
6. Выполнить `promtool check config`.
7. Reload Prometheus.
8. Убедиться, что runtime target имеет `UP`.
9. Проверить recording rules для нового instance.
10. Проверить отсутствие дублей с role-specific alerts.

## Rollback

Если изменение target ошибочно:

- восстановить предыдущий target file;
- вернуть предыдущий expected target count;
- проверить config через `promtool`;
- reload Prometheus;
- убедиться, что runtime targets и recording rules вернулись к предыдущему состоянию.

При обновлении node_exporter отдельно сохраняются предыдущий binary и systemd unit.

## Validation checklist

```text
[ ] известна версия node_exporter
[ ] node_exporter работает от отдельного service account
[ ] TCP/9100 привязан к нужному management IP
[ ] firewall/routing ограничивает scrape path
[ ] file_sd target содержит instance/site/role/os
[ ] runtime target = UP
[ ] scrape interval = 30s, timeout = 10s
[ ] expected Linux target count актуален
[ ] CPU/memory/filesystem/inode recording rules возвращают данные
[ ] node_textfile_scrape_error = 0 там, где используется textfile collector
[ ] OOM/time-sync metrics присутствуют на поддерживаемых хостах
[ ] Docker veth/bridge фильтруются на уровне query/dashboard при необходимости
[ ] generic alerts не дублируют role-specific alerts
[ ] promtool validation проходит до reload
```

## Ссылки

- node_exporter: <https://github.com/prometheus/node_exporter>
- node_exporter textfile collector: <https://github.com/prometheus/node_exporter#textfile-collector>
- Prometheus file-based service discovery: <https://prometheus.io/docs/prometheus/latest/configuration/configuration/#file_sd_config>
- Prometheus recording rules: <https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/>
- Prometheus alerting rules: <https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/>
- promtool: <https://prometheus.io/docs/prometheus/latest/command-line/promtool/>
