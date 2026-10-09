---
title: "Корреляция Windows DNS и MikroTik IPFIX: домены и объём трафика в Grafana"
description: "Практическая архитектура мониторинга, где Windows AD DNS даёт контекст доменов, MikroTik IPFIX — объём сетевого трафика, Loki хранит события, а Grafana объединяет данные."
category: "Мониторинг и безопасность"
tags: ["windows-dns", "active-directory", "mikrotik", "ipfix", "goflow2", "loki", "prometheus", "grafana", "observability"]
published: 2026-10-09
updated: 2026-10-09
status: current
testedOn: ["Windows Server DNS", "MikroTik RouterOS 7", "GoFlow2", "Loki", "Prometheus", "Grafana"]
featured: true
lang: ru
translationKey: "monitoring/windows-dns-mikrotik-ipfix-traffic-correlation"
---

## Контекст

Обычный сетевой мониторинг хорошо отвечает на вопросы:

- сколько трафика прошло через интерфейс;
- какой VLAN или IP потребляет больше всего полосы;
- когда возник пик нагрузки;
- сколько байт и пакетов было передано.

Но он почти не отвечает на более полезный для эксплуатации вопрос:

> Какие интернет-сервисы и домены создают этот трафик?

DNS-мониторинг решает противоположную задачу. Он показывает, какие доменные имена запрашивают рабочие станции, но сам по себе ничего не говорит о количестве переданных мегабайт или гигабайт.

Поэтому задача была разделена между двумя источниками:

```text
Windows AD DNS
      │
      │ DNS Analytical events
      ▼
     Loki
      │
      ├───────────────────────┐
      │                       │
      ▼                       ▼
   Grafana               correlation
                              ▲
                              │
                            IPFIX
                              │
                         MikroTik
```

DNS используется как семантический источник:

```text
client → domain
```

а IPFIX — как источник сетевой статистики:

```text
client → destination IP → bytes
```

Цель — получить приближённую модель:

```text
client → domain → destination → traffic volume
```

Все внутренние домены, IP-адреса, имена серверов и площадок в статье обезличены.

## Почему недостаточно одного MikroTik

MikroTik хорошо видит сетевые соединения.

Например:

```text
10.20.30.45 → 203.0.113.40
```

и IPFIX может передать:

```text
src_ip
dst_ip
src_port
dst_port
protocol
bytes
packets
```

Но destination IP сам по себе часто мало что говорит администратору. Один адрес CDN или облачного провайдера может обслуживать множество приложений.

GeoIP, ASN и reverse DNS полезны, но не дают исходный hostname, который запросил клиент.

## Почему недостаточно одного DNS

Windows AD DNS может видеть запрос:

```text
10.20.30.45 → www.example.net
```

Это уже намного понятнее, но DNS не знает, сколько данных клиент затем передал этому сервису.

Один DNS lookup может закончиться несколькими килобайтами HTTP-трафика, а другой — несколькими гигабайтами видео.

Поэтому:

```text
DNS ≠ traffic accounting
IPFIX ≠ application identity
```

Вместе эти источники значительно полезнее.

## Архитектура

В пилотной схеме используются:

```text
Windows AD DNS
MikroTik RouterOS
GoFlow2
Fluent Bit / Alloy
Loki
Prometheus
Grafana
```

Логически:

```text
                        ┌─────────────────┐
                        │ Windows AD DNS  │
                        └────────┬────────┘
                                 │
                        DNS Analytical ETW
                                 │
                                 ▼
                         Fluent Bit / Alloy
                                 │
                                 ▼
┌──────────┐    IPFIX     ┌───────────┐
│ MikroTik │─────────────►│ GoFlow2   │
└──────────┘              └─────┬─────┘
                                │
                         classification
                                │
                ┌───────────────┴──────────────┐
                ▼                              ▼
              Loki                         Prometheus
                │                              │
                └──────────────┬───────────────┘
                               ▼
                            Grafana
```

Loki используется для событий с высокой кардинальностью:

```text
client_ip
domain
src_ip
dst_ip
bytes
flow
```

Prometheus остаётся для обычных инфраструктурных метрик.

## Windows DNS как источник телеметрии

На контроллерах домена используется журнал:

