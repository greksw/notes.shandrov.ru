---
title: "Обслуживание PostgreSQL 17 для 1С: диагностика XID, VACUUM и autovacuum"
description: "Практический production-кейс Postgres Pro 1C 17.10: предупреждение XID 90,82%, поиск старых relfrozenxid, безопасный VACUUM 18 баз, проверка autovacuum и нюанс ONLY_DATABASE_STATS."
category: "Приложения и сервисы"
tags: ["postgresql", "postgres-pro", "1c", "vacuum", "autovacuum", "xid", "database", "monitoring"]
published: 2026-10-15
updated: 2026-10-15
status: current
testedOn: ["AlmaLinux 9", "Postgres Pro 1C 17.10", "1С:Предприятие 8.3"]
featured: true
lang: ru
translationKey: "applications/postgres-pro-1c-xid-vacuum-maintenance"
---

## Задача: предупреждение мониторинга о возрасте XID

В октябре 2026 года на production-сервере с Postgres Pro 1C 17.10, обслуживающем 26 информационных баз 1С, мониторинг показал увеличение возраста `datfrozenxid`. Наиболее высокий показатель достигал **181 631 691 транзакции** при `autovacuum_freeze_max_age = 200000000` — **90,82% от порога принудительного anti-wraparound autovacuum**.

Это **не означает, что до переполнения 32-битного счётчика XID осталось 9,18%**. `autovacuum_freeze_max_age` — защитный порог для инициирования агрессивной очистки, а не физический предел счётчика. Тем не менее приближение к нему требует диагностики, особенно когда сервер обслуживает множество активных баз.

Работа проводилась на нагруженной системе; задача состояла в том, чтобы снизить возраст XID, не останавливая сервис 1С и не запускать разрушительно-блокирующие операции.

## Подтверждённый результат

| Показатель | До | После |
| --- | ---: | ---: |
| Количество баз на сервере | 26 | 26 |
| Баз, включённых в контролируемое обслуживание | 18 | 18 обработаны |
| Максимальный возраст XID | 181 631 691 | менее 160 000 000 во всех БД |
| Максимум относительно `autovacuum_freeze_max_age` | 90,82% | менее 80% |
| Пример одной базы | 181 335 365 | 152 808 739 |
| Максимальный возраст после работ | — | 159 997 686 (около 80%) |
| Возраст MultiXact в итоговой проверке | — | 0 |

Имена производственных баз в публичной статье заменены числами. Значения отражают диагностические замеры на момент работ, а не постоянные характеристики системы: возраст XID продолжает расти по мере выполнения транзакций.

## Окружение и границы кейса

- ОС: AlmaLinux 9, экземпляр Postgres Pro **1C 17.10**.
- Система: сервер баз данных для **1С:Предприятие 8.3**, 26 БД.
- PostgreSQL запущен как отдельный systemd-сервис `postgrespro-1c-17`.
- Метрики PostgreSQL собирает `postgres_exporter`.
- На этапе проверки диска оставалось порядка **53 ГБ свободного пространства**, файловая система была занята примерно на **83%**.
- Выполнено контролируемое последовательное обслуживание 18 баз, без `VACUUM FULL`.

Этот материал — **разбор конкретного эксплуатационного случая**, а не универсальный рецепт тюнинга для всех конфигураций 1С. Доступ к БД выполнялся локально под административной учётной записью PostgreSQL.

## 1. Чем опасен рост XID age

PostgreSQL использует MVCC: обновление или удаление строк оставляет старые версии кортежей до последующей очистки. `VACUUM` освобождает место для повторного использования и помогает продвигать `relfrozenxid`. При длительном отсутствии эффективной очистки система может приблизиться к защите от **transaction ID wraparound**.

Два разных показателя важно не путать:

- `age(datfrozenxid)` — возраст самого старого незамороженного XID, учтённого на уровне **базы данных**.
- `age(relfrozenxid)` — соответствующий возраст **отношения**: пользовательской таблицы, системного каталога, TOAST-таблицы и т. д.

