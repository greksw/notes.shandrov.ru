---
title: "WireGuard на MikroTik RouterOS 7: роли ADMIN/VPN-ONLY, IPsec и Hysteria"
description: "Разграничение WireGuard-клиентов по ролям, доступ к IPsec-площадкам и выборочный интернет-маршрут через Hysteria; обезличенный практический кейс."
category: "Сети"
tags: ["mikrotik","routeros","wireguard","ipsec","firewall","nat","hysteria","policy-routing"]
published: 2026-11-08
updated: 2026-11-08
status: lab
testedOn: ["RouterOS 7.24.6"]
featured: false
lang: ru
---

# WireGuard на MikroTik RouterOS 7: две группы доступа и маршрутизация через Hysteria

В этой статье разбираю практический случай: один WireGuard-интерфейс на MikroTik обслуживает одновременно администраторов инфраструктуры и клиентов, которым нужен только выход в интернет. При этом адреса выбранных сервисов должны идти через отдельный Hysteria-шлюз, а административная группа — дополнительно видеть локальные VLAN и удалённые площадки по IPsec.

**Статус на 08.11.2026:** конфигурация импортирована в RouterOS 7.24.6; пользователь подтвердил работоспособность административного доступа. Отдельный тест нового клиента группы VPN-ONLY в собранных журналах не зафиксирован, поэтому её изоляцию следует считать настроенной, но не подтверждённой полноценным негативным тестом.

> Здесь приводятся фрагменты конкретной конфигурации, а не универсальный импортируемый скрипт. Названия интерфейсов, списков, порядок правил, адреса и IPsec-селекторы перед применением необходимо сверять со своим маршрутизатором. Не публикуйте в открытых статьях ключи WireGuard, pre-shared keys и экспорт `/export show-sensitive`.

## Исходная архитектура

> **Публичная версия.** Обозначения SITE-A…SITE-F, имена устройств, интерфейсов и списков, а также вся IPv4-адресация в этой статье — демонстрационные. Они не соответствуют боевой сети. Примеры сохраняют логику решения, но не предназначены для прямого импорта.


- Маршрутизатор SITE-A (центральная площадка): MikroTik с RouterOS 7.24.6.
- WireGuard: `wg1`, адрес шлюза `10.250.50.1/24`, условный порт UDP `51820`.
- Локальные сети: например, `10.50.10.0/24` (управление) и `10.50.20.0/24` (серверы).
- Удалённые площадки: SITE-B, SITE-C, SITE-D, SITE-E и SITE-F, подключённые по site-to-site IPsec.
- Отдельный сервер `vpn-egress-01`: `10.50.10.61`; выборочная маршрутизация в таблицу `to-EGRESS-VPN` ведёт к нему. На сервере работает Hysteria.
- Список направлений для отдельного выхода: `VPN-DESTINATIONS` (статические адреса и динамические адреса, полученные через DNS-правила).

Общий путь обычного интернет-трафика остаётся через основной WAN. Смена маршрута происходит **только для совпадений с `VPN-DESTINATIONS`**.

```text
                      wg1 / 10.250.50.1/24
                                |
             +------------------+------------------+
             |                                     |
      ADMIN: .2-.50                         VPN-ONLY: .51-.100
             |                                     |
    VLAN + S2S IPsec                       нет доступа к VLAN/S2S
             |                                     |
             +------------------+------------------+
                                |
                  dst in VPN-DESTINATIONS ?
                    /             \
                  да               нет
                  |                 |
         to-EGRESS-VPN / Hysteria    обычный WAN
              10.50.10.61
```

## Матрица разрешений

| Возможность | ADMIN (`.2–.50`) | VPN-ONLY (`.51–.100`) |
|---|---|---|
| Доступ к управлению самим роутером | Да, по существующим ACL | Нет, кроме DNS/NTP на `10.250.50.1` |
| Домашние VLAN и инфраструктура | Да | Нет |
| SITE-B, SITE-C, SITE-D | Да, через существующие IPsec-селекторы | Нет |
| SITE-E, SITE-F | Да, с адресной трансляцией | Нет |
| Обычный IPv4-интернет | Через WAN | Через WAN |
| Направления `VPN-DESTINATIONS` | Через Hysteria | Через Hysteria |

Вся логика прав живёт на **шлюзе**, но она не заменяет настройку отдельных WireGuard-пиров. У каждого пира должен быть свой публичный ключ и `allowed-address` вида `/32`. Иначе клиент потенциально может подставить чужой адрес внутри туннеля.

## 1. Разделяем WireGuard по адресам

Создаём два адресных диапазона и общий список выданных адресов. В RouterOS диапазон `10.250.50.2-10.250.50.50` может отображаться непосредственно как диапазон, а пара `.2–.3` будет нормализована в `/31`.

