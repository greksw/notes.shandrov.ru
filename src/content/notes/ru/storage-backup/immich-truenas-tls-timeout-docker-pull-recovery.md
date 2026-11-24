---
title: "Immich на TrueNAS SCALE не запускается после обновления: TLS handshake timeout и восстановление Docker Pull"
description: "Реальный инцидент при обновлении Immich: STOPPED без контейнеров, TLS handshake timeout при Docker Pull, диагностика GHCR/CDN, выборочная маршрутизация через Hysteria2 и последовательная загрузка шести образов."
category: "Хранение и резервное копирование"
tags: ["immich", "truenas", "truenas-scale", "docker", "ghcr", "tls", "hysteria2", "mikrotik", "routeros", "zfs", "troubleshooting"]
published: 2026-11-24
updated: 2026-11-24
status: current
testedOn: ["TrueNAS SCALE 25.10.x", "Immich 3.4.2", "TrueNAS Apps 1.14.74", "PostgreSQL 18 / VectorChord 1.1.1", "MikroTik RouterOS 7", "Hysteria2"]
featured: false
lang: ru
translationKey: "storage-backup/immich-truenas-tls-timeout-docker-pull-recovery"
---

## Контекст и результат

24 ноября 2026 года после обновления приложения Immich на TrueNAS SCALE до версии каталога **1.14.74** сервис перестал запускаться. В интерфейсе фиксировались неудачные задания `app.upgrade` и `app.start`; состояние оставалось `STOPPED`, контейнеры приложения отсутствовали.

**Подтверждённая проблема:** TrueNAS не мог завершить скачивание Docker-образов: журнал содержал `TLS handshake timeout`, `connection reset by peer` и `download failed after attempts=6`. После последовательной предварительной загрузки всех шести образов приложение штатно запустилось. Проверены четыре здоровых основных контейнера, успешное завершение двух служебных контейнеров и API HTTP 200.

**Важное ограничение вывода:** точная причина сетевых TLS-тайм-аутов не была окончательно установлена. Одновременно изменились два фактора — маршрут к одному CDN и режим загрузки образов (последовательный вместо параллельного). Поэтому нельзя доказательно приписать успех исключительно VPN или только последовательной загрузке.

Имена узлов, приватные IP-адреса и внешний домен в статье заменены условными. Все публичные CDN-IP ниже приведены как исторический результат DNS на дату инцидента, **не** как постоянный список для маршрутизации.

## 01 / Как выглядел сбой

После обновления TrueNAS сообщил о неудачных операциях, а проверка middleware и Docker показала:

~~~bash
midclt call app.query |
  jq '.[] | select(.name=="immich") | {name,state,version}'

docker ps -a --filter name=ix-immich   --format 'table {{.Names}}	{{.Status}}'
~~~

Фактический результат:

~~~text
{
  "name": "immich",
  "state": "STOPPED",
  "version": "1.14.74"
}

NAMES     STATUS
~~~

Отсутствие контейнеров принципиально: проблема возникала **до** старта PostgreSQL, а не внутри уже работающей базы или Immich Server. Повторное нажатие `Start` без диагностики лишь воспроизводило ошибку.

В `/var/log/app_lifecycle.log` обнаружены:

~~~text
TLS handshake timeout
connection reset by peer
download failed after attempts=6
pgvecto Error
redis Error
~~~

`pgvecto` и `redis` здесь — имена сервисов Compose. **Это не означает**, что их образы обязательно загружаются из Docker Hub: фактически все шесть образов данной версии были опубликованы в GHCR.

Для публичного отчёта не нужно копировать полный lifecycle-журнал: в нём могут быть чувствительные значения. Следующий пример выводит только время и категории известных сетевых ошибок:

~~~bash
python3 - <<'PY'
from pathlib import Path
import re

p = Path("/var/log/app_lifecycle.log")
patterns = {
    "TLS_TIMEOUT": "TLS handshake timeout",
    "CONNECTION_RESET": "connection reset by peer",
    "DOWNLOAD_FAILED": "download failed after attempts=",
}

if not p.is_file():
    raise SystemExit("Lifecycle log not found")

for line in p.read_text(errors="replace").splitlines()[-1000:]:
    if "immich" not in line.lower():
        continue
    flags = [key for key, needle in patterns.items()
             if needle.lower() in line.lower()]
    if flags:
        stamp = re.search(r"\[\d{4}/\d{2}/\d{2}[^\]]*\]", line)
        print((stamp.group(0) if stamp else "NO_TIMESTAMP"),
              ",".join(flags))
