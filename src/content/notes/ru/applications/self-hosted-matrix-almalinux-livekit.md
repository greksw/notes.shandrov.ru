---
title: "Self-hosted Matrix на AlmaLinux 9: Synapse, Element X и MatrixRTC/LiveKit"
description: "Практический разбор приватного Matrix-сервера с PostgreSQL, nginx, Element X и видеозвонками через LiveKit за NAT и общим TLS-ingress."
category: "Приложения и сервисы"
tags: ["matrix", "synapse", "livekit", "webrtc", "almalinux", "nginx", "postgresql"]
published: 2026-09-23
updated: 2026-09-23
status: current
testedOn: ["AlmaLinux 9.8", "Synapse 1.161.0", "LiveKit 1.13.7", "lk-jwt-service 0.7.0", "Element X 26.09.2"]
featured: true
lang: ru
translationKey: "applications/self-hosted-matrix-almalinux-livekit"
---

Нужно было заменить старый Jabber и получить приватный мессенджер без зависимости от Telegram: с нормальным Android-клиентом, локальными пользователями, E2EE, файлами, push-уведомлениями и рабочими аудио/видеозвонками.

В итоге получилась полностью self-hosted схема на Matrix Synapse с PostgreSQL, Element X и MatrixRTC/LiveKit. Самая интересная часть проекта оказалась не в установке Synapse, а в том, как правильно состыковать Matrix identity, `.well-known`, OpenID, LiveKit, reverse proxy, NAT и split DNS.

Ниже — архитектура, ключевые решения и проблемы, которые пришлось разбирать по ходу внедрения.

## 01 / ЗАДАЧА

Исходные требования были простыми:

- приватный Matrix homeserver;
- идентификаторы пользователей вида `@user:shandrov.ru`;
- регистрация новых пользователей только администратором;
- federation не нужна;
- Android-клиент — Element X;
- шифрованные комнаты;
- отправка файлов;
- push-уведомления;
- аудио- и видеозвонки;
- размещение в домашней инфраструктуре за MikroTik;
- TLS через существующий публичный ingress;
- возможность нормального резервного копирования.

Главный принцип — не открывать наружу лишние сервисы и не строить отдельный публичный frontend для каждого компонента.

## 02 / АРХИТЕКТУРА

Matrix VM работает на AlmaLinux 9.

Основные компоненты:

```text
Matrix VM
├── Synapse
├── PostgreSQL
├── nginx
├── LiveKit
└── lk-jwt-service
```

Снаружи используется общий TLS-ingress:

```text
Internet
   |
   | TCP/443
   v
public IP
   |
   v
srv-prom / nginx
   |
   +--> matrix.shandrov.ru
   |       |
   |       v
   |   srv-matrix-01 nginx
   |       |
   |       v
   |   Synapse :8008
   |
   +--> rtc.shandrov.ru
           |
           v
       srv-matrix-01 nginx
           |
           +--> /livekit/sfu --> LiveKit :7880
           |
           +--> /livekit/jwt --> lk-jwt-service :8080
```

WebRTC media идёт напрямую на LiveKit:

```text
Internet
   |
   +--> TCP/7881
   |
   +--> UDP/7882
           |
           v
      LiveKit SFU
```

Такой вариант позволил не ломать уже существующий HTTPS ingress, на котором одновременно работают Grafana и другие сервисы.

## 03 / MATRIX IDENTITY И SYNAPSE

Ключевой параметр Synapse:

```yaml
server_name: "shandrov.ru"
public_baseurl: "https://matrix.shandrov.ru/"
```

Это принципиальное разделение.

`server_name` задаёт Matrix identity:

```text
@admin:shandrov.ru
@user1:shandrov.ru
@user2:shandrov.ru
```

А `public_baseurl` указывает, где реально находится homeserver.

Synapse слушает только loopback:

```yaml
listeners:
  - port: 8008
    type: http
    tls: false
    bind_addresses:
      - "127.0.0.1"
```

Наружу он напрямую не публикуется.

В качестве БД используется PostgreSQL 16. Для media store выделен отдельный диск, смонтированный в `/srv/matrix-media`.

Саморегистрация отключена:

```yaml
enable_registration: false
allow_guest_access: false
```

Пользователи создаются через консольный `register_new_matrix_user`.

## 04 / USER DIRECTORY ДЛЯ ПРИВАТНОГО HOMESERVER

На маленьком закрытом сервере нет смысла заставлять пользователей вручную вводить полный MXID каждого собеседника.

Поэтому был включён локальный каталог:

```yaml
user_directory:
  enabled: true
  search_all_users: true
  prefer_local_users: true
  exclude_remote_users: true
```

После этого Element X начал нормально находить локальных пользователей.

Это мелочь, но для домашнего или корпоративного private homeserver сильно улучшает usability.

## 05 / TLS INGRESS И SPLIT DNS

Публичный `443/tcp` уже использовался Grafana, поэтому напрямую пробрасывать его на Matrix VM было нельзя.

Решение — общий nginx ingress с SNI:

