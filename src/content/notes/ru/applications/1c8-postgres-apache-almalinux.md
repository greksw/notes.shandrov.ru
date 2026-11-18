---
title: "Установка сервера 1С:Предприятие 8.3 на AlmaLinux 9 с Postgres Pro 1C"
description: "Пошаговое руководство по установке 1С 8.3.27 на AlmaLinux 9 с Postgres Pro 1C 17, systemd, firewall, проверками, резервным копированием и необязательной публикацией через Apache."
category: "Приложения и сервисы"
tags: ["1c", "postgresql", "postgres-pro", "apache", "almalinux", "erp"]
published: 2026-09-16
updated: 2026-11-19
status: current
testedOn: ["AlmaLinux 9.8", "1С:Предприятие 8.3.27.2325", "Postgres Pro 1C 17.11", "Apache 2.4.62 (установлен)"]
featured: true
lang: ru
translationKey: "applications/1c8-postgres-apache-almalinux"
---

## Контекст

На производственном сервере 1С и Postgres Pro размещены совместно в одной виртуальной машине. Apache установлен и может использоваться для веб-публикаций, но **его активность на дату обновления статьи отдельно не подтверждена**. Следующая схема включает необязательный веб-уровень:

```text
пользователи / web-клиенты
          |
          v
Apache 2.4 (опционально)
          |
          v
сервер 1С:Предприятие 8
          |
          v
Postgres Pro 1C 17
```

Сводка производственного контура по диагностике октября–ноября 2026 года и ранее подтверждённым версиям:

~~~text
OS:             AlmaLinux 9.8
1С:Предприятие: 8.3.27.2325 (активный экземпляр ранее проверен)
СУБД:           Postgres Pro 1C 17.11
Ресурсы VM:     32 vCPU, около 258 GiB RAM
БД:             26 в контрольном снимке октября 2026 года; 1С и СУБД на одной VM
PGDATA:         /var/lib/pgpro/1c-17/data
Apache:         2.4.62 установлен; текущее состояние требует проверки
~~~

**Важно:** это эксплуатационный пример, а не универсальный профиль ресурсов. Значения 1С, СУБД и Apache получены из контрольных снимков разных дат; непосредственно перед использованием команд их нужно перепроверить. Публичная статья не раскрывает внутренние IP, имена информационных баз и схемы доступа организации.

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

## Требования и подготовка инсталляционных файлов

Понадобятся AlmaLinux 9 x86_64, серверная лицензия 1С, право получения дистрибутива нужного релиза с портала 1С, совместимая с ним сборка Postgres Pro 1C 17 и проверенное резервное хранилище. Для новой установки сначала уточните матрицу совместимости именно вашей конфигурации 1С и редакции СУБД. Не смешивайте пакеты различных редакций Postgres Pro и штатного PostgreSQL из AppStream.

Сервер можно установить на физический хост или VM. В рассматриваемом примере он развёрнут на KVM/Proxmox. Прежде чем использовать большой объём ОЗУ, оценивают реальную пиковую нагрузку и требуемое место для базы, WAL, временных файлов и резервных копий.

Инсталляторы 1С проприетарные: RPM-пакеты получают через разрешённый канал поставки, проверяют контрольные суммы и **не включают в публичный Git-репозиторий**. Список пакетов и unit-файлов может отличаться между сборками.

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

## Пакеты ОС и локализация

На новом AlmaLinux установите стандартные административные утилиты и русскую локаль:

~~~bash
sudo dnf install -y glibc-langpack-ru glibc-langpack-en \
  tar gzip unzip curl jq lsof fontconfig freetype \
  libgsf unixODBC firewalld
locale -a | grep -Ei '^ru_RU\.(utf8|UTF-8)

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

## Полная установка и первичная инициализация Postgres Pro 1C 17

Для редакции Postgres Pro 1C 17 требуется **соответствующий репозиторий поставщика**. Способ его подключения зависит от условий поставки; универсальный URL с ключами доступа в статье намеренно не приводится. Убедитесь, что пакет берётся из нужного источника:

