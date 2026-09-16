---
title: "Мониторинг PostgreSQL / Postgres Pro через Prometheus и postgres_exporter"
description: "Production-подход к мониторингу PostgreSQL и Postgres Pro через postgres_exporter, Prometheus и Grafana с отделением метрик БД от обычного Linux-мониторинга."
category: "Мониторинг и безопасность"
tags: ["postgresql", "postgres-pro", "prometheus", "postgres-exporter", "grafana", "monitoring"]
published: 2026-09-16
updated: 2026-09-16
status: current
testedOn: ["AlmaLinux 9.8", "Postgres Pro 1C 17.10", "postgres_exporter", "Prometheus", "Grafana"]
featured: true
lang: ru
translationKey: "monitoring/postgresql-postgrespro-prometheus-monitoring"
---

## Контекст

Обычный мониторинг Linux показывает CPU, память, файловые системы и сеть, но этого недостаточно для диагностики большинства проблем на уровне СУБД.

Для PostgreSQL/Postgres Pro нужны собственные метрики БД:

```text
соединения
транзакционная активность
блокировки
статистика активности и кеша
размер баз
checkpoint/background writer
репликация, если используется
```

В production-стеке 1С сервер БД работает на AlmaLinux 9.8 с Postgres Pro 1C 17.10, а метрики PostgreSQL уже собираются отдельным сервисом `postgres_exporter`.

Поэтому exporter рассматривается как самостоятельный источник сигналов, а не как дополнение к проверке наличия процесса `postgres`.

## Production baseline

Подтверждённый стек:

```text
OS: AlmaLinux 9.8
Database: Postgres Pro 1C 17.10
Exporter service: postgres_exporter.service
Metrics backend: Prometheus
Visualization: Grafana
```

Точную версию самого exporter и текущий datasource/config я здесь намеренно не утверждаю, пока они не сняты с работающего сервера.

## Слои мониторинга

Полезная схема выглядит так:

```text
Linux host metrics
       |
       +--> CPU / RAM / filesystem / network
       |
       v
PostgreSQL exporter
       |
       +--> database/session/activity metrics
       |
       v
Prometheus
       |
       v
Grafana
```

Эти два источника отвечают на разные вопросы.

Host monitoring покажет, что сервер упёрся в CPU. PostgreSQL metrics помогут понять, связано ли это с ростом соединений, транзакционной активностью, блокировками или другой нагрузкой БД.

## Сначала проверяем существующий production service

Перед изменением конфигурации:

```bash
systemctl status postgres_exporter --no-pager
systemctl is-enabled postgres_exporter
```

Далее смотрим реальный unit:

```bash
systemctl cat postgres_exporter
```

Это важно, потому что exporter может получать настройки через:

```text
EnvironmentFile
systemd drop-in
wrapper script
command-line flags
```

Не публикуйте credentials из unit или environment-файлов.

## Проверяем listener exporter

Находим реальный socket:

```bash
ss -lntp | grep -i postgres_exporter
```

Если имени процесса не видно:

```bash
ps -ef | grep '[p]ostgres_exporter'
```

Часто используется порт `9187`, но в эксплуатационной документации лучше фиксировать фактическую конфигурацию, а не предполагать default.

## Проверяем endpoint локально

После того как адрес/порт известны:

```bash
curl -fsS http://127.0.0.1:9187/metrics | head
```

Если в production используется другой порт, подставьте его.

Успешный ответ означает только доступность exporter endpoint. Это ещё не доказывает, что запросы к БД выполняются без ошибок.

Смотрим журнал:

```bash
journalctl -u postgres_exporter -n 100 --no-pager
```

## Учётная запись БД для мониторинга

Для exporter нужна отдельная БД-учётка с минимально необходимыми правами.

Не используйте повторно:

```text
учётку приложения
postgres superuser
учётку сервиса 1С
```

Пароль не должен попадать в Git, документацию и открытые shell scripts.

В зависимости от версии PostgreSQL/Postgres Pro и включённых collectors можно использовать штатные monitoring roles и точечные дополнительные grants для custom queries.

Конкретные права нужно проверять по реально установленной версии exporter и набору запросов.

## Не публикуем exporter наружу

Нормальная схема:

```text
Prometheus -> postgres_exporter
users      -X-> postgres_exporter
Internet   -X-> postgres_exporter
```

Ограничьте listen address и/или firewall так, чтобы endpoint был доступен только со стороны Prometheus.

Если Prometheus расположен на том же сервере — достаточно loopback.

Если удалённо — разрешайте только monitoring host/network.

## Scrape job Prometheus

Минимальный пример:

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

В публичной статье используйте обезличенные DNS names.

Для multi-site инфраструктуры полезны стабильные labels:

```text
site
role
service
environment
```

Не помещайте в labels имена БД, SQL-текст, usernames и другие значения с высокой кардинальностью.

## Проверка Prometheus

Перед reload/restart:

```bash
promtool check config /etc/prometheus/prometheus.yml
```

После применения конфигурации проверьте, что target в Prometheus имеет состояние `UP`.

На уровне запросов убедитесь, что приходят реальные PostgreSQL metrics, а exporter не сообщает постоянные ошибки collection.