```text
grafana.shandrov.ru -> Grafana
matrix.shandrov.ru  -> Synapse frontend
rtc.shandrov.ru     -> MatrixRTC / LiveKit
```

Внутри сети эти имена должны разрешаться не в публичный адрес, а прямо в LAN-адрес ingress.

На MikroTik используются split-DNS записи:

```text
grafana.shandrov.ru -> 10.20.30.10
matrix.shandrov.ru  -> 10.20.30.10
rtc.shandrov.ru     -> 10.20.30.10
```

Отсутствие split DNS для одного из имён сразу проявилось характерно: `curl` по локальному адресу работал, а браузер пытался идти через публичный IP и получал timeout.

После добавления локальной DNS-записи и очистки DNS-кэша проблема исчезла.

## 06 / MATRIX DISCOVERY

Так как Matrix ID используют домен `shandrov.ru`, а homeserver находится на `matrix.shandrov.ru`, на основном сайте нужен:

```text
https://shandrov.ru/.well-known/matrix/client
```

Содержимое:

```json
{
  "m.homeserver": {
    "base_url": "https://matrix.shandrov.ru"
  },
  "org.matrix.msc4143.rtc_foci": [
    {
      "type": "livekit",
      "livekit_service_url": "https://rtc.shandrov.ru/livekit/jwt"
    }
  ]
}
```

Основной сайт находится на отдельном VPS и обслуживается Caddy.

Важно: этот endpoint только сообщает клиенту адрес homeserver и RTC authorization service. Matrix-трафик через web-сервер сайта не проксируется.

## 07 / MATRIXRTC И LIVEKIT

Современный Element X использует MatrixRTC. Одного coturn для этого недостаточно.

Для звонков понадобились:

```text
Synapse
   |
   +--> MatrixRTC transport discovery
   |
lk-jwt-service
   |
   +--> проверка Matrix/OpenID
   +--> выдача LiveKit JWT
   |
LiveKit SFU
```

Используемые на момент внедрения версии:

```text
Synapse          1.161.0
LiveKit          1.13.7
lk-jwt-service   0.7.0
```

LiveKit настроен на:

```yaml
port: 7880

rtc:
  tcp_port: 7881
  udp_port: 7882
  use_external_ip: true
  advertise_internal_ip: true
  skip_external_ip_validation: true
```

`7880/tcp` используется только за reverse proxy.

Наружу напрямую опубликованы только WebRTC media:

```text
7881/tcp
7882/udp
```

Для небольшой установки удобно использовать один UDP mux port `7882`, а не большой диапазон UDP-портов.

Дополнительно пришлось увеличить receive buffer:

```text
net.core.rmem_max = 5000000
```

После этого предупреждение LiveKit о слишком маленьком UDP receive buffer исчезло.

## 08 / MATRIXRTC В SYNAPSE

В Synapse включены необходимые experimental features:

```yaml
experimental_features:
  msc3266_enabled: true
  msc4143_enabled: true
  msc4222_enabled: true
  msc4502_enabled: true
  msc4512_enabled: true
```

MatrixRTC transport:

```yaml
matrix_rtc:
  transports:
    - type: livekit
      url: "wss://rtc.shandrov.ru/livekit/sfu"
      livekit_service_url: "https://rtc.shandrov.ru/livekit/jwt"
```

Для OpenID в listener добавлен resource:

```yaml
resources:
  - names:
      - client
      - openid
```

При этом полноценная federation не включалась.

## 09 / APPLICATION SERVICE ДЛЯ LK-JWT-SERVICE

`lk-jwt-service` подключён к Synapse как Application Service.

Критический момент — правильные имена параметров MSC4502/MSC4512:

```yaml
io.element.msc4502.scopes:
  - "urn:matrix:client:io.element.msc4502:rooms:is_joined"

io.element.msc4512.proxy_prefix: "rtc/livekit"
io.element.msc4512.proxy_url: "http://127.0.0.1:8080"
```

До исправления этих полей Synapse загружал Application Service, но в журнале показывал:

```text
proxy_url: None
proxy_prefix: None
scopes: set()
```

После корректной конфигурации:

```text
proxy_url: http://127.0.0.1:8080
proxy_prefix: rtc/livekit
scopes: urn:matrix:client:io.element.msc4502:rooms:is_joined
```

Это хороший пример того, почему одного `systemctl status` недостаточно: сервис был `active`, но функциональная интеграция ещё не работала.

## 10 / ДВЕ ОШИБКИ, КОТОРЫЕ СТОИЛИ БОЛЬШЕ ВСЕГО ВРЕМЕНИ

### MISSING_MATRIX_RTC_TRANSPORT

Первоначально Element X показывал:

```text
MISSING_MATRIX_RTC_TRANSPORT
```

Причина была ожидаемая: homeserver ещё не публиковал MatrixRTC transport.

После настройки `matrix_rtc` Synapse начал возвращать:

```json
{
  "rtc_transports": [
    {
      "type": "livekit",
      "url": "wss://rtc.shandrov.ru/livekit/sfu",
      "livekit_service_url": "https://rtc.shandrov.ru/livekit/jwt"
    }
  ]
}
```