```text
Microsoft-Windows-DNSServer/Analytical
```

Из DNS-событий извлекаются:

```text
timestamp
dns_server
client_ip
qname
qtype
rcode
```

Пример нормализованного события:

```json
{
  "client_ip": "10.20.30.45",
  "domain": "www.example.net",
  "qtype": "A",
  "rcode": "NOERROR"
}
```

Поля `client_ip` и `domain` лучше не превращать в Loki labels. Уникальных клиентов и hostname может быть очень много, что быстро увеличивает cardinality.

Высококардинальные значения удобнее оставлять внутри JSON.

## Что уже можно получить из DNS

Без IPFIX можно построить полноценный DNS dashboard:

```text
Total DNS queries
Unique clients
Unique domains
NXDOMAIN
Queries/sec
Top clients
Top domains
Top NXDOMAIN domains
```

Это помогает находить:

- неправильно настроенные приложения;
- большое количество NXDOMAIN;
- необычную DNS-активность;
- шумные рабочие станции;
- периодические обращения к внешним сервисам.

Но DNS показывает количество запросов, а не объём трафика.

## MikroTik IPFIX

Для сетевой статистики используется Traffic Flow/IPFIX:

```text
MikroTik
   │
   │ IPFIX
   ▼
GoFlow2
   │
   ▼
classifier
   │
   ▼
Loki
```

Пример нормализованного flow:

```json
{
  "src_ip": "10.20.30.45",
  "dst_ip": "203.0.113.40",
  "src_port": 52144,
  "dst_port": 443,
  "protocol": "tcp",
  "bytes": 1832451
}
```

Из IPFIX можно считать:

```text
bytes per client
bytes per destination
flows per client
top destinations
estimated bandwidth
```

## Почему потоки нужно классифицировать

Не каждый flow на MikroTik является обычным Internet-трафиком.

В распределённой инфраструктуре могут одновременно существовать:

```text
Internet
Inter-Site
VPN
internal networks
public NAT
infrastructure traffic
```

Поэтому до визуализации полезно классифицировать поток:

```text
Internet candidate
Inter-Site
VPN
Public NAT / unknown client
Internal
```

Если после NAT исходный пользователь уже потерян, лучше показать `unknown client`, чем искусственно приписать трафик неправильному хосту.

## Корреляция DNS и IPFIX

Пусть DNS зафиксировал:

```text
10.20.30.45
www.example.net
10:05:12
```

а IPFIX:

```text
10.20.30.45
→ 203.0.113.40
10:05:13
2.1 MB
```

На этом этапе появляется возможность связать доменный контекст с сетевым flow.

Но простое правило:

```text
www.example.net = 2.1 MB
```

будет слишком грубым.

Для более корректной модели нужен correlation cache:

```text
client_ip
domain
resolved_ip
valid_until
site
```

## Почему корреляция не может быть абсолютно точной

Современный веб использует:

- CDN;
- API;
- object storage;
- analytics;
- authentication endpoints;
- отдельные video/static domains;
- shared IP;
- HTTP/2 и HTTP/3.

Пользователь может открыть:

```text
portal.example.net
```

а основной объём получить с:

```text
cdn.example.net
video.example-cdn.net
static.example.net
```

Поэтому корректнее говорить:

> оценка объёма сетевого трафика, связанного с доменом или сервисом

а не «точный трафик сайта».

## DNS cache

Рабочая станция может один раз запросить:

```text
10:00
www.example.net
```

а затем использовать полученный IP длительное время.

IPFIX продолжит видеть flows, но новых DNS-событий может уже не быть.

Поэтому correlation layer должен учитывать TTL и временное состояние:

```text
client_ip
domain
resolved_ip
valid_until
```

## DoH и DoT

Если браузер использует DNS over HTTPS, корпоративный Windows DNS может вообще не увидеть hostname.

Для системы это выглядит как HTTPS-трафик к публичному resolver.

В корпоративной среде можно либо управлять DoH политиками, либо явно считать такой трафик blind spot.

## DNS proxy на маршрутизаторе

Если клиент использует MikroTik как DNS proxy:

```text
client → MikroTik DNS → AD DNS
```

Windows DNS может видеть источником маршрутизатор, а не конечный клиент.