Не копируйте dashboard queries вслепую из другого exporter release: названия metrics и collectors могут отличаться.

## Что мониторить

### Соединения

Главные вопросы:

```text
сколько сессий открыто?
насколько близко значение к max_connections?
есть ли аномальный рост соединений?
```

График connections имеет смысл только вместе с реальным `max_connections` и пониманием поведения приложения.

### Транзакционная активность

Следите за transaction/activity rate и формируйте baseline обычной нагрузки.

Аномально низкая активность тоже может быть проблемой, если в это время приложение обычно активно.

### Блокировки

Locks помогают отличить общее замедление приложения от contention внутри БД.

Во время инцидента полезно сопоставлять их с:

```text
application errors
query latency, если собирается
CPU / I/O pressure
ростом соединений
```

### Размер БД

Рост базы важен для capacity planning, но не заменяет контроль свободного места на файловой системе.

Нужно видеть оба показателя:

```text
logical DB growth
filesystem/storage capacity
```

### Cache/activity statistics

PostgreSQL предоставляет статистику, полезную для анализа изменений workload.

Лучше смотреть её как тренд. Один коэффициент без контекста редко даёт полноценный диагноз производительности.

### Checkpoints и write activity

Метрики checkpoint/background writer помогают сопоставлять write pressure со storage latency и замедлениями приложения.

Особенно полезно смотреть их на том же временном диапазоне, что CPU, disk и storage metrics.

### Репликация

Если replication используется, мониторьте отдельно:

```text
доступность replica
lag
WAL/replay progress
replication slots, если используются
```

Не создавайте alerts по replication там, где её нет.

## Структура Grafana dashboard

Database dashboard должен отвечать на эксплуатационные вопросы, а не показывать все metrics подряд.

Полезная структура:

```text
Overview
  -> exporter/DB availability
  -> connections
  -> transaction/activity rate
  -> locks
  -> database size
  -> checkpoints/write activity
  -> host CPU/RAM/storage
  -> replication, если используется
```

Host panels лучше держать рядом с PostgreSQL panels — так проще увидеть, проблема находится в СУБД или ниже, на уровне ресурсов сервера/storage.

## Alerting

Не нужно alert'ить на факт любого изменения metric.

Полезнее actionable conditions:

```text
exporter недоступен
PostgreSQL недоступен
connections приближаются к лимиту
длительное состояние блокировок/contention
рост БД или filesystem к критической ёмкости
replication lag выше допустимого окна
```

Пороги должны исходить из реальной нагрузки и maintenance model, а не из случайного импортированного dashboard.

## Граница с мониторингом 1С

Эта БД обслуживает 1С, но мониторинг PostgreSQL и мониторинг 1С — разные уровни.

PostgreSQL metrics не доказывают, что:

```text
процессы сервера 1С работают корректно
запущен нужный instance платформы
информационная база доступна пользователю
операции на уровне приложения выполняются успешно
```

В production уже используется отдельный сервис/таймер метрик 1С. Эти сигналы нужно описывать в отдельной статье по мониторингу 1С.

## Безопасность

Для exporter:

- отдельная monitoring DB account;
- никаких паролей в Git;
- ограниченный listener;
- по возможности не передавать secrets через process arguments;
- environment/config files с ограниченными правами;
- endpoint exporter не должен быть доступен из Internet;
- TCP/5432 ограничивается независимо от exporter.

Monitoring не должен превращаться в альтернативный административный доступ к СУБД.

## Backup и rollback

Изменения monitoring не должны затрагивать production schema БД без отдельной необходимости конкретного collector.

Перед изменением существующего exporter сохраняйте:

```text
systemd unit / drop-ins
exporter environment/config
Prometheus scrape config
custom query files, если есть
Grafana dashboard JSON/provisioning
alert rules
```

Rollback должен означать возврат предыдущей конфигурации monitoring, а не изменения в application database.

## Проверка после изменений

```text
[ ] postgres_exporter active
[ ] endpoint доступен только по разрешённому monitoring path
[ ] в journal нет постоянных ошибок collection
[ ] Prometheus target = UP
[ ] PostgreSQL metrics присутствуют
[ ] labels корректно идентифицируют host/site/service
[ ] Grafana показывает свежие меняющиеся данные
[ ] alert rules можно безопасно протестировать
```

## Что ещё снять с production

Чтобы сделать статью полностью implementation-specific, достаточно снять не секретные детали:

```bash
postgres_exporter --version 2>/dev/null || true
systemctl cat postgres_exporter
ss -lntp | grep -E ':9187\b|postgres_exporter'
```

И отдельно — обезличенный scrape job из Prometheus.

Не публикуйте database password и connection string с credentials.

## Ссылки

- postgres_exporter: <https://github.com/prometheus-community/postgres_exporter>
- Prometheus configuration: <https://prometheus.io/docs/prometheus/latest/configuration/configuration/>
- PostgreSQL monitoring statistics: <https://www.postgresql.org/docs/current/monitoring-stats.html>
- PostgreSQL predefined roles: <https://www.postgresql.org/docs/current/predefined-roles.html>
- Grafana documentation: <https://grafana.com/docs/grafana/latest/>