~~~bash
sudo dnf repolist --enabled
sudo dnf list --showduplicates 'postgrespro-1c-17*'
~~~

Пример установки после подключения официального репозитория именно этой редакции:

~~~bash
sudo dnf install -y \
  postgrespro-1c-17-server \
  postgrespro-1c-17-client \
  postgrespro-1c-17-libs \
  postgrespro-1c-17-contrib
~~~

**Команды ниже — только для новой, пустой инсталляции после проверки утилиты в выбранной редакции.** На существующем srv-1c8c выполнять initdb повторно категорически нельзя: это операция создания кластера, а не обновления.

~~~bash
PGSETUP=/opt/pgpro/1c-17/bin/pg-setup
PGDATA=/var/lib/pgpro/1c-17/data
test -x "$PGSETUP" || { echo "pg-setup не найден"; exit 1; }
if test -e "$PGDATA/PG_VERSION"; then
  echo "Кластер уже инициализирован. initdb запрещён."
else
  echo "Пустой PGDATA: можно планировать initdb"
fi
~~~

На **заведомо новом кластере** после проверки способа установки через документацию пакета:

~~~bash
sudo /opt/pgpro/1c-17/bin/pg-setup initdb \
  --encoding=UTF8 --locale=ru_RU.UTF-8
sudo systemctl enable --now postgrespro-1c-17.service
~~~

Поведение пакетов при первичной инициализации зависит от редакции и способа установки; сначала убедитесь, что это не произошло. Параметры настройки под 1С (включая возможность --tune=1c) проверяйте в документации и выводе initdb --help **своей** редакции: нельзя переносить опции другой сборки без проверки.

~~~bash
sudo systemctl is-active postgrespro-1c-17.service
sudo -u postgres /opt/pgpro/1c-17/bin/psql \
  -XAt -d postgres -c 'SELECT version();'
sudo -u postgres /opt/pgpro/1c-17/bin/psql \
  -XAt -d postgres -c 'SHOW data_directory;'
sudo -u postgres /opt/pgpro/1c-17/bin/psql \
  -XAt -d postgres -c 'SHOW lc_collate;'
~~~

Для общей VM с 1С и PostgreSQL сначала предпочтительно подключение к СУБД локально, без публикации TCP/5432 в пользовательские сети. Если приложение или средства сопровождения работают на других хостах, разрешайте только необходимое сочетание адресов и методов аутентификации.

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

## Первичная безопасность PostgreSQL

После инициализации отдельно проверьте параметры подключения и правила HBA:

~~~bash
sudo -u postgres /opt/pgpro/1c-17/bin/psql -X -d postgres \
  -c "SHOW listen_addresses;"
sudo -u postgres /opt/pgpro/1c-17/bin/psql -X -d postgres \
  -c "SHOW password_encryption;"
sudo -u postgres /opt/pgpro/1c-17/bin/psql -X -d postgres \
  -c "SELECT line_number, type, database, user_name, \
  address, auth_method, error FROM pg_hba_file_rules;"
~~~

Для локальных административных подключений используйте peer вместо trust. Для сетевых соединений требуется аутентификация; SCRAM-SHA-256 и TLS предпочтительны, но перед переводом конкретного контура 1С убедитесь в совместимости и проверьте рабочие подключения. Замена правил на действующем сервере без консольного доступа и плана отката недопустима.

Отдельные прикладные роли вместо суперпользователя PostgreSQL уменьшают последствия компрометации, но настройка прав должна соответствовать механизмам создания баз и требованиям вашей платформы 1С. На обследованном сервере ранее выявлялось использование роли postgres приложением; это **остаточный риск**, а не рекомендуемая схема.

После любого изменения HBA:

~~~sql
SELECT pg_reload_conf();
SELECT * FROM pg_hba_file_rules WHERE error IS NOT NULL;
~~~