`datfrozenxid` определяется старейшими значениями в отношениях этой базы. Поэтому одна забытая системная или TOAST-таблица может удерживать высокий показатель всей БД.

## 2. Базовая проверка без изменений

Сначала собираем факты, не перезапускаем сервер и не меняем параметры наугад.

~~~bash
systemctl is-active postgrespro-1c-17
df -h
sudo -u postgres psql -X -d postgres -P pager=off
~~~

Дальнейшие SQL-запросы можно выполнять в открытой консоли `psql`.

~~~sql
SELECT version();

SHOW autovacuum;
SHOW autovacuum_freeze_max_age;
SHOW autovacuum_max_workers;
SHOW autovacuum_naptime;
SHOW maintenance_work_mem;
SHOW log_autovacuum_min_duration;
~~~

Для сервера из кейса были подтверждены: `autovacuum = on`, `autovacuum_max_workers = 16`, `autovacuum_naptime = 20s`, `maintenance_work_mem = 1GB`, `autovacuum_vacuum_cost_delay = 2ms`. Значение `autovacuum_vacuum_cost_limit = -1` означало наследование обычного `vacuum_cost_limit = 1600`.

Эти значения **не предлагаются как рекомендуемые настройки**: они приведены, чтобы показать фактические условия диагностики.

## 3. Находим проблемные базы

Выполняем из любой БД кластера:

~~~sql
SELECT
    datname,
    age(datfrozenxid) AS xid_age,
    round(
      100.0 * age(datfrozenxid) /
      current_setting('autovacuum_freeze_max_age')::numeric, 2
    ) AS pct_of_freeze_limit,
    mxid_age(datminmxid) AS mxid_age,
    datallowconn
FROM pg_database
ORDER BY age(datfrozenxid) DESC;
~~~

Проценты в этом запросе измеряют **долю от `autovacuum_freeze_max_age`**, а не вероятность потери данных. Ищем базы со стабильно высоким или растущим возрастом, сравниваем с предыдущими замерами и временем последней очистки.

В кейсе для контролируемого обслуживания были выбраны 18 баз. Остальные базы не подвергались ручному `VACUUM` без необходимости.

## 4. Выясняем, какие отношения удерживают старые XID

Запрос ниже нужно выполнять **внутри конкретной проблемной БД**, а не только в служебной `postgres`.

~~~sql
SELECT
    n.nspname AS schema_name,
    c.relname AS relation_name,
    c.relkind,
    age(c.relfrozenxid) AS xid_age,
    mxid_age(c.relminmxid) AS mxid_age
FROM pg_class AS c
JOIN pg_namespace AS n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'm', 't')
ORDER BY age(c.relfrozenxid) DESC
LIMIT 30;
~~~

`relkind = 'r'` — обычная таблица, `'m'` — материализованное представление, `'t'` — TOAST. Внимание к системным каталогам `pg_catalog` обязательно: ограничение запросов только схемой `public` скроет часть проблемы.

В нашем случае старые XID удерживали **системные каталоги, пользовательские таблицы и TOAST**, поэтому проверять только пользовательские таблицы было бы недостаточно.

Дополнительно оцениваем накопление мёртвых строк и историю autovacuum:

~~~sql
SELECT
    schemaname, relname, n_live_tup, n_dead_tup,
    last_vacuum, last_autovacuum,
    vacuum_count, autovacuum_count
FROM pg_stat_all_tables
ORDER BY n_dead_tup DESC
LIMIT 25;
~~~

`n_dead_tup` — приблизительная статистика, а нулевой `last_autovacuum` у конкретной таблицы сам по себе не означает неисправность daemon.

## 5. Проверяем блокирующие факторы

Перед обслуживанием стоит исключить долгие транзакции, старые snapshots, prepared transactions и слоты репликации.

