---
title: "1С:Предприятие 8 + PostgreSQL + Apache на AlmaLinux"
description: "Базовая схема развёртывания сервера 1С:Предприятие 8, совместимой с 1С PostgreSQL-базы и веб-публикации через Apache 2.4 на AlmaLinux с явной проверкой матрицы совместимости и границ rollback."
category: "Приложения и сервисы"
tags: ["1c", "postgresql", "postgres-pro", "apache", "almalinux", "erp"]
published: 2026-09-16
updated: 2026-09-16
status: lab
testedOn: []
featured: true
lang: ru
translationKey: "applications/1c8-postgres-apache-almalinux"
---

## Контекст

Типовое Linux-развёртывание 1С:Предприятия обычно состоит из трёх отдельных слоёв:

```text
пользователи / web-клиенты
          |
          v
Apache 2.4
          |
          v
кластер серверов 1С:Предприятие 8
          |
          v
PostgreSQL-совместимый сервер БД
```

Эти слои нужно проверять независимо. Рабочая страница Apache не доказывает, что кластер 1С подключается к базе, а запущенный PostgreSQL не доказывает, что информационная база работает корректно.

Эта заметка намеренно имеет статус **лаборатория**, пока не подтверждены точные версии платформы 1С, дистрибутива/версии PostgreSQL и AlmaLinux в целевом окружении.

## Сначала проверяем матрицу совместимости

Не начинайте с установки пакетов. Сначала зафиксируйте и проверьте совместимость конкретной комбинации:

```text
версия платформы 1С:Предприятие
Linux-дистрибутив и major version
версия PostgreSQL/Postgres Pro
версия и архитектура Apache
```

В документации 1С список поддерживаемых Linux-дистрибутивов зависит от версии платформы. AlmaLinux совместим с RHEL, но это не означает автоматическую формальную поддержку любой версии платформы 1С.

Для БД используйте сборку PostgreSQL, которую поддерживает выбранная версия 1С. Не стоит автоматически считать штатный PostgreSQL из AlmaLinux AppStream подходящим для production 1С.

Postgres Pro публикует отдельные рекомендации по 1С и поддерживает современные AlmaLinux 9/10 в актуальных версиях. Если выбран Postgres Pro, используйте конкретную редакцию и версию, соответствующую приложению и лицензированию.

## Рекомендуемый порядок развёртывания

```text
подготовка ОС
  -> locale / time / DNS
  -> сервер БД
  -> серверные пакеты 1С
  -> проверка кластера 1С
  -> тестовая информационная база
  -> Apache
  -> web-публикация
  -> TLS / firewall
  -> backup / monitoring
```

Не публикуйте web endpoint наружу до проверки backend-слоёв.

## Подготовка AlmaLinux

Начинайте с минимальной обновлённой системы:

```bash
sudo dnf update -y
sudo hostnamectl status
sudo timedatectl status
```

Для 1С/PostgreSQL часто нужна русская UTF-8 locale. Проверка:

```bash
locale -a | grep -Ei 'ru_RU.*utf'
```

Если locale отсутствует, установите/сгенерируйте её до инициализации PostgreSQL-кластера.

Также проверьте прямое и обратное DNS-разрешение тех имён, которые реально будут использовать 1С и БД.

## Слой базы данных

### Используем PostgreSQL, поддерживаемый 1С

Источник пакетов БД — часть архитектуры, а не случайный выбор после установки ОС.

Возможные варианты: Postgres Pro или другая PostgreSQL-сборка, явно поддерживаемая выбранной платформой 1С.

Зафиксируйте:

```text
продукт БД
major/minor version
репозиторий/источник пакетов
путь к data directory
locale при initdb
метод аутентификации
метод резервного копирования
```

### Инициализация с правильной locale

Locale кластера БД важна. В рекомендациях Postgres Pro для 1С отдельно фигурирует русская UTF-8 locale.

До инициализации:

```bash
locale
```

Не создавайте production-кластер случайно под `C`/`POSIX`, рассчитывая исправить это позже.

### PostgreSQL должен оставаться внутренним сервисом

Сервер БД обычно должен слушать только адреса, необходимые серверу 1С.

Проверка:

```bash
ss -lntp | grep 5432
```

В `pg_hba.conf` ограничьте доступ адресами/подсетями серверов 1С.

TCP/5432 не должен быть опубликован в Internet.

### Тюнинг — только под реальную нагрузку

