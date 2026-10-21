---
title: "Мониторинг RouterOS ↔ NetBox IPAM: systemd timer, Prometheus и Alertmanager"
description: "Как превратить read-only IPAM-аудит в промышленный контроль: атомарные .prom метрики, Node Exporter Textfile Collector, systemd hardening, PromQL и маршрутизация Alertmanager."
category: "Мониторинг и безопасность"
tags: ["netbox", "mikrotik", "routeros", "ipam", "prometheus", "node-exporter", "alertmanager", "systemd", "selinux", "observability"]
published: 2026-10-21
updated: 2026-10-21
status: current
testedOn: ["AlmaLinux 9", "Python 3.11", "Prometheus", "Node Exporter Textfile Collector", "Alertmanager 0.34", "systemd", "SELinux Enforcing"]
featured: false
lang: ru
translationKey: "monitoring/routeros-netbox-ipam-prometheus-alerting"
---

## От ручной сверки к эксплуатационному мониторингу

Собрать RouterOS и NetBox и один раз получить `CLEAN` — только половина задачи. IPAM может устареть завтра: изменится VLAN, статический IP окажется на другом интерфейсе или станет недоступен API. Надёжной схеме нужен ежедневный запуск и предупреждение о ситуациях, когда **сама проверка не смогла выполниться**.

В [предыдущей статье](/ru/notes/monitoring/routeros-netbox-ipam-drift-ssh-readonly/) описан read-only сбор VLAN/IPv4 из MikroTik RouterOS и NetBox. Здесь — вторая часть практической реализации: **Python-аудитор → атомарный `.prom` → Node Exporter → Prometheus → Alertmanager**.

Команды и имена в публикации обобщены. Реальные IP, домены, топология и пути к секретам конкретной сети не публикуются.

## 01 / Архитектура

```text
systemd timer
    |
    v
oneshot service
    |
    v
read-only Python audit (RouterOS SSH + NetBox HTTPS GET)
    |
    +--- CLEAN=0 | DRIFT=1 | ERROR=2
    |
    v
atomic textfile writer
    |
    v
/var/lib/node_exporter/textfile_collector/routeros-netbox-ipam.prom
    |
    v
node_exporter /metrics ---> Prometheus ---> alert rules ---> Alertmanager
```

На узле мониторинга уже использовался Node Exporter Textfile Collector для других инфраструктурных метрик. Поэтому не пришлось открывать новый TCP-порт, поднимать постоянно работающий Python HTTP-сервис или менять конфигурацию существующего экспортёра.

## 02 / Предварительная проверка Node Exporter

Убедимся, что textfile collector включён, а уже действующие метрики читаются без ошибок:

```bash
systemctl is-active node_exporter
PID=$(systemctl show node_exporter -p MainPID --value)
tr '\0' '\n' < "/proc/$PID/cmdline" | grep collector.textfile

curl -fsS http://127.0.0.1:9100/metrics | grep -E \
  '^(node_textfile_scrape_error|node_scrape_collector_success\{collector="textfile")'
```

Нормальное значение: `node_scrape_collector_success{collector="textfile"} 1` и `node_textfile_scrape_error 0`. Каталог textfile проверяется отдельно; его существующие файлы других сервисов не затрагиваются. При **SELinux Enforcing** важно сохранять правильный контекст `.prom` после записи.

## 03 / Контракт метрик: не маскировать ошибку под успешный аудит

Для простого контроля достаточно таких Gauge:

```prometheus
# TYPE netbox_routeros_ipam_audit_status gauge
netbox_routeros_ipam_audit_status 0
# TYPE netbox_routeros_ipam_audit_differences gauge
netbox_routeros_ipam_audit_differences 0
# TYPE netbox_routeros_ipam_audit_timestamp_seconds gauge
netbox_routeros_ipam_audit_timestamp_seconds 1790000000
# TYPE netbox_routeros_ipam_routeros_vlans gauge
netbox_routeros_ipam_routeros_vlans 8
# TYPE netbox_routeros_ipam_netbox_vlans gauge
netbox_routeros_ipam_netbox_vlans 8
```

Весь числовой набор здесь иллюстративный. Статус имеет строгую семантику:

| Значение | Состояние | Действие |
|---|---|---|
| `0` | CLEAN | Проверка состоялась, сравниваемые объекты совпали |
| `1` | DRIFT | Есть расхождения — предупредить администратора |
| `2` | ERROR | Результат сравнения недостоверен — критическая ошибка |