~~~sql
SELECT
    pid, datname, usename, state,
    now() - xact_start AS xact_duration,
    backend_xmin, wait_event_type, wait_event
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
ORDER BY xact_start;
~~~

~~~sql
SELECT gid, database, prepared
FROM pg_prepared_xacts
ORDER BY prepared;
~~~

~~~sql
SELECT slot_name, slot_type, active,
       xmin, catalog_xmin, restart_lsn
FROM pg_replication_slots;
~~~

В расследованном инциденте **долгие транзакции, prepared transactions и слоты репликации не объясняли высокий XID age**. Это не повод удалять существующие слоты на других системах: такой шаг без анализа восстановления или репликации опасен.

## 6. Autovacuum включён — почему всё равно возникло предупреждение?

Проверить состояние процессов:

~~~sql
SELECT backend_type, pid, datname, state,
       wait_event_type, wait_event
FROM pg_stat_activity
WHERE backend_type LIKE 'autovacuum%'
ORDER BY backend_type, pid;
~~~

На сервере присутствовал **autovacuum launcher**, но в отдельном моментальном снимке не было worker-процессов. **Отсутствие worker в одну секунду не доказывает, что autovacuum не работает**: они создаются по мере появления подходящих задач и завершаются после обработки.

Сопоставляйте одновременно:

- настройки `autovacuum` и `track_counts`;
- `pg_stat_all_tables` и динамику `last_autovacuum`;
- `pg_stat_progress_vacuum` во время выполнения;
- записи логов о долгих autovacuum;
- загрузку диска и конкуренцию с рабочими транзакциями 1С.

Не рекомендуется настраивать запуск новых worker исключительно по одному снимку `ps` или `pg_stat_activity`.

## 7. Контролируемый VACUUM без остановки 1С

Перед вмешательством нужно проверить восстановимость резервной копии, свободное место, фоновые задания 1С, нагрузку I/O и наличие подходящего окна обслуживания. Обычный `VACUUM` допускает параллельную работу с `SELECT`/`INSERT`/`UPDATE`/`DELETE`, но создаёт дисковую нагрузку и может конфликтовать с DDL.

В этом случае базы обрабатывались **последовательно**. Пример для одной обезличенной БД:

~~~bash
DB='accounting_demo'

sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d "$DB" \
  -c "VACUUM (TRUNCATE FALSE, SKIP_DATABASE_STATS, PARALLEL 0);"

sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d "$DB" \
  -c "VACUUM (ONLY_DATABASE_STATS);"
~~~

Смысл параметров:

- `TRUNCATE FALSE` — не пытаться обрезать пустые страницы в конце таблиц; это помогает избегать связанных с truncation эксклюзивных блокировок.
- `PARALLEL 0` — отключить параллельные worker для обработки индексов конкретного `VACUUM`, снижая непредсказуемость фоновой конкуренции.
- `SKIP_DATABASE_STATS` — отложить пересчёт database-wide значения старейшего XID.
- `ONLY_DATABASE_STATS` — **после обработки** обновить эту агрегированную статистику без повторной очистки таблиц.

`VACUUM` запускается отдельной командой, **не внутри `BEGIN/COMMIT`**. Здесь `ANALYZE` не является обязательной частью операции по снижению XID age; актуальность статистики планировщика проверяется отдельно.

Использование `TRUNCATE FALSE` и `PARALLEL 0` не делает нагрузку нулевой. При росте latency, lock wait или жалобах пользователей 1С следующую базу не запускаем, пока не разобрались с причиной.

## 8. Главный нюанс PostgreSQL 17: SKIP_DATABASE_STATS

После выполнения `VACUUM (..., SKIP_DATABASE_STATS)` возраст отдельных отношений может уменьшиться, **но `age(datfrozenxid)` продолжит показывать старый уровень**.

Это не обязательно ошибка `VACUUM`: параметр сознательно пропускает пересчёт database-wide сведений. Важный завершающий шаг:

~~~sql
VACUUM (ONLY_DATABASE_STATS);
~~~

