---
title: "Мониторинг PostgreSQL / Postgres Pro через Prometheus и postgres_exporter"
description: "Production-подход к мониторингу PostgreSQL и Postgres Pro через postgres_exporter, Prometheus и Grafana с отделением метрик БД от обычного Linux-мониторинга."
category: "Мониторинг и безопасность"
tags: ["postgresql", "postgres-pro", "prometheus", "postgres-exporter", "grafana", "monitoring"]
published: 2026-09-16
updated: 2026-09-16
status: current
testedOn: ["AlmaLinux 9.8", "Postgres Pro 1C 17.10", "postgres_exporter systemd deployment", "Prometheus", "Grafana"]
featured: true
lang: ru
translationKey: "monitoring/postgresql-postgrespro-prometheus-monitoring"
---

## Контекст

Обычный мониторинг Linux показывает CPU, память, файловые системы и сеть, но этого недостаточно для диагностики большинства проблем на уровне СУБД.

В production-стеке 1С сервер БД работает на AlmaLinux 9.8 с Postgres Pro 1C 17.10 и отдаёт метрики через отдельный `postgres_exporter.service` в Prometheus и Grafana.

Поэтому мониторинг разделён на два уровня:

```text
метрики Linux -> CPU / RAM / filesystem / network
метрики PostgreSQL -> sessions / transactions / locks / checkpoints / DB state
```

Рабочий Linux-хост ещё не означает здоровую БД.

## Подтверждённый production baseline

```text
OS: AlmaLinux 9.8
Database: Postgres Pro 1C 17.10
Database listener for exporter: loopback
Exporter service: postgres_exporter.service
Exporter port: 9187
Metrics backend: Prometheus
Visualization: Grafana
```

Точную версию бинарника `postgres_exporter` не утверждаю: на работающем сервере вызов `postgres_exporter --version` не вернул строку версии.

## Реальная схема systemd

Exporter работает от отдельной непривилегированной учётной записи:

```ini
[Service]
Type=simple
User=postgres_exporter
Group=postgres_exporter
```

Подключение к БД локальное:

```ini
Environment="DATA_SOURCE_URI=127.0.0.1:5432/postgres?sslmode=disable"
Environment="DATA_SOURCE_USER=postgres_exporter"
Environment="DATA_SOURCE_PASS_FILE=/etc/postgres_exporter/password"
```

Это даёт несколько полезных свойств:

- пароль не передаётся в `ExecStart`;
- secret хранится в отдельном файле;
- exporter подключается к PostgreSQL по loopback;
- доступ к PostgreSQL и к exporter можно ограничивать независимо.

Содержимое `/etc/postgres_exporter/password` в Git и документацию не публикуется. Права на файл должны оставаться минимально необходимыми.

## Фактический запуск exporter

Production unit запускает:

```bash
/usr/local/bin/postgres_exporter \
  --config.file= \
  --web.listen-address=<db-host-ip>:9187 \
  --collector.database_wraparound \
  --collector.long_running_transactions \
  --collector.postmaster \
  --collector.stat_checkpointer \
  --no-collector.stat_replication
```

Внутренний IP в публичной статье намеренно заменён placeholder'ом.

Unit явно задаёт пустой `--config.file=` и использует environment variables для параметров подключения к БД.

Включены collectors:

```text
database_wraparound
long_running_transactions
postmaster
stat_checkpointer
```

Сбор replication metrics отключён:

```text
--no-collector.stat_replication
```

Collector имеет смысл включать тогда, когда за ним стоит конкретный эксплуатационный вопрос или alert, а не просто потому, что он существует.

## Сетевой listener

Exporter не слушает `0.0.0.0`.

Он привязан к одному внутреннему адресу:

```text
<db-host-ip>:9187
```

Проверка:

```bash
ss -lntp | grep -E ':9187\b|postgres_exporter'
```

Это лучше, чем публикация endpoint на всех интерфейсах. При этом firewall всё равно должен разрешать TCP/9187 только со стороны Prometheus.

## Порядок запуска сервисов

Unit содержит:

```ini
After=network-online.target postgrespro-1c-17.service
Wants=network-online.target
```

То есть exporter запускается после поднятия сети и сервиса Postgres Pro 1C 17.

Это правильный порядок, но он не заменяет runtime-проверку: после рестарта БД нужно убедиться, что exporter снова успешно собирает metrics.

## Hardening systemd

Production unit уже достаточно жёстко ограничен:

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

Для exporter это подходящая модель: ему не нужны elevated capabilities, доступ к kernel modules или возможность писать по всей файловой системе.

Если будущий collector потребует дополнительных прав, их лучше добавлять точечно, а не ослаблять unit заранее.

## Проверка работающего exporter

Состояние сервиса:

```bash
systemctl status postgres_exporter --no-pager
systemctl is-enabled postgres_exporter
```

Эффективный unit:

```bash
systemctl cat postgres_exporter
```

Listener:

```bash
ss -lntp | grep -E ':9187\b|postgres_exporter'
```

Так как exporter привязан к внутреннему адресу, а не к loopback, endpoint нужно проверять по этому адресу из разрешённого monitoring path:

```bash
curl -fsS http://<db-host-ip>:9187/metrics | head
```

После этого смотрим журнал:

```bash
journalctl -u postgres_exporter -n 100 --no-pager
```