**Ключевой принцип:** если SSH, NetBox API или парсер не отработал, публикуется `status=2`, а значение `differences=0` **не публикуется** — нулевое число в такой ситуации нельзя считать измерением. `timestamp_seconds` обновляется на каждую попытку публикации, включая ERROR. Его отсутствие/устаревание обнаруживается отдельным алертом.

## 04 / Атомарная запись `.prom`

Node Exporter не должен считывать наполовину сформированный файл. Запись выполняется во временный файл **в том же каталоге**, затем происходит атомарная замена:

```python
import os
import tempfile
from pathlib import Path

metrics_dir = Path("/var/lib/node_exporter/textfile_collector")
target = metrics_dir / "routeros-netbox-ipam.prom"
content = "netbox_routeros_ipam_audit_status 0\n"  # пример

fd, tmp = tempfile.mkstemp(prefix=".ipam-", suffix=".tmp", dir=metrics_dir)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        stream.write(content)
        stream.flush()
        os.fsync(stream.fileno())
    os.chmod(tmp, 0o644)
    os.replace(tmp, target)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
```

Это фрагмент **механизма записи**, а не полноценный exporter: промышленная реализация перед этим выполняет аудит, валидирует коды выхода и формирует все метрики. При невозможности записать файл предыдущий результат может остаться на диске; поэтому **алерт устаревания обязателен**. Код не должен выводить токен, SSH-ключ, внутренние адреса или полные трассировки в журналы systemd.

## 05 / systemd oneshot + ежедневный таймер

В эксплуатационной реализации аудитор запускается `Type=oneshot` с ограничением времени и прав записи. Универсальный пример service:

```ini
# /etc/systemd/system/routeros-netbox-ipam.service
[Unit]
Description=Read-only RouterOS and NetBox IPAM audit
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=root
Group=root
WorkingDirectory=/opt/netbox-inventory-toolkit
ExecStart=/usr/bin/python3.11 /usr/local/libexec/netbox-inventory/ipam_metrics.py
TimeoutStartSec=180
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=/var/lib/node_exporter/textfile_collector
ProtectHome=read-only
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
LockPersonality=yes
RestrictSUIDSGID=yes
```

`ExecStart` — пример локальной обвязки, **не публичный готовый инсталлятор из PR**. В конкретном окружении она должна существовать и быть предварительно проверена. Запуск от `root` здесь обусловлен root-only SSH-ключом и токеном; каталог с Python-кодом и сами модули должны принадлежать root и **не быть доступны для изменения обычным пользователям**. Отдельный системный пользователь с минимальными правами — дальнейшее усиление безопасности.

```ini
# /etc/systemd/system/routeros-netbox-ipam.timer
[Unit]
Description=Daily IPAM drift audit

[Timer]
OnCalendar=*-*-* 06:45:00
RandomizedDelaySec=5min
AccuracySec=1min
Persistent=true
Unit=routeros-netbox-ipam.service

[Install]
WantedBy=timers.target
```

Время в примере интерпретируется по часовому поясу сервера. **Не добавляйте `Requires=routeros-netbox-ipam.service` в `[Unit]` таймера**: это может запустить service при активации таймера, помимо запланированного времени.

```bash
systemd-analyze verify /etc/systemd/system/routeros-netbox-ipam.service
systemd-analyze verify /etc/systemd/system/routeros-netbox-ipam.timer
systemctl daemon-reload
systemctl start routeros-netbox-ipam.service  # ручная проверка
systemctl show routeros-netbox-ipam.service -p Result -p ExecMainStatus
systemctl enable --now routeros-netbox-ipam.timer
systemctl list-timers --all routeros-netbox-ipam.timer
```

У завершившегося `oneshot` корректно увидеть `ActiveState=inactive`, `Result=success`, `ExecMainStatus=0`. При `DRIFT`/`ERROR` сервис может завершаться с ненулевым кодом; экспортёр при этом сначала должен записать соответствующую метрику.

## 06 / PromQL и четыре правила оповещения

Для ежедневного запуска настроены четыре независимые проверки. В примере используются тестовые метки `job=node`, `instance=monitor01`, `site=example`: реальные метки следует взять из `/api/v1/targets`.