Команда должна выполняться **в каждой обслуженной БД**, если предыдущие вызовы `VACUUM` пропускали пересчёт. `ONLY_DATABASE_STATS` нельзя объединять с `ANALYZE`, `PARALLEL`, `TRUNCATE` и прочими включёнными опциями, кроме `VERBOSE`.

Если после пересчёта показатель не снизился, надо вновь проверить самые старые `relfrozenxid` и возможные ограничения на продвижение горизонта очистки. Команда **не замораживает XID самостоятельно** — она лишь обновляет сводную информацию.

Именно различие между возрастом отношений и возрастом базы помогло правильно интерпретировать итоговые показания мониторинга в этом кейсе.

## 9. Как наблюдать выполнение VACUUM

Во время обслуживания:

~~~sql
SELECT
    pid, datname, relid::regclass AS relation_name,
    phase, heap_blks_total, heap_blks_scanned,
    round(
      100.0 * heap_blks_scanned /
      NULLIF(heap_blks_total, 0), 1
    ) AS scan_pct
FROM pg_stat_progress_vacuum
ORDER BY datname, pid;
~~~

`scan_pct` показывает долю **сканированных блоков heap**, а не точный процент выполнения всей операции: после сканирования могут оставаться этапы обработки индексов и очистки.

Оцениваем задержки и блокировки:

~~~sql
SELECT pid, datname, state, wait_event_type, wait_event,
       now() - query_start AS query_duration
FROM pg_stat_activity
WHERE state = 'active'
ORDER BY query_start;
~~~

Использование `pg_stat_progress_vacuum` и `pg_stat_activity` помогает не принимать длительный, но работающий `VACUUM` за зависший процесс.

## 10. Диагностическое логирование autovacuum

Исходное значение `log_autovacuum_min_duration` составляло **600000 ms (10 минут)**. В процессе диагностики временно установили **60 секунд**, чтобы выявить длительные операции.

~~~sql
SELECT name, setting, unit, source, sourcefile
FROM pg_settings
WHERE name = 'log_autovacuum_min_duration';
~~~

Если конфигурация допускает `ALTER SYSTEM` и изменение согласовано с политикой администрирования:

~~~sql
ALTER SYSTEM SET log_autovacuum_min_duration = '60s';
SELECT pg_reload_conf();
SHOW log_autovacuum_min_duration;
~~~

На исследованном сервере журналирование использовало `logging_collector = on`, `log_destination = stderr` и каталог `log/` относительно `data_directory`. Для ориентира:

~~~bash
PGDATA=$(sudo -u postgres psql -XAt -d postgres \
  -c 'SHOW data_directory;')

grep -Ei 'autovacuum|automatic vacuum|автоматическ.*очист' \
  "$PGDATA"/log/postgresql-*.log | tail -n 80
~~~

Лог изменения параметра **не равен доказательству успешно завершённого autovacuum**. Следует искать именно сообщения о выполненных очистках и соотносить их с `pg_stat_all_tables`.

Временную диагностическую настройку не оставляем без решения о сроке хранения и объёме логов. Для возвращения **зафиксированного исходного значения из кейса**:

~~~sql
ALTER SYSTEM SET log_autovacuum_min_duration = '600000ms';
SELECT pg_reload_conf();
~~~

Это пример восстановления исходного значения, **не подтверждение, что возврат уже состоялся**. На другой системе сперва запишите исходное значение и его источник, особенно если конфигурация управляется Ansible или другой автоматизацией.

## 11. Проверяем результат, а не только код завершения

Снова собираем сводку по всем базам:

~~~sql
SELECT
    datname,
    age(datfrozenxid) AS xid_age,
    round(
      100.0 * age(datfrozenxid) /
      current_setting('autovacuum_freeze_max_age')::numeric, 2
    ) AS pct_of_freeze_limit,
    mxid_age(datminmxid) AS mxid_age
FROM pg_database
ORDER BY age(datfrozenxid) DESC;
~~~