PY
~~~

## 02 / Проверка реестров: проблема не везде одинаковая

На NAS отдельно проверили четыре HTTPS-адреса. `401` от `ghcr.io/v2/` и `registry-1.docker.io/v2/` — нормальный ответ реестра без авторизации; `400` или `404` от проверочного пути на CDN/Auth также сами по себе не означают недоступность TLS.

~~~bash
for HOST in   ghcr.io   pkg-containers.githubusercontent.com   registry-1.docker.io   auth.docker.io
do
    echo "===== $HOST ====="
    curl -4 -sS --connect-timeout 10 --max-time 20       -o /dev/null       -w 'HTTP=%{http_code} TCP=%{time_connect}s TLS=%{time_appconnect}s TOTAL=%{time_total}s\n'       "https://$HOST/v2/"
    echo "EXIT=$?"
done
~~~

Результаты одного сравнительного теста:

| Адрес | Прямой WAN | Через Hysteria2 |
|---|---|---|
| `ghcr.io` | TLS 0,09 с; HTTP 401 | TLS 7,36 с; HTTP 401 |
| `pkg-containers.githubusercontent.com` | `SSL connection timeout` | TLS около 7,00 с; HTTP 400 |
| `registry-1.docker.io` | TLS 0,27 с; HTTP 401 | TLS 7,15 с; HTTP 401 |
| `auth.docker.io` | TLS 0,09 с; HTTP 404 | TLS 7,05 с; HTTP 404 |

Вывод: **гнать весь HTTPS-трафик NAS через Hysteria2 было нерационально** — большинство проверенных реестров отвечали напрямую значительно быстрее. При этом конкретный GitHub CDN через прямой WAN не завершал TLS-соединение, а через VPN отвечал стабильно, хотя и медленно.

Семисекундное TLS-рукопожатие само по себе не объясняет первопричину. MTU, потери пакетов и особенности VPN-пути в этом расследовании отдельно не доказаны.

## 03 / Временная выборочная маршрутизация CDN

На MikroTik RouterOS v7 уже существовали рабочие VPN-шлюз и отдельная таблица маршрутизации. Для аварийной загрузки временно направили **только TCP/443 от NAS к выбранным IP CDN** через Hysteria2, оставив `ghcr.io` и остальные реестры на прямом WAN.

Условные параметры примера:

~~~text
NAS:                192.168.10.10
MikroTik interface: vlan10
VPN routing table:  to-VPN
~~~

Предварительно убедитесь, что FIB-таблица `to-VPN` имеет рабочий маршрут через VPN-шлюз. Команды ниже **не создают VPN**.

В конкретном инциденте DNS вернул четыре адреса `pkg-containers.githubusercontent.com`. Мы внесли их в адресный список с коротким сроком жизни:

~~~routeros
/ip firewall address-list add list=IMMICH-CDN-TEMP address=185.199.108.154 timeout=4h comment="Immich recovery"
/ip firewall address-list add list=IMMICH-CDN-TEMP address=185.199.109.154 timeout=4h comment="Immich recovery"
/ip firewall address-list add list=IMMICH-CDN-TEMP address=185.199.110.154 timeout=4h comment="Immich recovery"
/ip firewall address-list add list=IMMICH-CDN-TEMP address=185.199.111.154 timeout=4h comment="Immich recovery"

/ip firewall mangle add chain=prerouting in-interface=vlan10 src-address=192.168.10.10 protocol=tcp dst-port=443 dst-address-list=IMMICH-CDN-TEMP action=mark-routing new-routing-mark=to-VPN passthrough=no place-before=0 comment="IMMICH CDN TEMP via VPN"
~~~

**Не копируйте эти IP вслепую.** CDN-адреса могут меняться; общие IP способны обслуживать несколько доменов. Перед применением сверяйте актуальные DNS-ответы, таблицу маршрутизации и влияние на другие сервисы. Срок `4h` создаёт риск переключения маршрута во время передачи, если адресная запись истечёт. Это аварийный приём, не готовое постоянное решение.

В рассматриваемой конфигурации имелись пересекающиеся правила DNS FWD для `githubusercontent.com`, поэтому автоматическое наполнение отдельного address-list не было надёжно подтверждено. Не стоит считать более конкретную запись гарантированно выбранной при пересечениях.

