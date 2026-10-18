---
title: "Immich на TrueNAS SCALE: собственное Google Фото, Android, HTTPS и ZFS"
description: "Практический кейс: Immich на TrueNAS SCALE 25.10, RAIDZ2, фотографии с Android, Split DNS на MikroTik, Nginx/Let's Encrypt и резервирование PostgreSQL с ZFS snapshots."
category: "Хранение и резервное копирование"
tags: ["immich", "truenas", "truenas-scale", "zfs", "android", "mikrotik", "nginx", "letsencrypt", "postgresql", "backup", "self-hosted"]
published: 2026-10-18
updated: 2026-10-18
status: current
testedOn: ["TrueNAS SCALE 25.10.7", "Immich 3.3.3", "TrueNAS Apps 1.14.52", "PostgreSQL 18", "MikroTik RouterOS 7", "Nginx 1.20.1", "Android 16"]
featured: false
lang: ru
translationKey: "storage-backup/immich-truenas-scale-android-zfs-https"
---

## Контекст и результат

Задача — заменить Google Фото домашним хранилищем: автоматически выгружать снимки и видео с Android из любой сети, сохранять оригиналы на NAS и иметь единый URL как дома, так и через LTE/5G.

Использовали **Immich** из каталога приложений TrueNAS SCALE, **ZFS RAIDZ2**, Nginx с сертификатом Let's Encrypt и Split DNS на MikroTik. На момент завершения настройки первоначальная синхронизация порядка **3,7 тыс. файлов** закончилась; библиотека занимала около **41 GiB**. Сервер Immich, PostgreSQL, Redis и Machine Learning находились в состоянии \`healthy\`. Штатный дамп PostgreSQL создан и проверен, baseline snapshots выполнены, ежедневное задание snapshots настроено.

**Граница результата:** независимый backup на отдельный USB-диск пока **не настроен**; диск будет подключён позднее. Первый автоматический ночной цикл также ещё не проверен. Ни RAIDZ2, ни snapshots на том же NAS не заменяют внешнюю копию.