Не копируйте чужой `postgresql.conf` целиком.

Для 1С особенно важны число соединений, память на запросы, WAL/checkpoints, temp workload и storage latency.

Минимально проверьте:

```text
max_connections
shared_buffers
work_mem
maintenance_work_mem
effective_cache_size
checkpoint/WAL settings
locale/collation
storage latency
```

Конкретные значения зависят от RAM, CPU, размера базы и количества пользователей.

## Установка серверной части 1С:Предприятие 8

Linux-пакеты 1С — проприетарное ПО. Получите дистрибутив из авторизованного источника 1С и передайте его на сервер по согласованному каналу.

Не публикуйте RPM-пакеты 1С в открытом GitHub.

Перед установкой:

```bash
ls -1 *.rpm
rpm -qpi ./*.rpm | less
```

Установка:

```bash
sudo dnf install ./*.rpm
```

Имена RPM меняются между версиями платформы, поэтому не стоит жёстко зашивать историческое имя пакета в automation без намеренного pinning.

После установки:

```bash
rpm -qa | grep -Ei '1c|1cv8' | sort
```

## Находим фактически установленную версию 1С

На Linux бинарники 1С обычно находятся в versioned path под `/opt/1cv8/x86_64/`.

Не угадываем путь, а ищем:

```bash
find /opt/1cv8/x86_64 -maxdepth 2 -type f \
  \( -name 'webinst' -o -name 'rac' -o -name 'ras' \) \
  -print
```

Для web-публикации нужно использовать `webinst` той же версии платформы, что обслуживает информационную базу.

## Проверяем сервис 1С

Имена systemd units могут отличаться между релизами и пакетными схемами. Сначала обнаруживаем:

```bash
systemctl list-unit-files | grep -Ei '1c|srv1cv8'
```

Затем:

```bash
systemctl status '<обнаруженный-unit>' --no-pager
```

Не автоматизируйте enable/start по угаданному unit name.

Проверка сокетов:

```bash
ss -lntp | grep -E ':(1540|1541|156[0-9]|157[0-9]|158[0-9]|159[0-1])\b'
```

Точный набор портов должен соответствовать конфигурации кластера и firewall policy.

## Создание или подключение информационной базы

Базу создавайте через штатный поддерживаемый механизм администрирования выбранной версии 1С.

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

До настройки Apache убедитесь, что база открывается обычным клиентом 1С.

## Устанавливаем Apache 2.4

```bash
sudo dnf install -y httpd
sudo systemctl enable --now httpd
```

Проверка:

```bash
apachectl configtest
systemctl status httpd --no-pager
ss -lntp | grep -E ':(80|443)\b'
```

До готовности публикации держите доступ локальным или внутренним.

## Публикация ИБ через `webinst`

Для Apache 2.4 используется режим `-apache24`.

Сначала находим бинарник:

```bash
WEBINST=$(find /opt/1cv8/x86_64 -type f -name webinst | sort -V | tail -1)
printf '%s\n' "$WEBINST"
```

В production не выбирайте автоматически самый новый `webinst`, если на сервере установлено несколько версий платформы. Нужна версия, совпадающая с сервером 1С.

Каталог публикации:

```bash
sudo install -d -o root -g apache -m 0750 /var/www/1c/demo
```

Пример:

```bash
sudo "$WEBINST" \
  -publish \
  -apache24 \
  -wsdir demo \
  -dir /var/www/1c/demo \
  -connstr 'Srvr=1c-app.example.net:1541;Ref=demo;' \
  -confpath /etc/httpd/conf/httpd.conf
```

В публичной документации используйте placeholders вместо реальных имён серверов и ИБ.

После публикации:

```bash
sudo apachectl configtest
sudo systemctl reload httpd
```

Документация 1С также требует, чтобы Apache user имел read/execute-доступ к каталогу бинарников соответствующей версии платформы 1С.

## Проверяем конфигурацию Apache

```bash
grep -RniE '1cv8|wsap|demo' /etc/httpd /var/www/1c 2>/dev/null
```

Убедитесь, что путь к web extension существует и его архитектура совпадает с архитектурой Apache.

## SELinux

Не отключайте SELinux навсегда ради запуска публикации.

Проверка:

```bash
getenforce
```

Если Apache работает, а web-публикация 1С нет, смотрим AVC:

```bash
sudo ausearch -m AVC,USER_AVC -ts recent
```

