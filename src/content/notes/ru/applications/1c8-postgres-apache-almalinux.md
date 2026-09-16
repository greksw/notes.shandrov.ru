---
title: "1С:Предприятие 8 + Postgres Pro 1C + Apache на AlmaLinux"
description: "Production-схема развёртывания 1С:Предприятие 8.3.27, Postgres Pro 1C 17 и Apache 2.4 на AlmaLinux 9 с учётом service layout, web-публикации, monitoring и rollback."
category: "Приложения и сервисы"
tags: ["1c", "postgresql", "postgres-pro", "apache", "almalinux", "erp"]
published: 2026-09-16
updated: 2026-09-16
status: current
testedOn: ["AlmaLinux 9.8", "1С:Предприятие 8.3.27", "Postgres Pro 1C 17.10", "Apache 2.4.62"]
featured: true
lang: ru
translationKey: "applications/1c8-postgres-apache-almalinux"
---

## Контекст

Этот стек реально используется в production как трёхслойная схема:

```text
пользователи / web-клиенты
          |
          v
Apache 2.4
          |
          v
сервер 1С:Предприятие 8
          |
          v
Postgres Pro 1C 17
```

Подтверждённый baseline сервера:

```text
OS:              AlmaLinux 9.8
1С:Предприятие:  ветка 8.3.27
PostgreSQL:      Postgres Pro 1C 17.10
Apache:          2.4.62
```

На сервере установлено несколько build 1С 8.3.27, а default-instance включён для `8.3.27.2325`. Поэтому version-aware подход здесь обязателен: нельзя автоматически считать, что самый новый найденный binary всегда обслуживает production ИБ.

## Production service layout

На хосте раздельно представлены сервисы 1С, базы и monitoring. Обезличенный layout:

```text
postgrespro-1c-17.service
srv1cv8-8.3.27.1719.service
srv1cv8-8.3.27.1859.service
srv1cv8-8.3.27.2325@.service
srv1cv8-8.3.27.2325@default.service
postgres_exporter.service
fm-1c-metrics.service / fm-1c-metrics.timer
```

Postgres Pro работает отдельным systemd unit, PostgreSQL-метрики собираются через `postgres_exporter`, а для 1С есть отдельная metrics service/timer пара.

Это удобно для диагностики: application, database, web и monitoring слои можно проверять независимо.

## Порядок развёртывания

Рабочая последовательность:

```text
подготовка ОС
  -> locale / time / DNS
  -> Postgres Pro 1C
  -> пакеты сервера 1С
  -> проверка сервисов 1С
  -> проверка ИБ
  -> Apache
  -> web-публикация
  -> TLS / firewall
  -> backup / monitoring
```

Apache не должен быть первой точкой проверки. Сначала должен работать backend.

## Подготовка AlmaLinux

Начинайте с минимальной обновлённой системы:

```bash
sudo dnf update -y
sudo hostnamectl status
sudo timedatectl status
```

До инициализации БД проверьте locale:

```bash
locale -a | grep -Ei 'ru_RU.*utf'
```

Для 1С/PostgreSQL русская UTF-8 locale влияет на collation и поведение приложения, поэтому это не декоративная настройка.

Также проверьте прямое и обратное DNS-разрешение имён, которые реально используют 1С и БД.

## Установка Postgres Pro 1C

В production используется не штатный PostgreSQL из AlmaLinux AppStream, а специализированная сборка Postgres Pro 1C 17.

Установленный package family:

```text
postgrespro-1c-17
postgrespro-1c-17-client
postgrespro-1c-17-contrib
postgrespro-1c-17-libs
postgrespro-1c-17-server
```

Проверка версии:

```bash
psql --version
```

Подтверждённый baseline:

```text
psql (PostgreSQL) 17.10
```

Проверка сервиса:

```bash
systemctl status postgrespro-1c-17 --no-pager
ss -lntp | grep 5432
```