Проверка временного правила:

~~~routeros
/ip firewall mangle print detail where comment="IMMICH CDN TEMP via VPN"
/ip firewall mangle print stats where comment="IMMICH CDN TEMP via VPN"
~~~

Счётчик увеличивался; три последовательных HTTPS-запроса к CDN завершились HTTP 400 без ошибок curl, TLS около 6,9–7,0 с. Это подтверждает доступность тестового HTTPS endpoint и попадание пакетов под mangle, **но не факт полной загрузки Docker-слоя**.

Вопрос «можно ли обращаться к реестру и CDN через разные страны?» решается на уровне соединений: Docker может открывать отдельные TCP/TLS-сессии к API, авторизации и хранилищу blob. Обычно это допустимо, если каждое соединение сохраняет свой маршрут. Но привязка URL к IP, политика CDN или смена внешнего IP посреди соединения могут нарушить загрузку.

## 04 / Узнаём точный список образов из TrueNAS Chart

Не следует угадывать версии PostgreSQL и Valkey по именам сервисов из ошибки. TrueNAS сохраняет отрендеренную конфигурацию Compose для установленных ревизий приложения.

~~~bash
COMPOSE=$(
  find /mnt/.ix-apps/app_configs/immich/versions     -type f -path '*/templates/rendered/docker-compose.yaml'     2>/dev/null | sort -V | tail -1
)

test -n "$COMPOSE" || {
  echo "Rendered compose not found"
  exit 1
}

echo "Compose: $COMPOSE"
docker compose -f "$COMPOSE" config --images | sort -u
~~~

В версии каталога `1.14.74` получили шесть образов, все из `ghcr.io`:

| Компонент | Образ и версия |
|---|---|
| Immich Server | `immich-app/immich-server:v3.4.2` |
| Machine Learning | `immich-app/immich-machine-learning:v3.4.2` |
| PostgreSQL / VectorChord | `immich-app/postgres:18-vectorchord1.1.1` |
| Valkey | `valkey-io/valkey:9.2.0` |
| TrueNAS Container Utils | `truenas/containers/container-utils:1.1.2` |
| PostgreSQL Upgrade | `truenas/containers/postgres-upgrade:1.3.0` |

Реальные записи Compose содержали также закреплённые digest `@sha256:…` — важно сохранить их при загрузке, а не заменять на произвольный `latest`.

## 05 / Последовательная предварительная загрузка

Сначала вручную успешно скачали Valkey и PostgreSQL/VectorChord, которые ранее фигурировали в ошибках. Затем проверили оставшиеся четыре образа: два уже находились локально, ещё два были загружены. **Все шесть точных digest были доступны до запуска приложения.**

Воспроизводимый вариант для текущей установленной версии:

~~~bash
bash <<'BASH'
set -Eeuo pipefail

COMPOSE=$(
  find /mnt/.ix-apps/app_configs/immich/versions     -type f -path '*/templates/rendered/docker-compose.yaml'     2>/dev/null | sort -V | tail -1
)

test -n "$COMPOSE"

while IFS= read -r IMAGE; do
    test -n "$IMAGE" || continue
    echo "===== $IMAGE ====="

    if docker image inspect "$IMAGE" >/dev/null 2>&1; then
        echo "ALREADY PRESENT"
    else
        docker pull "$IMAGE"
    fi

    docker image inspect "$IMAGE"       --format 'VERIFIED: {{.Id}}'
done < <(docker compose -f "$COMPOSE" config --images | sort -u)

echo "ALL REQUIRED IMAGES VERIFIED"
BASH
~~~

Здесь `docker pull` скачивает образы в локальное хранилище Docker, но **не запускает PostgreSQL, не мигрирует схему и не изменяет фотобиблиотеку**. Скрипт останавливается на первой ошибке, позволяя диагностировать конкретный образ. Для этой версии последовательная загрузка оказалась успешной.

Не используйте `docker system prune` или удаление app datasets как способ исправить TLS timeout.

## 06 / Снимок ZFS и штатный запуск

Перед повторным запуском, пока приложение оставалось остановленным, создали рекурсивный ZFS snapshot:

~~~bash
SNAP="pre-immich-start-$(date +%Y%m%d-%H%M)"
zfs snapshot -r "data/immich@$SNAP"

zfs list -t snapshot -r data/immich   -o name,creation | grep -F "@$SNAP"
~~~