Дальше исправляем контексты, права или создаём узкую local policy под реальный denial.

`setenforce 0` допустим только как временная диагностическая проверка, не как итоговая конфигурация.

## Firewall

Открывайте только реально необходимые направления.

```text
client -> Apache: 443
1C client/admin network -> порты кластера 1С
1C application tier -> PostgreSQL: 5432
Internet -> PostgreSQL: никогда
```

Если web-клиент нужен извне, используйте HTTPS и стандартный процесс управления сертификатами.

## Последовательность проверки

### PostgreSQL

```bash
systemctl --no-pager --type=service | grep -Ei 'postgres|pgpro'
ss -lntp | grep 5432
```

Затем проверьте подключение с сервера 1С утверждённой учёткой БД.

### Сервер 1С

```bash
systemctl list-units --type=service | grep -Ei '1c|srv1cv8'
ss -lntp | grep -E ':(1540|1541)\b'
```

Сначала база должна открываться обычным клиентом 1С.

### Apache

```bash
apachectl configtest
systemctl is-active httpd
curl -I http://127.0.0.1/
```

### Web-публикация

Проверьте реальный URI и выполните полноценный login в приложение. HTTP 200/302 сам по себе недостаточен.

## Backup и rollback

До production cutover нужны независимые recovery paths для всех трёх слоёв.

### База данных

Выберите метод под размер БД и RPO:

```text
logical dump — для небольших/простых случаев
physical/base backup — для крупных production БД
WAL/archive — когда нужен PITR
```

### Конфигурация 1С

Сохраняйте:

```text
версию/пакеты платформы 1С
service overrides и связанные системные настройки
настройки кластера
параметры регистрации ИБ
собственные scripts
```

### Apache

Перед повторным запуском `webinst` или сменой версии сохраняйте конфиги Apache и каталоги публикаций.

Rollback должен быть возможен без полной переустановки всего стека.

## Типовые ошибки

Не стоит:

- ставить штатный PostgreSQL без проверки поддержки 1С;
- инициализировать PostgreSQL с неправильной locale;
- открывать 5432 широким сетям;
- использовать `webinst` от другой версии платформы;
- копировать web-публикацию между несовместимыми версиями;
- отключать SELinux вместо исправления policy;
- открывать весь диапазон портов 1С всем сетям;
- считать рабочую страницу Apache доказательством здоровья ИБ;
- одновременно обновлять 1С, PostgreSQL и Apache без независимого rollback boundary.

## Что снять с реального сервера

Чтобы перевести статью из `lab` в `current`, достаточно подтвердить реальные не секретные версии:

```bash
cat /etc/os-release | grep -E '^(PRETTY_NAME|VERSION_ID)='
httpd -v
rpm -qa | grep -Ei '1c|1cv8' | sort
systemctl list-unit-files | grep -Ei '1c|srv1cv8'
systemctl --no-pager --type=service | grep -Ei 'postgres|pgpro'
```

Версию продукта БД также нужно снять отдельно, без публикации паролей.

После этого metadata и команды можно привязать к реальной production-схеме.

## References

- 1C:Enterprise: настройка web-сервера на Linux / Apache 2.4: <https://kb.1ci.com/1C_Enterprise_Platform/Guides/Administrator_Guides/1C_Enterprise_8.3.27_Administrator_Guide/Chapter_8.Setting_up_web_services_for_1C_Enterprise/8.4._Setting_up_client_application_support/8.4.2._On_Linux/>
- 1C `webinst`: <https://kb.1ci.com/1C_Enterprise_Platform/Guides/Administrator_Guides/1C_Enterprise_8.3.27_Administrator_Guide/Chapter_8.Setting_up_web_services_for_1C_Enterprise/8.3._Publication_types/8.3.3._Webinst_utility/>
- 1C: общая процедура web-публикации: <https://kb.1ci.com/1C_Enterprise_Platform/Guides/Administrator_Guides/1C_Enterprise_8.3.22_Administrator_Guide/Chapter_8._Setting_up_web_services_for_1C_Enterprise/8.3._Publication_types/8.3.1._General_publication_procedure/>
- Postgres Pro: настройка для 1С: <https://postgrespro.ru/docs/enterprise/16/config-one-c>
- Postgres Pro: установка и поддерживаемые Linux-дистрибутивы: <https://postgrespro.ru/docs/enterprise/17/binary-installation-on-linux>