Доступный `/metrics` подтверждает только работу HTTP endpoint. Повторяющиеся ошибки database collection всё равно означают неисправный monitoring path.

## Учётная запись БД

Exporter использует отдельную DB account:

```text
postgres_exporter
```

Ей нужны только права, необходимые включённым collectors.

Не нужно переиспользовать:

```text
учётку приложения
postgres superuser
учётку сервиса 1С
```

По возможности используйте штатные monitoring roles PostgreSQL/Postgres Pro и добавляйте только те grants, которые реально нужны custom queries.

## Prometheus scrape model

Обезличенный пример:

```yaml
scrape_configs:
  - job_name: postgresql
    static_configs:
      - targets:
          - db01.example.net:9187
        labels:
          service: postgresql
          role: database
```

Перед применением изменений:

```bash
promtool check config /etc/prometheus/prometheus.yml
```

После reload/restart проверьте `UP` target и то, что DB metrics действительно меняются во времени.

## Что мониторить

### Connections и long-running transactions

Следите за числом сессий относительно реального `max_connections` и за аномальным ростом.

Collector `long_running_transactions` важен, потому что долгие транзакции могут удерживать locks, мешать cleanup и увеличивать bloat.

### Transaction activity и locks

Сопоставляйте transaction rate и contention с CPU/I/O сервера и ошибками приложения.

Медленная 1С может упираться в БД, но также в storage, сеть или application tier.

### Checkpoints

Collector `stat_checkpointer` даёт видимость checkpoint activity.

Эти метрики полезно коррелировать со storage latency и write pressure, а не оценивать отдельно.

### Postmaster state

Collector `postmaster` позволяет контролировать состояние основного процесса PostgreSQL на уровне БД, а не только факт открытого TCP-порта.

### Transaction ID wraparound

`database_wraparound` нужен для контроля риска exhaustion/wraparound transaction IDs — это типичный пример состояния, которое невозможно качественно увидеть через обычный Linux monitoring.

### Replication

В текущем unit replication collector отключён.

Если позже появится репликация, сначала нужно определить нормальные значения lag/slot/replay state, а затем включать соответствующий collector и alerts.

## Структура Grafana dashboard

Полезная структура:

```text
Overview
  -> exporter / DB availability
  -> connections
  -> long-running transactions
  -> transaction activity
  -> locks / contention
  -> checkpoint activity
  -> wraparound risk
  -> host CPU / RAM / storage
```

Host panels лучше держать рядом с DB panels, чтобы сразу было видно, проблема находится в PostgreSQL или ниже, на уровне ресурсов сервера.

## Alerting

Полезнее alert'ить на actionable conditions:

```text
exporter недоступен
PostgreSQL недоступен
connections приближаются к лимиту
long-running transactions превышают допустимое время
длительное lock/contention состояние
checkpoint/write pressure выходит за baseline
растёт риск transaction ID wraparound
filesystem/storage приближается к заполнению
```

Пороги должны основываться на реальной нагрузке 1С и maintenance model.

## Граница с мониторингом 1С

PostgreSQL monitoring не доказывает здоровье application tier 1С.

Он не отвечает напрямую на вопросы:

```text
запущен ли нужный instance 1С
доступна ли информационная база пользователям
выполняются ли операции приложения
здоров ли кластер 1С
```

На production-хосте уже есть отдельный сервис/таймер метрик 1С, поэтому application-level monitoring нужно описывать отдельно.

## Безопасность

Текущая модель уже правильно разделяет доступ:

- отдельный OS user `postgres_exporter`;
- отдельная PostgreSQL monitoring account;
- пароль в `/etc/postgres_exporter/password`, а не в `ExecStart`;
- подключение exporter -> PostgreSQL по loopback;
- exporter слушает только один внутренний IP;
- TCP/9187 разрешается только monitoring path;
- TCP/5432 ограничивается отдельно;
- systemd hardening сохраняется, пока нет обоснованной причины его ослабить.

Monitoring не должен становиться вторым административным каналом в БД.

## Backup и rollback

Перед изменением exporter сохраняйте:

```text
/etc/systemd/system/postgres_exporter.service
metadata/permissions /etc/postgres_exporter/password
Prometheus scrape config
Grafana dashboards/provisioning
alert rules
```

Сам пароль копировать в Git или документацию не нужно.

Rollback должен возвращать предыдущую monitoring configuration и не затрагивать application database.

## Проверка после изменений

```text
[ ] postgres_exporter.service active
[ ] exporter работает от postgres_exporter user/group
[ ] подключение к PostgreSQL остаётся на loopback
[ ] password file-backed и не находится в ExecStart
[ ] exporter слушает только нужный внутренний адрес:9187
[ ] firewall ограничивает 9187 monitoring path
[ ] в journal нет повторяющихся collection errors
[ ] Prometheus target = UP
[ ] DB metrics меняются
[ ] Grafana показывает свежие данные
```

## Ссылки

- postgres_exporter: <https://github.com/prometheus-community/postgres_exporter>
- Prometheus configuration: <https://prometheus.io/docs/prometheus/latest/configuration/configuration/>
- PostgreSQL monitoring statistics: <https://www.postgresql.org/docs/current/monitoring-stats.html>
- PostgreSQL predefined roles: <https://www.postgresql.org/docs/current/predefined-roles.html>
- Grafana documentation: <https://grafana.com/docs/grafana/latest/>