Проверены snapshots родительского dataset, медиатеки `data/immich/data` и базы `data/immich/pgData` (3/3). Снимок при остановленной БД удобен как контрольная точка, но остаётся **локальным snapshot, не независимой резервной копией**. Откат PostgreSQL после миграций требует отдельного плана совместимости; не выполняйте `zfs rollback` автоматически.

После этого выполнили **TrueNAS → Apps → Immich → Start**, без ручного запуска Compose. Итог:

~~~text
App state:                     RUNNING
TrueNAS App version:           1.14.74
Immich Server:                 healthy
PostgreSQL / VectorChord:      healthy
Machine Learning:              healthy
Valkey:                        healthy
Postgres upgrade job:          Exited (0)
Permissions job:               Exited (0)
~~~

`Exited (0)` у двух одноразовых служебных контейнеров — нормальное успешное завершение; их не нужно удерживать в состоянии `Up`.

Контрольные команды:

~~~bash
midclt call app.query |
  jq '.[] | select(.name=="immich") | {name,state,version}'

docker ps -a --filter name=ix-immich   --format 'table {{.Names}}	{{.Status}}'

curl -fsS --max-time 15   http://127.0.0.1:30041/api/server/version

curl -fsS --max-time 15   http://127.0.0.1:30041/api/server/ping
~~~

API подтвердил **Immich 3.4.2**; запрос `/api/server/ping` вернул `{"res":"pong"}` и **HTTP 200**. Последующая проверка логов не выявила явных ошибок запуска. При этом отдельный тест просмотра старых и новых фотографий в браузере в приведённых диагностических данных не зафиксирован: HTTP 200 не доказывает целостность всей медиатеки.

По завершении аварийное правило CDN было отключено:

~~~routeros
/ip firewall mangle disable [find where comment="IMMICH CDN TEMP via VPN"]
~~~

Список временных адресов был создан с `timeout=4h` и должен автоматически истечь. На реальном маршрутизаторе правило может иметь другое имя — используйте фактический comment.

## 07 / Что улучшить перед следующим обновлением

1. **Pre-pull до обновления:** заранее получить точные `image@sha256` из будущей версии chart и скачать образы последовательно, пока рабочий Immich ещё запущен. При этом учитывайте, что TrueNAS может не иметь отрендеренного Compose следующей версии до начала обновления; в таком случае сначала получите и проверьте манифест образов другим корректным способом, а не подставляйте `latest`.
2. **Разделить сетевую и прикладную диагностику:** отдельно проверять прямой WAN, VPN, TLS и реальные Docker Pull; один `curl` не доказывает работоспособность доставки blob.
3. **Не оставлять широкий PBR:** выборочные правила должны быть проверяемыми, с понятным rollback; временные IP и DNS-совпадения не заменяют постоянной корректной схемы маршрутизации.
4. **Проверять данные, а не только контейнеры:** после запуска открыть старые фотографии, загрузить новый объект, проверить базу и задания резервирования.
5. **Сохранять точки восстановления:** логический дамп PostgreSQL, ZFS snapshots и отдельная копия за пределами исходного NAS решают разные задачи.

## Итог

В этом инциденте Immich был недоступен **из-за незавершённой загрузки Docker-образов**, а не из-за подтверждённого повреждения PostgreSQL или фотографий. Проверка TLS по отдельным endpoint показала узкое место на GitHub CDN; временная PBR-маршрутизация обеспечила доступ к нему. Последовательная загрузка шести образов по закреплённым digest устранила блокирующий этап. TrueNAS смог штатно поднять приложение, четыре основных контейнера стали `healthy`, API вернул HTTP 200.

**Урок:** при `STOPPED` без контейнеров сначала анализируйте lifecycle-журнал и Docker Pull, а не удаляйте приложение и не откатывайте ZFS.

### Связанные материалы

- [Immich на TrueNAS SCALE: собственное Google Фото, Android, HTTPS и ZFS](/ru/notes/storage-backup/immich-truenas-scale-android-zfs-https/)
- [Immich — установка на TrueNAS](https://docs.immich.app/install/truenas/)
- [Immich — backup and restore](https://docs.immich.app/administration/backup-and-restore/)
- [TrueNAS SCALE Apps](https://www.truenas.com/docs/scale/)
- [Docker image pull](https://docs.docker.com/reference/cli/docker/image/pull/)