### OPEN_ID_ERROR

После этого ошибка изменилась на:

```text
OPEN_ID_ERROR
```

Element X успешно получал OpenID token от Synapse, но `lk-jwt-service` должен был проверить его через Matrix OpenID userinfo endpoint.

Так как Matrix identity — `shandrov.ru`, сервис сначала искал:

```text
https://shandrov.ru/.well-known/matrix/server
```

А такого endpoint ещё не было.

При отсутствии discovery сервис пытался использовать стандартный federation fallback, что в данной архитектуре не соответствовало реальному адресу Synapse.

Решение:

```text
https://shandrov.ru/.well-known/matrix/server
```

```json
{
  "m.server": "matrix.shandrov.ru:443"
}
```

После этого OpenID userinfo начал корректно возвращать:

```json
{
  "sub": "@admin:shandrov.ru"
}
```

Важно: наличие `matrix/server` не означает, что на homeserver обязательно нужно включать полную federation. В этой схеме Synapse публикует только необходимый OpenID endpoint.

## 11 / ПРОВЕРКА RTC БЕЗ КЛИЕНТА

Перед тестом на телефоне была отдельно проверена серверная цепочка.

Запрос токена через MatrixRTC вернул:

```text
HTTP 200
jwt_received = true
```

`lk-jwt-service` после этого создал LiveKit room и выдал SFU access token.

LiveKit зарегистрировал создание комнаты и успешный webhook.

При реальном звонке в журнале появилась уже полноценная RTC-сессия:

```text
starting RTC session
```

То есть удалось проверить отдельно:

```text
Synapse
  -> Application Service
  -> lk-jwt-service
  -> LiveKit Room API
  -> JWT
  -> WebSocket signaling
  -> WebRTC session
```

И только после этого звонок проверялся через Element X.

## 12 / REDIS: НУЖЕН ЛИ ОН ЗДЕСЬ

В этой установке `lk-jwt-service` сейчас работает без Redis.

Это не просто вопрос кэширования.

Если задать:

```text
LIVEKIT_REDIS_URL
```

`lk-jwt-service` будет сохранять своё рабочее состояние в Redis и сможет восстановить его после рестарта. Без Redis используется in-memory store.

Для одиночной домашней установки это допустимо: сообщения, комнаты Matrix, media-файлы и история звонков от этого не теряются.

Redis имеет смысл добавить, если нужна:

- устойчивость служебного MatrixRTC state к рестартам;
- сохранение delegated delayed leave jobs;
- несколько экземпляров authorization service;
- более серьёзная production/HA-схема.

Для текущего single-node варианта это полезное улучшение, но не обязательная зависимость.

## 13 / БЕЗОПАСНОСТЬ

Основные решения:

- Synapse слушает только `127.0.0.1:8008`;
- `lk-jwt-service` слушает только `127.0.0.1:8080`;
- LiveKit signaling не публикуется напрямую;
- наружу открыты только необходимые WebRTC media ports;
- self-registration отключена;
- federation не используется;
- секреты вынесены в root-only конфигурацию;
- SELinux оставлен enforcing;
- firewall разрешает backend nginx только от TLS ingress;
- `.well-known` содержит только публичные service endpoints и не раскрывает секреты.

## 14 / РЕЗЕРВНОЕ КОПИРОВАНИЕ

Для полного восстановления недостаточно только VM backup.

Нужно сохранять как минимум:

```text
PostgreSQL database
/srv/matrix-media
/etc/synapse/homeserver.yaml
Synapse signing key
Synapse secrets
/etc/matrix-rtc
/etc/livekit
nginx configuration
systemd units
TLS/ACME configuration
.well-known configuration
```

Особенно важен signing key Synapse. Потеря этого файла при восстановлении создаёт гораздо более неприятную проблему, чем потеря обычного конфигурационного файла.

Для текущей установки уже сделан полный backup после того, как сообщения и MatrixRTC были проверены в рабочем состоянии.

## 15 / РЕЗУЛЬТАТ

В итоге получился закрытый self-hosted Matrix:

```text
Matrix ID:        @user:shandrov.ru
Homeserver:       matrix.shandrov.ru
RTC:              rtc.shandrov.ru
Client:           Element X
Database:         PostgreSQL
SFU:              LiveKit
Authorization:    lk-jwt-service
TLS ingress:      nginx
Root discovery:   Caddy
```

Работают:

- локальные пользователи;
- поиск пользователей;
- E2EE-комнаты;
- файлы;
- Android-клиенты;
- push для зарегистрированных pushers;
- аудиозвонки;
- видеозвонки;
- MatrixRTC/LiveKit;
- работа как из LAN, так и через Internet.

Самая полезная часть этого проекта — не сама установка Synapse, а отладка полного service chain.

Когда Matrix, OpenID, LiveKit, DNS и reverse proxy разнесены по разным хостам, ошибка в одном маленьком discovery endpoint может выглядеть как проблема WebRTC, клиента или firewall.

Поэтому рабочий подход здесь тот же, что и в любой инфраструктуре: проверять каждый слой отдельно и только после этого переходить к end-to-end тесту.