TCP/5432 должен оставаться внутренним сервисом. В `pg_hba.conf` разрешайте только реальные 1С application hosts и административные сети.

## Инициализация и тюнинг БД

До `initdb` должны быть определены:

```text
путь к data directory
locale / collation
listen addresses
pg_hba rules
backup method
WAL/archive policy
```

Не копируйте чужой `postgresql.conf` целиком.

Для 1С минимум проверяйте:

```text
max_connections
shared_buffers
work_mem
maintenance_work_mem
effective_cache_size
checkpoint/WAL settings
temporary workload
storage latency
```

Postgres Pro публикует отдельные рекомендации для 1С; их лучше брать за основу и затем проверять под реальной нагрузкой.

## Установка сервера 1С:Предприятие

Linux RPM 1С — проприетарные пакеты. Получайте их из авторизованного источника и не публикуйте в Git.

Перед установкой:

```bash
ls -1 *.rpm
rpm -qpi ./*.rpm | less
```

Установка:

```bash
sudo dnf install ./*.rpm
```

После установки лучше искать фактический layout, а не полагаться на исторические package names:

```bash
find /opt/1cv8/x86_64 -maxdepth 2 -type f \
  \( -name 'webinst' -o -name 'rac' -o -name 'ras' \) \
  -print
```

## Несколько build 1С на одном сервере

На production-хосте присутствует несколько сервисных build 8.3.27. Поэтому любые операции, зависящие от бинарников платформы, нужно привязывать к конкретной версии.

Проверка units:

```bash
systemctl list-unit-files | grep -Ei '1c|srv1cv8'
```

Проверка нужного instance:

```bash
systemctl status 'srv1cv8-8.3.27.2325@default.service' --no-pager
```

Для `webinst` используйте ту же версию платформы, которая обслуживает целевую ИБ.

Не выбирайте binary только потому, что он последний в сортировке по версии.

## Проверяем порты 1С

```bash
ss -lntp | grep -E ':(1540|1541|156[0-9]|157[0-9]|158[0-9]|159[0-1])\b'
```

Точный разрешённый диапазон должен соответствовать конфигурации кластера и firewall policy.

Не открывайте весь диапазон всем сетям.

## Создание или подключение ИБ

До Apache база должна открываться обычным клиентом 1С.

Зафиксируйте:

```text
кластер/сервер 1С
логическое имя ИБ
сервер БД
имя БД
учётную запись БД
locale/encoding
новая база или подключение существующей
```

Пароль БД не должен попадать в shell history, документацию и Git.

## Apache 2.4

Подтверждённая production-версия — Apache 2.4.62 из AlmaLinux.

Установка:

```bash
sudo dnf install -y httpd
sudo systemctl enable --now httpd
```

Проверка:

```bash
httpd -v
apachectl configtest
systemctl status httpd --no-pager
ss -lntp | grep -E ':(80|443)\b'
```

## Публикация ИБ через `webinst`

Для Apache 2.4 используется `-apache24`.

В production лучше указывать конкретный build явно:

```bash
WEBINST='/opt/1cv8/x86_64/8.3.27.2325/webinst'
```

Проверка:

```bash
test -x "$WEBINST"
```

Каталог публикации:

```bash
sudo install -d -o root -g apache -m 0750 /var/www/1c/demo
```

Пример публикации с обезличенными значениями:

```bash
sudo "$WEBINST" \
  -publish \
  -apache24 \
  -wsdir demo \
  -dir /var/www/1c/demo \
  -connstr 'Srvr=1c-app.example.net:1541;Ref=demo;' \
  -confpath /etc/httpd/conf/httpd.conf
```

Затем:

```bash
sudo apachectl configtest
sudo systemctl reload httpd
```

Apache account должен иметь read/execute-доступ к web extension выбранной версии 1С.

## Проверка Apache-конфигурации

```bash
grep -RniE '1cv8|wsap|demo' /etc/httpd /var/www/1c 2>/dev/null
```