Вторая выборка должна возвращать ноль строк. Отсутствие ошибок синтаксиса не заменяет проверку фактического подключения клиента.

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

## Служебная учётная запись, systemd и данные кластера

При установке серверных RPM проверьте, каким пользователем запускается ragent. На исследованном хосте это usr1cv8:grp1cv8; не запускайте процессы 1С как root.

~~~bash
rpm -qa | grep -Ei '1c-enterprise|1c-enterprise83' | sort
systemctl list-unit-files | grep -Ei 'srv1cv8|1cv83'
systemctl cat 'srv1cv8-8.3.27.2325@default.service'
getent passwd usr1cv8
ps -eo user,group,pid,args | grep -E '[r]agent|[r]mngr|[r]phost'
~~~

Обычно данные кластера размещаются под домашним каталогом сервисной учётной записи. В рассматриваемом случае ранее использовался путь /home/usr1cv8/.1cv8/1C/1cv8. Фактический путь и параметры запуска получайте из systemd unit и environment-файлов: при установке нескольких сборок они различаются.

На новой системе проверьте владельца каталога, что к нему нет излишних прав, и сохраните конфигурацию запуска в эксплуатационном паспорте. **Не создавайте вручную копию производственного каталога данных кластера на работающий экземпляр без остановки/согласованного резервирования.**

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

## Проверка firewalld и модель сетевого доступа

Нормальная схема минимизации доступа: PostgreSQL 5432 — локально либо от подтверждённых серверов приложений; 1С 1540, 1541 и диапазон рабочих процессов — только от разрешённых терминальных серверов и администраторов; 22/tcp — только из административной сети; Apache 443 — только при действующей веб-публикации.

~~~bash
sudo firewall-cmd --state
sudo firewall-cmd --get-active-zones
sudo firewall-cmd --list-all
sudo firewall-cmd --list-rich-rules
sudo ss -lntp | grep -E ':(5432|1540|1541|15[6-9][0-9])\b'
~~~

Пример адресного правила для **учебного** IP из TEST-NET-1 (замените адрес на реальный доверенный источник и согласуйте полный портовый диапазон кластера):

~~~bash
sudo firewall-cmd --permanent \
  --add-rich-rule='rule family="ipv4" source address="192.0.2.10/32" port port="1540-1541" protocol="tcp" accept'
sudo firewall-cmd --reload
~~~

Это правило само по себе **не обеспечивает полную работоспособность клиентов 1С**: рабочие процессы используют отдельный настроенный диапазон. Перед изменением проверьте фактический диапазон в параметрах ragent и разрешите его только тем клиентам, которым он действительно необходим. Применяйте ограничения при сохранённой консоли VM, чтобы не потерять доступ SSH.

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

## Контрольная проверка клиент-серверной установки

До развёртывания Apache подключитесь штатным клиентом 1С к тестовой информационной базе и проверьте, что прикладные процессы и PostgreSQL отвечают. Со стороны Linux:

~~~bash
systemctl is-active postgrespro-1c-17.service
systemctl is-active 'srv1cv8-8.3.27.2325@default.service'
sudo journalctl -u postgrespro-1c-17.service -n 50 --no-pager
sudo journalctl -u 'srv1cv8-8.3.27.2325@default.service' \
  -n 50 --no-pager
ps -eo user,pid,args | grep -E '[r]agent|[r]mngr|[r]phost'
~~~

Убедитесь, что нет ошибок подключения, клиент открывает базу и выполняет тестовую операцию без пользовательских изменений в production. При проверке не создавайте демонстрационную базу поверх существующей.

## Apache 2.4 — необязательный веб-уровень

В ранее собранном инвентаре установлен Apache 2.4.62. В июньском снимке безопасности он был остановлен и отключён; перед использованием веб-публикации повторно проверьте статус и бизнес-необходимость сервиса. Если пользователи работают через тонкий клиент/RDS, Apache не является обязательной частью установки.

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

## Резервное копирование и восстановление