```yaml
# Пример отдельной группы в каталоге rule_files
# Сам YAML помещается в существующий prometheus rules/*.yml.
groups:
  - name: example-routeros-netbox-ipam
    interval: 30s
    rules:
      - alert: RouterOSIPAMDrift
        expr: netbox_routeros_ipam_audit_status{job="node",instance="monitor01"} == 1
        for: 5m
        labels: {severity: warning, component: netbox-ipam, site: example}
        annotations:
          summary: "RouterOS and NetBox IPAM drift detected"
      - alert: RouterOSIPAMAuditError
        expr: netbox_routeros_ipam_audit_status{job="node",instance="monitor01"} == 2
        for: 5m
        labels: {severity: critical, component: netbox-ipam, site: example}
        annotations:
          summary: "IPAM audit failed"
      - alert: RouterOSIPAMAuditStale
        expr: time() - netbox_routeros_ipam_audit_timestamp_seconds{job="node",instance="monitor01"} > 93600
        for: 10m
        labels: {severity: warning, component: netbox-ipam, site: example}
        annotations:
          summary: "IPAM audit older than 26 hours"
      - alert: RouterOSIPAMAuditMissing
        expr: absent(netbox_routeros_ipam_audit_status{job="node",instance="monitor01"})
        for: 10m
        labels: {severity: critical, component: netbox-ipam, site: example}
        annotations:
          summary: "IPAM audit metric missing"
```

Порог `93600` секунд — 26 часов, с запасом относительно ежедневного запуска с небольшой случайной задержкой. `Missing` защищает от исчезновения метрики целиком, тогда как `Stale` обнаруживает старый файл. Оба правила нужны: отсутствие серии нельзя обнаружить сравнением её старого значения.

## 07 / Как проверяли без нарушения production

Сначала проверялись три режима **в изолированном временном каталоге**: `CLEAN=0`, `DRIFT=1`, `ERROR=2`. Мок-ответы Python `subprocess` позволили убедиться в форматировании `.prom`, не создавая реального инцидента на маршрутизаторе и не изменяя действующий набор метрик.

После ручного запуска systemd проверены `Result=success`, `ExecMainStatus=0`, публикация файла, `node_textfile_scrape_error 0` и появление серии `netbox_routeros_ipam_audit_status` в Prometheus. Отдельная особенность: Prometheus может слушать **только IP интерфейса**, а не `127.0.0.1:9090`; точный адрес смотрим через `ss -ltnp` или `--web.listen-address`.

```bash
/usr/local/bin/promtool check rules /etc/prometheus/rules/example-ipam.yml
systemctl reload prometheus

curl -fsSG 'http://prometheus.example.net:9090/api/v1/query' \
  --data-urlencode 'query=netbox_routeros_ipam_audit_status'
```

Сразу после reload API иногда показывает для новых правил `state=unknown`, `health=unknown`, пока не выполнена первая оценка. Через установленный интервал ожидаются `state=inactive`, `health=ok`, если отклонений нет. Перезапускать Prometheus из-за этого не нужно.

## 08 / Alertmanager: маршрут — ещё не факт доставки

Проверить маршрут с учётом реальных меток можно локально, **не создавая тестовый alert**:

```bash
amtool config routes test \
  --config.file=/etc/alertmanager/alertmanager.yml \
  alertname=RouterOSIPAMDrift \
  severity=warning component=netbox-ipam site=example \
  job=node instance=monitor01
```

Путь к файлу конфигурации здесь примерный: в работающей системе его надёжнее взять из `--config.file` процесса Alertmanager. Маршрутизация `warning` и `critical` в существующий receiver была подтверждена. Отдельно через Prometheus проверялась статистика `alertmanager_notifications_total` и `alertmanager_notifications_failed_total`: для email и webhook были ненулевые значения отправок без зарегистрированных ошибок на рассматриваемом отрезке.

**Однако `increase(...[24h])` даёт экстраполированное значение и не является точным целочисленным счётчиком писем; метрики других алертов не доказывают получение конкретного IPAM-уведомления.** Полный end-to-end тест доставки — отдельная операция, требующая согласования, поскольку она действительно отправляет сообщение.

## Результат и ограничения

В проверенной схеме ежедневный timer активен, IPAM-аудит возвращает `CLEAN`, Textfile Collector работает без ошибок, Prometheus получает метрики, все четыре правила находятся в состоянии `inactive/ok`, Alertmanager принимает выбранный маршрут. Существующие мониторинговые сервисы и правила других систем не были изменены.

Остались два направления развития: автоматическая верификация происхождения рассмотренных динамических IPsec-адресов и перенос локальной эксплуатационной обвязки в универсальный обезличенный комплект GitHub. Сам read-only аудитор и его ограничения описаны в [первой статье](/ru/notes/monitoring/routeros-netbox-ipam-drift-ssh-readonly/).