```routeros
/ip firewall address-list
add list=WG-ADMIN address=10.250.50.2-10.250.50.50 comment="WG-ROLE | admins"
add list=WG-VPN-ONLY address=10.250.50.51-10.250.50.100 comment="WG-ROLE | Internet only"
add list=WG-ASSIGNED address=10.250.50.2-10.250.50.100 comment="WG-ROLE | role-assigned clients"
```

Важно одновременно убрать прежние разрешения уровня `10.250.50.0/24` из списков управления. Иначе формально изолированная группа может проходить через старое общее правило:

```routeros
/ip firewall address-list remove [find where list="MGMT_ALLOWED" and address="10.250.50.0/24"]
/ip firewall address-list remove [find where list="ICMP_ALLOWED" and address="10.250.50.0/24"]
/ip firewall address-list add list=MGMT_ALLOWED address=10.250.50.2-10.250.50.50
/ip firewall address-list add list=ICMP_ALLOWED address=10.250.50.2-10.250.50.50
```

Если аналогичные разрешения есть в других address-list, правилах сервисов, FastTrack или interface-list, их нужно проверить отдельно.

## 2. Ограничиваем `input`: DNS разрешён, WinBox — нет

Клиенты VPN-ONLY используют роутер как DNS-сервер. Поэтому UDP/TCP 53 и, если требуется, UDP 123 допускаются **только на адрес WireGuard-интерфейса**. Остальной входящий трафик от этой роли блокируется.

```routeros
/ip firewall filter
add chain=input action=accept in-interface=wg1 \
    src-address-list=WG-VPN-ONLY dst-address=10.250.50.1 \
    protocol=udp dst-port=53,123 comment="WG-ROLE | VPN-ONLY DNS NTP UDP"
add chain=input action=accept in-interface=wg1 \
    src-address-list=WG-VPN-ONLY dst-address=10.250.50.1 \
    protocol=tcp dst-port=53 comment="WG-ROLE | VPN-ONLY DNS TCP"
add chain=input action=drop in-interface=wg1 \
    src-address-list=WG-VPN-ONLY comment="WG-ROLE | VPN-ONLY DROP INPUT"
add chain=input action=drop in-interface=wg1 \
    src-address-list=!WG-ASSIGNED comment="WG-ROLE | UNASSIGNED DROP INPUT"
```

**Порядок принципиален:** в нашей схеме эти правила помещены **перед** общим `established,related`, а не просто добавлены в конец цепочки. В противном случае уже открытые сеансы могут пережить смену роли.

## 3. Ограничиваем `forward`: закрываем внутренние назначения

Для группы VPN-ONLY блокируем маршрутизацию к внутренним адресам, а также входящие соединения из внутренних сетей к этой группе. Используется существующий список `NON_PUBLIC_IPV4`.

```routeros
/ip firewall filter
add chain=forward action=drop in-interface=wg1 \
    src-address-list=WG-VPN-ONLY \
    dst-address-list=NON_PUBLIC_IPV4 \
    comment="WG-ROLE | VPN-ONLY DROP PRIVATE EGRESS"
add chain=forward action=drop \
    src-address-list=NON_PUBLIC_IPV4 \
    dst-address-list=WG-VPN-ONLY \
    comment="WG-ROLE | VPN-ONLY DROP PRIVATE INGRESS"
add chain=forward action=drop in-interface=wg1 \
    src-address-list=!WG-ASSIGNED \
    comment="WG-ROLE | UNASSIGNED DROP FORWARD"
```

Эти фильтры должны стоять **до** общих разрешений LAN→WAN и S2S, а также до приоритетного accept для `established,related`, если необходимо немедленно пресечь уже существующие соединения.

Проверьте состав `NON_PUBLIC_IPV4`: помимо применяемых RFC1918-подсетей нужно учесть остальные реально используемые внутренние адреса, транзитные сети, CGNAT-диапазоны при необходимости и локальные маршруты. Пустой или неполный список превращает защиту в иллюзию.

## 4. ADMIN и IPsec-площадки: где нужен SNAT

В конфигурации SITE-A обнаружились две группы IPsec-площадок:

1. **SITE-B, SITE-C, SITE-D.** В условной схеме существуют политики с источником `10.250.50.0/24`. Трафик ADMIN идёт напрямую, адрес клиента виден на удалённом узле.
2. **SITE-E и SITE-F.** В условной схеме существующие политики рассчитаны на источник `10.50.10.0/24`. Чтобы не изменять обе стороны IPsec, трафик ADMIN к этим площадкам преобразуется в `10.50.10.1` до применения IPsec-политик.

Для демонстрации SNAT к SITE-E используются `10.63.10.0/24`, `10.63.77.0/24`; к SITE-F — `10.64.122.0/24`–`10.64.125.0/24`. Это условные сети, выбранные для иллюстрации селекторов.