В нашем случае завершено обслуживание **18 баз из 26**. Контроль показал:

- ни одна БД не имела зафиксированного возраста отношений выше 160 млн XID;
- максимальный возраст на уровне БД после обслуживания — **159 997 686**, примерно **80%** `autovacuum_freeze_max_age`;
- одна из первоначально проблемных БД снизилась с **181 335 365** до **152 808 739**;
- возраст MultiXact во всех проверенных базах составлял **0**.

Код завершения `psql` сам по себе недостаточен: сверяйте `relfrozenxid`, `datfrozenxid`, ошибки в журналах и работоспособность прикладных сеансов 1С.

## 12. Что отслеживать далее

Для `postgres_exporter`/Prometheus/Grafana разумно собирать:

- `age(datfrozenxid)` и долю от `autovacuum_freeze_max_age` **по каждой БД**;
- `mxid_age(datminmxid)` и отношение к `autovacuum_multixact_freeze_max_age`;
- возраст наиболее старых `relfrozenxid` на уровне отношений;
- число и продолжительность активных autovacuum;
- `n_dead_tup`, `last_autovacuum`, долгие транзакции и блокировки;
- свободное место, I/O latency, WAL и успешность резервного копирования.

Пример диагностического запроса-источника для будущего экспортера:

~~~sql
SELECT
    datname,
    age(datfrozenxid) AS xid_age,
    current_setting('autovacuum_freeze_max_age')::bigint
        AS xid_freeze_limit
FROM pg_database
WHERE datallowconn;
~~~

**Это пример метрик, а не утверждение, что для них уже созданы правила alerting.** Пороги предупреждений, интервалы опроса и эскалацию следует выбирать по реальной скорости роста XID. Значение 80% здесь — ориентир результатов кейса, а не универсальная безопасная граница.

## Чего не делали

- Не запускали `VACUUM FULL`: он требует `ACCESS EXCLUSIVE` и переписывает таблицы, что нежелательно на активной 1С.
- Не выполняли массовый `REINDEX` и не удаляли вручную файлы `pg_xact`/`pg_wal`.
- Не отключали autovacuum и не повышали `autovacuum_freeze_max_age` только ради исчезновения тревоги.
- Не запускали одновременно `VACUUM` во всех 26 базах.
- Не считали отсутствие autovacuum worker в единичном снимке доказательством поломки.

## Вывод

Предупреждение о `datfrozenxid` оказалось поводом для **диагностики и контролируемого обслуживания**, а не аварийного перезапуска СУБД. Последовательный `VACUUM`, проверка старых отношений, учёт TOAST/системных каталогов и отдельный `VACUUM (ONLY_DATABASE_STATS)` позволили снизить показатель во всех затронутых базах и проверить эффект на уровне всего кластера.

Открытые задачи после обслуживания: наблюдать динамику XID, получить репрезентативные записи autovacuum при временном пороге 60 секунд, решить вопрос о возврате логирования к исходному значению и проверить выбранные пороги мониторинга.

Связанный материал: [Развёртывание 1С:Предприятие 8, Postgres Pro 1C и Apache на AlmaLinux](/ru/notes/applications/1c8-postgres-apache-almalinux/).

## Документация

- [PostgreSQL 17 — Routine Vacuuming](https://www.postgresql.org/docs/17/routine-vacuuming.html)
- [PostgreSQL 17 — VACUUM, включая SKIP_DATABASE_STATS и ONLY_DATABASE_STATS](https://www.postgresql.org/docs/17/sql-vacuum.html)
- [PostgreSQL 17 — Automatic Vacuuming](https://www.postgresql.org/docs/17/runtime-config-autovacuum.html)
- [PostgreSQL 17 — Monitoring Database Activity](https://www.postgresql.org/docs/17/monitoring.html)
- [PostgreSQL 17 — Progress Reporting](https://www.postgresql.org/docs/17/progress-reporting.html)