Проверьте, что referenced web extension существует и его архитектура совпадает с Apache.

## SELinux

Не отключайте SELinux навсегда ради запуска публикации.

Проверка:

```bash
getenforce
```

Если Apache работает, а публикация 1С нет:

```bash
sudo ausearch -m AVC,USER_AVC -ts recent
```

Исправляйте file contexts, permissions или создавайте узкую local policy по фактическому denial.

`setenforce 0` допустим только как временная диагностическая проверка.

## Firewall model

Минимальная схема доступа:

```text
web clients              -> Apache: 443
1C client/admin networks -> необходимые порты 1С
1C application tier      -> Postgres Pro: 5432
Internet                 -> PostgreSQL: никогда
```

Если web-клиент публикуется наружу — используйте HTTPS и стандартный lifecycle сертификатов.

## Monitoring

На production-хосте уже есть:

```text
postgres_exporter.service
fm-1c-metrics.service
fm-1c-metrics.timer
```

Минимально имеет смысл контролировать:

```text
доступность PostgreSQL
connections
transactions / locks
WAL / checkpoint pressure
размер БД
доступность процессов 1С
порты кластера 1С
Apache
HTTP response web-публикации
CPU / RAM / storage latency
```

Monitoring должен видеть backend degradation, а не только факт ответа Apache.

## Последовательность проверки

Postgres Pro:

```bash
systemctl is-active postgrespro-1c-17
psql --version
ss -lntp | grep 5432
```

1С:

```bash
systemctl status 'srv1cv8-8.3.27.2325@default.service' --no-pager
ss -lntp | grep -E ':(1540|1541)\b'
```

Apache:

```bash
apachectl configtest
systemctl is-active httpd
curl -I http://127.0.0.1/
```

После этого проверьте реальный URI и выполните полноценный login в 1С. HTTP 200/302 сам по себе недостаточен.

## Backup и rollback

Для каждого слоя нужен отдельный recovery path.

Для БД:

```text
logical dump — небольшие/простые случаи
physical/base backup — крупные production БД
WAL/archive — когда нужен PITR
```

Также сохраняйте:

```text
версию и package information 1С
service overrides
настройки кластера
параметры регистрации ИБ
Apache config
каталоги web-публикаций
собственные monitoring scripts
```

Не объединяйте upgrade 1С, major upgrade Postgres Pro и переработку Apache в один rollback unit.

## Типовые ошибки

Не стоит:

- использовать stock PostgreSQL без проверки совместимости с 1С;
- инициализировать БД с неправильной locale;
- широко открывать 5432;
- использовать `webinst` от другого установленного build 1С;
- отключать SELinux вместо исправления policy;
- открывать полный диапазон портов 1С всем сетям;
- считать рабочую страницу Apache доказательством здоровья ИБ;
- одновременно менять 1С, Postgres Pro и Apache без независимых rollback points.

## References

- 1C:Enterprise: настройка web-сервера на Linux / Apache 2.4: <https://kb.1ci.com/1C_Enterprise_Platform/Guides/Administrator_Guides/1C_Enterprise_8.3.27_Administrator_Guide/Chapter_8.Setting_up_web_services_for_1C_Enterprise/8.4._Setting_up_client_application_support/8.4.2._On_Linux/>
- 1C `webinst`: <https://kb.1ci.com/1C_Enterprise_Platform/Guides/Administrator_Guides/1C_Enterprise_8.3.27_Administrator_Guide/Chapter_8.Setting_up_web_services_for_1C_Enterprise/8.3._Publication_types/8.3.3._Webinst_utility/>
- Postgres Pro: настройка для 1С: <https://postgrespro.ru/docs/enterprise/17/config-one-c>
- Postgres Pro: установка и поддерживаемые Linux-дистрибутивы: <https://postgrespro.ru/docs/enterprise/17/binary-installation-on-linux>