```routeros
/ip firewall address-list
add list=WG-S2S-SNAT address=10.63.10.0/24
add list=WG-S2S-SNAT address=10.63.77.0/24
add list=WG-S2S-SNAT address=10.64.122.0/24
add list=WG-S2S-SNAT address=10.64.123.0/24
add list=WG-S2S-SNAT address=10.64.124.0/24
add list=WG-S2S-SNAT address=10.64.125.0/24

/ip firewall nat add chain=srcnat action=src-nat \
    in-interface=wg1 src-address-list=WG-ADMIN \
    dst-address-list=WG-S2S-SNAT \
    to-addresses=10.50.10.1 \
    comment="WG-ROLE | ADMIN SNAT TO SITE-E SITE-F"
```

В действующей конфигурации соответствующий `forward accept` добавлен перед общими IPsec-правилами. NAT-правило помещено перед широким WAN masquerade. Не следует добавлять SNAT для трёх площадок, где полные селекторы WireGuard уже присутствуют: это ухудшает трассировку действий администраторов.

Проверка нужна с **двух сторон**: `established` для IKE не означает, что установлены все нужные Child SA, а firewall/ACL удалённой площадки может блокировать конкретный сервис.

## 5. Выборочный Hysteria через `to-EGRESS-VPN`

Список `VPN-DESTINATIONS` объединяет статические сети и записи, пополняемые DNS-разрешением имён (`type=FWD`, `address-list`). В нём присутствуют направления для Telegram, WhatsApp, Instagram/Meta, OpenAI и других сервисов. Перечень зависит от текущего содержимого списка; статическая выгрузка не гарантирует полный набор IP для каждого сервиса.

Для новых TCP/UDP-соединений из `VPN-SOURCES` маршрут маркируется как `to-EGRESS-VPN`. В эту группу входит WireGuard-подсеть `10.250.50.0/24`.

```routeros
/ip firewall mangle print stats where comment~"VPN-CA"
/ip route print detail where routing-table=to-EGRESS-VPN
/ip firewall address-list print where list=VPN-DESTINATIONS
```

Для направлений в `NON_PUBLIC_IPV4` перед правилами Hysteria добавлен `mangle action=accept`: это предотвращает ошибочную отправку трафика к VLAN и S2S в VPN-шлюз.

На `forward` используется защита от прямого выхода на WAN для пакетов WireGuard, направленных к `VPN-DESTINATIONS`. Это ограничивает утечку при отказе PBR, но **не заменяет** отдельный fail-closed на самом Hysteria-шлюзе. Дополнительно нужно учесть DNS-подмену, DoH/Private DNS и IPv6: текущая схема управляет IPv4.

## 6. Профиль WireGuard-клиента

Для новой машины из VPN-ONLY выдаётся отдельный peer с адресом `10.250.50.51/32` и отдельным ключом. Пример клиентского профиля:

```ini
[Interface]
Address = 10.250.50.51/32
DNS = 10.250.50.1
PrivateKey = <CLIENT_PRIVATE_KEY>

[Peer]
PublicKey = <ROUTER_PUBLIC_KEY>
Endpoint = <VPN_ENDPOINT>:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
```

`AllowedIPs = 0.0.0.0/0` делает клиентский туннель полным по IPv4, а **на MikroTik** по PBR выбирается только тот трафик, который должен идти через Hysteria. Обычный интернет остаётся через WAN центральной площадки. На самом MikroTik соответствующему peer необходимо назначить строго `allowed-address=10.250.50.51/32`.

## 7. Эксплуатационные проверки

После импорта основной скрипт вывел `PRECHECK OK` и `IMPORT COMPLETE`. Новые адресные списки, правила `input`, `forward`, `mangle`, `srcnat` появились; пять IPsec-пиров находились в состоянии `established`. Пользователь позже подтвердил, что настроенный административный доступ работает.

Минимальный контроль на роутере:

```routeros
/interface wireguard peers print detail
/ip firewall address-list print where list~"WG-ROLE"
/ip firewall filter print stats where comment~"WG-ROLE"
/ip firewall nat print stats where comment~"WG-ROLE"
/ip firewall mangle print stats where comment~"VPN-CA"
/ip ipsec active-peers print
/ip ipsec installed-sa print
```

Обязательные тесты с настоящих клиентов: ADMIN должен открывать инфраструктуру и удалённые площадки; VPN-ONLY должен получать DNS и выходить в интернет, **но не** подключаться к роутеру по WinBox, внутренним VLAN и удалённым сетям. Важно проверить не только успешные соединения, но и ожидаемые отказы.

## Практический итог

Один интерфейс WireGuard может предоставлять разные уровни доступа без создания отдельных туннелей. Критичны четыре вещи: привязка peer к уникальному `/32`, корректный порядок firewall-правил, учёт реальных IPsec-селекторов и независимая проверка fail-closed маршрутизации. Именно их сочетание отделяет технически работающую схему от схемы, которая лишь выглядит безопасной.