Для 1С на одной VM учитывайте разные уровни консистентности: PostgreSQL, данные кластера 1С, конфигурация systemd, лицензирование и конфигурация веб-публикации. Наличие VM-бэкапа **не равно** проверенной восстанавливаемости отдельных баз.

Для PostgreSQL можно использовать согласованные логические копии (pg_dump/pg_dumpall) и/или физические backup с журналами WAL. Выбор зависит от допустимых RPO/RTO и размера БД. Не копируйте файлы PGDATA простым cp/rsync на работающем кластере как единственный способ резервирования.

Минимальная проверка:

~~~bash
systemctl list-timers --all | grep -Ei 'backup|postgres|1c'
df -h
df -i
sudo -u postgres /opt/pgpro/1c-17/bin/psql -X -d postgres \
  -c "SELECT datname, pg_size_pretty(pg_database_size(oid)) \
      FROM pg_database WHERE datallowconn ORDER BY 1;"
~~~

В испытательном контуре выполняйте реальный restore одной базы, проверку целостности и вход клиента. Периодически фиксируйте время восстановления, дату копии и наличие ошибок. Контрольный restore нельзя подменять одним успешным завершением cron.

Для production также важно наблюдать WAL, переполнение файловой системы, возраст XID, autovacuum, длительные транзакции и задержки хранилища. По этой теме уже опубликован отдельный практический кейс: [обслуживание XID и VACUUM для 1С](/ru/notes/applications/postgres-pro-1c-xid-vacuum-maintenance/).

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

## Что относится к следующей статье

Здесь разобрана установка нового контура. Переключение с одной сборки 1С на другую — самостоятельная процедура: сверка совместимости, backup, установка параллельной версии, сохранение данных кластера, переключение systemd, проверка сервисов, рабочих процессов и пользовательских подключений, отдельный rollback. **Нельзя выполнять повторный initdb как часть обновления 1С.**

## References

- 1C:Enterprise: настройка web-сервера на Linux / Apache 2.4: <https://kb.1ci.com/1C_Enterprise_Platform/Guides/Administrator_Guides/1C_Enterprise_8.3.27_Administrator_Guide/Chapter_8.Setting_up_web_services_for_1C_Enterprise/8.4._Setting_up_client_application_support/8.4.2._On_Linux/>
- 1C `webinst`: <https://kb.1ci.com/1C_Enterprise_Platform/Guides/Administrator_Guides/1C_Enterprise_8.3.27_Administrator_Guide/Chapter_8.Setting_up_web_services_for_1C_Enterprise/8.3._Publication_types/8.3.3._Webinst_utility/>
- Postgres Pro: настройка для 1С: <https://postgrespro.ru/docs/enterprise/17/one-c-configuring-server>
- Postgres Pro: установка и поддерживаемые Linux-дистрибутивы (матрица редакций может отличаться): <https://postgrespro.ru/docs/enterprise/17/binary-installation-on-linux>
- Postgres Pro: pg-setup и параметры initdb (документация Standard; сверяйте путь для редакции 1С): <https://postgrespro.ru/docs/postgrespro/17/pg-setup>
- 1C:Enterprise: установка платформы на Linux: <https://kb.1ci.com/1C_Enterprise_Platform/FAQ/Administration/Server/Installing_1C_Enterprise_8_platform_on_Linux/>
- 1C:Enterprise: порты сервера: <https://kb.1ci.com/1C_Enterprise_Platform/FAQ/Administration/Server/Ports_setup_for_1C_Enterprise_server/>

hostname -f
timedatectl
getent ahostsv4 "$(hostname -f)"
~~~

Команда локализации лишь проверяет наличие нужной локали. **Collation уже существующей БД нельзя менять на работающем сервере простой сменой LANG**. Для новой БД locale выбирается на этапе initdb, после чего параметры проверяются запросом к PostgreSQL.

Проверьте также синхронизацию времени, DNS, места размещения PGDATA и доступ по консоли виртуализации до применения ограничений firewall/SSH.

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