Тогда теряется client attribution.

Для корректной корреляции нужно понимать DNS-путь в каждой VLAN.

## Несколько площадок

В распределённой сети удалённая площадка может использовать центральные AD DNS:

```text
remote client ──DNS──► central DC
```

но выходить в Internet через собственный gateway:

```text
remote client ──Internet──► remote MikroTik
```

Центральный DNS увидит запрос, но IPFIX центрального gateway соответствующий Internet-flow не увидит.

Поэтому в модель нужно включать:

```text
site
gateway
exporter
```

Иначе отсутствие flow можно ошибочно принять за отсутствие трафика.

## Модель данных

Более реалистичная модель:

```text
site
  │
client
  │
DNS query
  │
domain
  │
destination mapping
  │
IPFIX exporter
  │
flow
  │
bytes
```

`site` становится таким же важным измерением, как `client_ip`.

## Что показывать в Grafana

Dashboard удобно разделить на три блока.

### DNS visibility

```text
DNS requests
Unique clients
Unique domains
NXDOMAIN
Top domains
Top clients
```

### Network traffic

```text
Total Internet traffic
Top clients by bytes
Top destination IP
Top ASN
Traffic by site
Traffic by VLAN
```

### Correlation

```text
Estimated traffic by domain
Estimated traffic by client + domain
Top services by traffic
DNS requests without observed flows
Flows without DNS attribution
```

Последние две панели одновременно показывают качество самой корреляции.

## Не скрывать unknown

Полезно явно иметь категории:

```text
Attributed
Unattributed
Unknown NAT
DoH suspected
DNS cache / no recent lookup
Remote-site flow unavailable
```

Например:

```text
Total Internet traffic:      120 GB
Attributed:                   83 GB
Unattributed:                 24 GB
Unknown NAT:                   8 GB
Remote-site flow unavailable:  5 GB
```

Так dashboard честно показывает качество данных.

## Loki против Prometheus

Хранить каждый hostname как Prometheus label — плохая идея:

```text
dns_queries_total{
  client="10.20.30.45",
  domain="random-host.example.net"
}
```

Это создаёт высокую cardinality.

Практичнее:

```text
Prometheus → infrastructure metrics
Loki       → DNS/IPFIX events
Grafana    → queries, correlation and visualization
```

## Что эта система не является

Она не является:

```text
browser history
DPI
proxy log
EDR telemetry
packet capture
```

Она не знает полный URL:

```text
https://example.net/private/page?id=123
```

В лучшем случае она знает домен:

```text
example.net
```

Это важное отличие и технически, и с точки зрения приватности.

## Практическая ценность

Такая архитектура позволяет отвечать на вопросы:

- почему вырос внешний трафик;
- какой клиент создаёт нагрузку;
- какие сервисы используются чаще всего;
- какие домены связаны с большим объёмом данных;
- какая площадка создаёт трафик;
- есть ли массовый NXDOMAIN;
- какая доля сетевого трафика вообще может быть атрибутирована.

## Следующий этап

DNS и IPFIX pipelines уже могут работать независимо. Следующий логичный слой — correlation service/cache:

```text
DNS event
    │
    ├─ client_ip
    ├─ domain
    ├─ resolved_ip
    └─ timestamp
          │
          ▼
     correlation cache
          │
IPFIX ────┤
          │
          ▼
client + domain + bytes + confidence
```

Для production-варианта отдельно учитываются:

- TTL;
- несколько A/AAAA records;
- CDN;
- NAT;
- IPv6;
- DNS cache;
- DoH;
- site awareness;
- retention;
- cardinality.

## Итог

DNS и IPFIX по отдельности дают только половину картины.

DNS отвечает:

```text
куда обращался клиент
```

IPFIX отвечает:

```text
куда реально шёл трафик и сколько байт было передано
```

Связка Windows AD DNS, MikroTik IPFIX, Loki, Prometheus и Grafana позволяет построить observability-систему, которая показывает не только загрузку канала, но и контекст этой загрузки.

Главное — не выдавать correlation за абсолютную истину. Для современного HTTPS/CDN/DoH окружения показатель `traffic attribution confidence` полезнее, чем попытка любой ценой распределить 100% трафика по доменным именам.