В примерах ниже IP, имена машин и домен заменены на условные. Публичные адреса документационного диапазона и домен \`example.com\` не являются настоящими endpoint этой инфраструктуры.

## 01 / Архитектура

\`\`\`text
Android / браузер
      │ https://photos.example.com
      ├── LTE/5G ── публичный IP 203.0.113.10:443
      │                 │ DNAT MikroTik
      └── Wi-Fi ── Split DNS → 192.168.10.20:443
                                │
                         Nginx reverse proxy
                                │ HTTP/LAN
                         192.168.10.10:30041
                                │
                         TrueNAS SCALE / Immich
                                │
                    ZFS media + PostgreSQL
\`\`\`

Для смартфона используется **один HTTPS URL**, внутренний и внешний DNS возвращают разные IP. Пробрасывать наружу порт приложения \`30041\` и административный интерфейс TrueNAS не нужно.

## 02 / Диски и ресурсы

Тестовый NAS: один NVMe для \`boot-pool\` и четыре HDD по 8 TB в **RAIDZ2** для пула \`data\`. Оперативной памяти — около 30 GiB. Отдельного SSD-пула под Apps не было, поэтому и PostgreSQL, и медиатека размещены на HDD. Это работоспособно, но на первоначальной индексации увеличивает I/O и не способствует засыпанию дисков.

Ориентиры для Immich в этом стенде:

| Параметр | Значение |
|---|---|
| CPU limit | 4 |
| Memory limit | 8192 MiB |
| User / Group | 568 / 568 |
| Machine Learning | CPU, стандартный образ |
| Database storage type | HDD |
| Web UI port | 30041 |
| GPU passthrough | выключен |

NVMe, используемый для загрузки TrueNAS, не переразмечали и PostgreSQL на \`boot-pool\` не переносили.

## 03 / Подготовка ZFS datasets

Для удобного резервирования создаём отдельные datasets:

\`\`\`text
data/immich
├── data      # оригиналы, миниатюры, дампы Immich
└── pgData    # PostgreSQL
\`\`\`

На TrueNAS:

\`\`\`bash
zfs create -p \
  -o compression=lz4 -o atime=off \
  data/immich/data

zfs create \
  -o compression=lz4 -o atime=off \
  -o recordsize=16K \
  data/immich/pgData

chown 568:568 /mnt/data/immich/data
chmod 750 /mnt/data/immich/data

zfs list -r data/immich
zfs get mountpoint,compression,recordsize,atime \
  data/immich/data data/immich/pgData
\`\`\`

В медиатеке остался \`recordsize=128K\`, в \`pgData\` — \`16K\`. Это выбранные для стенда значения, а не универсально оптимальные настройки PostgreSQL на RAIDZ2.

Для PostgreSQL исходно оставляем каталог \`pgData\` под \`root:root\`: права назначит установщик приложения. Не выполняем рекурсивный \`chown\` по существующим архивам пользователя.

## 04 / Установка из TrueNAS Apps

Путь: **Apps → Discover Apps → Immich → Install**.

Ключевые поля:

| Раздел | Настройка |
|---|---|
| Immich Configuration | Postgres 18, HDD, разные сильные пароли БД и Redis |
| User and Group | UID/GID 568 |
| Network | WebUI 30041; metrics-порты не публикуются |
| Data Storage | \`Host Path\` → \`/mnt/data/immich/data\` |
| Postgres Data Storage | \`Host Path\` → \`/mnt/data/immich/pgData\` |
| Postgres Automatic Permissions | **Enabled** |
| Machine Learning Cache | Temporary |
| Resources | 4 CPU, 8192 MiB |

После установки права \`pgData\` были назначены PostgreSQL-пользователю \`999:999\`. Значения UID могут зависеть от версии контейнерного шаблона: ориентируйтесь на текущую документацию и UI, а не меняйте права наугад.

**Нюанс с Redis:** текущий шаблон отклонил пароль с символом \`#\`:

\`\`\`text
RenderError: Redis password cannot contain [#]
\`\`\`

Решение — заменить Redis-пароль на другой случайный, удовлетворяющий требованиям шаблона, и повторить установку. Например, получить буквенно-цифровой hex-пароль:

\`\`\`bash
openssl rand -hex 32
\`\`\`

Не публикуйте настоящие пароли, токены Selectel или файлы приватных ключей.

Проверка:

\`\`\`bash
midclt call app.query | jq -r \
  '.[] | select(.name=="immich") | [.name,.state,.version] | @tsv'

docker ps --filter name=ix-immich \
  --format 'table {{.Names}}\t{{.Status}}'

curl -fsS http://127.0.0.1:30041/api/server/ping
\`\`\`

Получили \`RUNNING\`, четыре \`healthy\` контейнера и ответ \`{"res":"pong"}\`.

## 05 / Публичный HTTPS: Nginx вместо прямого проброса Immich

Домашний MikroTik уже пересылал TCP/443 на Nginx reverse proxy. Дополнительное правило DNAT на порт 30041 не потребовалось.

Nginx работает на отдельном узле. Сертификаты выпускает \`acme.sh\` через **DNS-01** с провайдером Selectel (\`dns_selectel\`); ежедневная проверка продления выполняется systemd timer. Это позволило не менять проброс TCP/80, используемый другим сервисом.

После предварительно настроенного и защищённого DNS API клиента:

\`\`\`bash
/root/.acme.sh/acme.sh \
  --issue --dns dns_selectel \
  -d photos.example.com \
  --keylength ec-256 \
  --server letsencrypt

install -d -m 700 /etc/nginx/tls/photos.example.com

/root/.acme.sh/acme.sh \
  --install-cert -d photos.example.com --ecc \
  --fullchain-file /etc/nginx/tls/photos.example.com/fullchain.pem \
  --key-file /etc/nginx/tls/photos.example.com/privkey.pem \
  --reloadcmd "nginx -t && systemctl reload nginx"
\`\`\`

Для другого DNS-провайдера нужен соответствующий плагин acme.sh. Домен \`photos.example.com\` замените своим, предварительно настроив A-запись и DNS API.

Отдельный файл \`/etc/nginx/conf.d/photos.example.com.conf\` для **Nginx 1.20.1**:

\`\`\`nginx
server {
    listen 192.168.10.20:443 ssl http2;
    server_name photos.example.com;

    ssl_certificate /etc/nginx/tls/photos.example.com/fullchain.pem;
    ssl_certificate_key /etc/nginx/tls/photos.example.com/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 50000M;
    client_body_buffer_size 1024k;
    proxy_request_buffering off;

    proxy_connect_timeout 30s;
    proxy_read_timeout 600s;
    proxy_send_timeout 600s;
    send_timeout 600s;

    access_log /var/log/nginx/photos.access.log;
    error_log /var/log/nginx/photos.error.log warn;

    location / {
        proxy_pass http://192.168.10.10:30041;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_redirect off;
    }
}
\`\`\`

\`http2 on;\` здесь намеренно не используется: это синтаксис более новых версий Nginx. Прежде чем применять изменения, сохраняем исходную конфигурацию; \`reload\` — только после успешного \`nginx -t\`.

## 06 / Split DNS на MikroTik: без Hairpin NAT

При наличии DNAT только на WAN интерфейсе попытка открыть публичный IP из Wi-Fi может не сработать. В данном стенде это решено локальной A-записью на MikroTik:

\`\`\`routeros
/ip dns set allow-remote-requests=yes

/ip dns static add \
  name=photos.example.com \
  type=A \
  address=192.168.10.20 \
  ttl=1h \
  comment="Immich | Split DNS"

:put [:resolve "photos.example.com" server=192.168.10.1]
\`\`\`

Локальный результат — \`192.168.10.20\`, публичный DNS — \`203.0.113.10\`. DHCP в домашней сети должен выдавать клиентам DNS MikroTik. На Android отдельно проверяем **Частный DNS**, VPN и DNS-over-HTTPS: они могут обходить локальную запись.

Мобильное приложение сначала использовало локальный HTTP endpoint и внешний HTTPS endpoint. После настройки Split DNS перевели его на **единый HTTPS-адрес** для обеих сетей.

## 07 / Проверка TLS и API

На reverse proxy можно протестировать конкретный IP независимо от публичного резолвинга:

\`\`\`bash
curl -sS -o /dev/null \
  --resolve photos.example.com:443:192.168.10.20 \
  -w 'HTTP %{http_code}\n' \
  https://photos.example.com/

curl -fsS \
  --resolve photos.example.com:443:192.168.10.20 \
  https://photos.example.com/api/server/ping

curl -sSI \
  --resolve photos.example.com:443:192.168.10.20 \
  https://photos.example.com/.well-known/immich
\`\`\`

В нашем тесте главная страница и \`/.well-known/immich\` вернули HTTP 200, API — \`{"res":"pong"}\`. Другой HTTPS-vhost продолжил обслуживаться со своим TLS-сертификатом по SNI.

Если Nginx неожиданно отдаёт сертификат другого домена, сначала проверяем \`nginx -T\`, значение \`server_name\`, SNI через \`openssl s_client -servername\` и факт успешного \`reload\`, а не перевыпускаем сертификаты вслепую.

## 08 / Android: автоматическая синхронизация

Установили официальное приложение Immich, предоставили доступ к выбранным альбомам и включили резервирование камеры.

Для фоновой работы Android полезно проверить:

- разрешение доступа ко всем нужным фото/видео;
- отсутствие жёсткой оптимизации аккумулятора для Immich;
- разрешение фоновой передачи данных;
- режимы загрузки по мобильной сети, если это необходимо;
- адрес сервера: \`https://photos.example.com\`.

Во время первоначальной синхронизации Nginx фиксировал:

\`\`\`text
POST /api/assets                 → 201 Created
PUT  /api/albums/.../assets      → 200 OK
POST /api/sync/stream            → 200 OK
POST /api/sync/ack               → 204 No Content
\`\`\`

Это подтверждает успешные операции загрузки и синхронизации. После переключения с локального HTTP на единый HTTPS URL библиотека оставалась доступной.

## 09 / PostgreSQL dump и ZFS snapshots

Штатное создание дампов включено в **Администрирование → Настройки → Резервное копирование базы данных**. Расписание — \`0 2 * * *\`, хранение — 14 копий.

Первый дамп запустили вручную из **Администрирование → Очереди заданий → Создать задачу → Создать резервную копию базы данных**. В логе:

\`\`\`text
Database Backup Starting. Database Version: 18
pg_dump exited (0)
Database Backup Success
\`\`\`

Архив \`*.sql.gz\` появился в \`/mnt/data/immich/data/backups\`; его размер — около 41 MiB. Проверка:

\`\`\`bash
find /mnt/data/immich/data/backups \
  -maxdepth 1 -name '*.sql.gz' \
  -printf '%TY-%Tm-%Td %TH:%TM %10s %f\n'

gzip -t /mnt/data/immich/data/backups/immich-db-backup-*.sql.gz
\`\`\`

Последняя команда годится, когда файл один; при нескольких архивах используйте цикл \`for\`. Успешный \`gzip -t\` проверяет целостность сжатия, но **не заменяет тест восстановления**.

После завершения логического дампа создан baseline snapshot:

\`\`\`bash
SNAP="baseline-$(date +%Y%m%d-%H%M)"
zfs snapshot -r "data/immich@$SNAP"
zfs list -t snapshot -r data/immich
\`\`\`

Рекурсивно фиксируются \`data/immich\`, \`data/immich/data\`, \`data/immich/pgData\`. Snapshot работающей БД — дополнительная страховка; основой логического восстановления PostgreSQL остаётся дамп.

В интерфейсе **Data Protection → Periodic Snapshot Tasks** создано задание:

| Поле | Значение |
|---|---|
| Dataset | \`data/immich\` |
| Recursive | Yes |
| Naming | \`immich-auto-%Y-%m-%d_%H-%M\` |
| Schedule | ежедневно, 03:30 (Europe/Moscow) |
| Lifetime | 30 **DAY**, не MONTH |
| Allow Taking Empty Snapshots | Yes |

Первое выполнение было запланировано на следующий день после настройки. Его успех ещё предстояло проверить. Снимок в 03:30 сам по себе не гарантирует, что дамп в 02:00 действительно завершился: необходим отдельный контроль свежести backup.

## 10 / Диагностика Machine Learning

При первичной индексации встречались \`AssetDetectFaces\`, \`fetch failed\` и \`write EPIPE\`. Однако проверка не выявила ни OOM, ни рестартов контейнеров:

\`\`\`bash
docker stats --no-stream \
  ix-immich-server-1 \
  ix-immich-machine-learning-1 \
  ix-immich-pgvecto-1 \
  ix-immich-redis-1

docker inspect ix-immich-machine-learning-1 \
  --format 'RestartCount={{.RestartCount}} OOMKilled={{.State.OOMKilled}}'

docker logs --since 30m ix-immich-machine-learning-1
\`\`\`

Лог ML показывал завершение неактивного worker и запуск нового. По этим данным нельзя доказать первопричину EPIPE или гарантировать, что он не повторится. Пока увеличивать лимиты памяти и отключать распознавание лиц не потребовалось.

## 11 / Ограничения, безопасность и восстановление

- Открываем наружу **только HTTPS reverse proxy**; Web UI TrueNAS и порт Immich не публикуем.
- Используем разные сильные пароли и отдельные учётные записи Immich.
- Проверяем фактическое состояние NAT, firewall и правила доступа между proxy и NAS.
- Не включаем в Git внутренние IP, реальную DNS-зону, пароли, private keys и ACME API credentials.
- Для полной копии Immich необходимы **оригиналы медиа + база PostgreSQL**. Дамп не содержит фотографий.
- RAIDZ2 защищает от отказов дисков, snapshots — от ряда логических ошибок; **ни то ни другое не защищает от потери NAS целиком**.
- Отдельный USB-диск и независимая репликация запланированы, но **пока не внедрены**.
- После подключения внешнего носителя нужно проверить восстановление на отдельном тестовом окружении, а не считать наличие файла достаточным доказательством.

## Итог

Immich на TrueNAS SCALE оказался практичной заменой Google Фото для Android. Критичными оказались не установка контейнеров, а правильные \`Host Path\`/UID, TLS через существующий reverse proxy, Split DNS для домашнего Wi-Fi и проверяемое резервирование PostgreSQL вместе с ZFS.

### Документация

- [Immich — установка на TrueNAS](https://docs.immich.app/install/truenas/)
- [Immich — reverse proxy](https://docs.immich.app/administration/reverse-proxy/)
- [Immich — backup and restore](https://docs.immich.app/administration/backup-and-restore/)
- [TrueNAS — Periodic Snapshot Tasks](https://www.truenas.com/docs/scale/)
- [acme.sh](https://github.com/acmesh-official/acme.sh)
