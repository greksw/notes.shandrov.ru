---
title: "MikroTik: GRE поверх IPsec и выборочная маршрутизация через Hysteria"
description: "Обезличенный пилот GRE/IPsec между площадками: маркировка маршрутов, двойной SNAT, fail-closed и проверка транспорта."
category: "Сети"
tags: ["mikrotik","routeros","gre","ipsec","hysteria","nat","pbr","multi-wan"]
published: 2026-11-08
updated: 2026-11-08
status: lab
testedOn: ["RouterOS 7.24.6"]
featured: false
lang: ru
---

# GRE поверх IPsec между MikroTik: вывод отдельных ресурсов филиала через Hysteria другой площадки

Задача: офисная сеть уже использует два интернет-провайдера и несколько site-to-site IPsec-туннелей. Нужно отправлять только трафик к выбранным интернет-сервисам через другую площадку (SITE-A), где работает Hysteria-шлюз, но **не** переключать весь интернет офиса, не затрагивать локальные сети и не ломать существующие правила для другого VPN-канала.

Ниже — реальная последовательность настройки пилотного соединения SITE-B ↔ SITE-A на MikroTik RouterOS 7.24.6. В отличие от готовых лабораторных инструкций, здесь явно отделены успешно подтверждённые этапы от тех, которые ещё требуют проверки.

**Статус на 08.11.2026:** оба GRE-интерфейса `RUNNING`, проверка ICMP в обе стороны успешна (5/5, потери 0%). Таблица PBR на SITE-B активна. Однако в момент последнего измерения все счётчики пилотных mangle/NAT на SITE-B и SITE-A были равны нулю. Поэтому прохождение *пользовательских* соединений через Hysteria пока **не подтверждено**.

> Приведённые RouterOS-команды — фрагменты из внедрённой схемы. Некоторые строки зависят от уже существующих `interface-list`, адресных списков, NAT-исключений и порядка `filter/mangle`. Не импортируйте их вслепую в другую сеть.

## 1. Топология и ограничения

> **Публичная версия.** SITE-A/SITE-B, интерфейсы, маршруты, комментарии и все IP-адреса заменены на демонстрационные. Адреса из RFC1918 служат лишь иллюстрацией и не являются действующей схемой инфраструктуры. Команды требуют адаптации перед выполнением.


```text
              SITE-B (office, Multi-WAN)
              MikroTik router-site-b
              IPsec endpoint: 10.60.10.1
              GRE: 10.255.250.1/30
                         |
           GRE, защищённый существующим IPsec
                         |
              MikroTik router-site-a
              IPsec endpoint: 10.50.10.1
              GRE: 10.255.250.2/30
                         |
                  table: to-EGRESS-VPN
                         |
              Hysteria gateway: 10.50.10.61
                         |
                   Интернет
```

GRE создаётся поверх **уже действующего IPsec**, который разрешает обмен между `10.60.10.0/24` и `10.50.10.0/24`. Сам по себе GRE **не обеспечивает шифрование**: защиту даёт IPsec, а firewall принимает GRE от удалённого endpoint только при `ipsec-policy=in,ipsec`.

На SITE-B уже работали другой VPN-шлюз/MWAN-правила и список интернет-направлений `OFFICE-VPN-DESTINATIONS`. На SITE-A имеется Hysteria-шлюз в `10.50.10.0/24`, таблица `to-EGRESS-VPN` и другой GRE-туннель до SITE-C. Задача — добавить отдельный контур, не затронув имеющиеся.

## 2. GRE: интерфейсы и адреса

На SITE-B:

```routeros
/interface gre add name=gre-site-b-to-a \
    local-address=10.60.10.1 remote-address=10.50.10.1 \
    mtu=1300 keepalive=10s,3 allow-fast-path=no
/ip address add address=10.255.250.1/30 interface=gre-site-b-to-a
```

На SITE-A:

```routeros
/interface gre add name=gre-site-b-to-a \
    local-address=10.50.10.1 remote-address=10.60.10.1 \
    mtu=1300 keepalive=10s,3 allow-fast-path=no
/ip address add address=10.255.250.2/30 interface=gre-site-b-to-a
```

Использованы `mtu=1300` и `clamp-tcp-mss=yes` (последний параметр отображается в состоянии интерфейса). Эти значения удобны как стартовая конфигурация, но для другого WAN/IPsec их нужно подтвердить тестом MTU, включая пакеты без фрагментации.

Пример правила, допускающего **только зашифрованный** GRE на SITE-A (аналогичное зеркальное правило настроено на SITE-B):

```routeros
/ip firewall filter add chain=input action=accept \
    src-address=10.60.10.1 dst-address=10.50.10.1 \
    protocol=gre ipsec-policy=in,ipsec \
    comment="SITE-B-TO-A | encrypted GRE inbound"
```

Оно должно стоять до финального `input drop`. Отдельно разрешён ICMP только на транзитных адресах `10.255.250.1` и `.2` из GRE-интерфейса, что облегчает мониторинг.

## 3. Выборочная маршрутизация на SITE-B

Создана отдельная FIB-таблица `to-SITE-A` с маршрутом через GRE и резервным blackhole, который должен предотвращать переход на основной WAN при отказе GRE.

```routeros
/routing table add fib name=to-SITE-A
/ip route add dst-address=0.0.0.0/0 \
    gateway=10.255.250.2@main routing-table=to-SITE-A \
    check-gateway=ping distance=1 \
    comment="SITE-B-TO-A | GRE selected default"
/ip route add blackhole dst-address=0.0.0.0/0 \
    routing-table=to-SITE-A distance=250 \
    comment="SITE-B-TO-A | GRE fail-closed blackhole"
```

Для тестирования выделен `SITE-B-PILOT-SRC`. В него включили `10.60.10.3` и два адреса из сети управления `10.60.99.2–.3`:

```routeros
/ip firewall address-list add list=SITE-B-PILOT-SRC \
    address=10.60.10.3 comment="SITE-B-TO-A | test office host"
/ip firewall address-list add list=SITE-B-PILOT-SRC \
    address=10.60.99.2-10.60.99.3 \
    comment="SITE-B-TO-A | test admin hosts"
```

RouterOS отображает последнюю пару как `10.60.99.2/31` — это **нормально**: диапазон точно охватывает `.2` и `.3`.

При новом подключении к IP из `OFFICE-VPN-DESTINATIONS` у выбранного источника выставляется `connection-mark=cm-site-b-to-a`, после чего применяется `routing-mark=to-SITE-A`.

```routeros
/ip firewall mangle add chain=prerouting action=mark-connection \
    in-interface-list=LAN src-address-list=SITE-B-PILOT-SRC \
    dst-address-list=OFFICE-VPN-DESTINATIONS dst-address-type=!local \
    connection-state=new connection-mark=no-mark \
    new-connection-mark=cm-site-b-to-a passthrough=yes \
    comment="SITE-B-TO-A | PILOT mark selected connections"

/ip firewall mangle add chain=prerouting action=mark-routing \
    in-interface-list=LAN src-address-list=SITE-B-PILOT-SRC \
    dst-address-list=OFFICE-VPN-DESTINATIONS dst-address-type=!local \
    connection-mark=cm-site-b-to-a new-routing-mark=to-SITE-A \
    passthrough=no \
    comment="SITE-B-TO-A | PILOT route selected via GRE"
```

**Важнее самих команд — их место в таблице.** Оба правила установлены *перед* старым `LEGACY-VPN | mark selected destinations` для альтернативного VPN-шлюза. Это не даёт существующей схеме перехватить новые пилотные соединения. Отдельные правила старых специальных сервисов (например, Spamhaus, ClamAV, Ubiquiti) не меняли.

## 4. NAT на двух участках

Обычным интернет-сервисам не нужно знать внутреннюю адресацию филиала. В пилоте предусмотрено два этапа SNAT:

**SITE-B:** выбранный пакет при выходе в GRE получает источник `10.255.250.1`. Это позволяет SITE-A принимать трафик от одного явно разрешённого транзитного адреса.

```routeros
/ip firewall nat add chain=srcnat action=src-nat \
    connection-mark=cm-site-b-to-a \
    src-address-list=SITE-B-PILOT-SRC \
    dst-address-list=OFFICE-VPN-DESTINATIONS out-interface=gre-site-b-to-a \
    to-addresses=10.255.250.1 \
    comment="SITE-B-TO-A | PILOT SNAT to GRE"
```

**SITE-A:** при пересылке этого пакета к локальному Hysteria gateway источник заменяется на `10.50.10.1`. Отдельный маршрут возврата до сети GRE на шлюзе при такой схеме не нужен, но состояние NAT на MikroTik остаётся критически важным.

```routeros
/ip firewall nat add chain=srcnat action=src-nat \
    in-interface=gre-site-b-to-a out-interface=vlan-mgmt \
    src-address=10.255.250.1 dst-address-list=!NON_PUBLIC_IPV4 \
    to-addresses=10.50.10.1 \
    comment="SITE-B-TO-A | SNAT to Hysteria gateway"
```

Порядок NAT-исключений для IPsec и `masquerade` нельзя переносить из другой конфигурации без анализа. В рабочем скрипте правила поставлены перед конкретными существующими якорями по `comment`, а не добавлены произвольно в конец списка.

## 5. Принудительно запрещаем обход Hysteria

На SITE-B для соединений `cm-site-b-to-a` добавлен `forward drop`, если маршрут всё-таки ведёт в обычный WAN; отдельный `forward accept` разрешает нужным источникам выход в `gre-site-b-to-a`.

На SITE-A аналогичный принцип: пакеты, пришедшие из GRE, **не должны** уходить в частные сети или напрямую в WAN. Вместо этого они маркируются в `to-EGRESS-VPN` и допускаются к Hysteria gateway через `vlan-mgmt`.

Фрагмент mangle SITE-A:

```routeros
/ip firewall mangle add chain=prerouting action=mark-routing \
    in-interface=gre-site-b-to-a src-address=10.255.250.1 \
    dst-address-list=!NON_PUBLIC_IPV4 dst-address-type=!local \
    new-routing-mark=to-EGRESS-VPN passthrough=no \
    comment="SITE-B-TO-A | route GRE via Hysteria"
```

Это **двухуровневое ограничение**. Первый уровень защищает от обхода GRE на стороне офиса, второй — от выхода GRE-трафика прямо через WAN домашнего маршрутизатора. Но если сам шлюз Hysteria начнёт пересылать интернет-пакеты вне туннеля, защита на MikroTik этого не заметит. Поэтому на шлюзе необходим независимый kill-switch.

## 6. Что подтвердили измерения

После импорта скриптов обе стороны показали `PRECHECK OK`. GRE-интерфейсы находились в состоянии `RUNNING` с `actual-mtu=1300`; маршрут по таблице `to-SITE-A` был активен, с `immediate-gw=10.255.250.2%gre-site-b-to-a`.

| Проверка | Результат |
|---|---|
| Ping SITE-B → `10.255.250.2` | 5/5, потери 0%, средний RTT **5,720 мс** |
| Ping SITE-A → `10.255.250.1` | 5/5, потери 0%, средний RTT **6,809 мс** |
| GRE interface status | `RUNNING` на обеих сторонах |
| `to-SITE-A` | default через GRE — `ACTIVE`; blackhole distance 250 присутствует |
| SITE-B `cm-site-b-to-a` | **0 соединений** на момент проверки |
| SITE-B и SITE-A mangle/NAT `SITE-B-TO-A` | **0 пакетов** на момент проверки |

Следовательно, транспортная часть подтверждена, а весь прикладной маршрут `клиент → GRE → SITE-A → Hysteria → интернет` пока **не считается проверенным**.

## 7. План проверки пилота

На тестовой машине (`10.60.10.3`, `10.60.99.2` или `.3`) создать **новое** соединение к направлению из `OFFICE-VPN-DESTINATIONS` (например, открыть Telegram Web или Instagram). Использовать DNS, который заполняет нужные адресные списки; внешний DoH может обойти локальную DNS-классификацию. Не следует делать выводы только по `ping` с самого MikroTik, так как это не тот же путь `prerouting`, что у клиентского трафика.

Проверка на SITE-B:

```routeros
/ip firewall address-list print where list=SITE-B-PILOT-SRC
/ip firewall mangle print stats where comment~"SITE-B-TO-A"
/ip firewall filter print stats where comment~"SITE-B-TO-A"
/ip firewall nat print stats where comment~"SITE-B-TO-A"
/ip firewall connection print count-only where connection-mark=cm-site-b-to-a
/ip route print detail where routing-table=to-SITE-A
```

На SITE-A:

```routeros
/ip firewall mangle print stats where comment~"SITE-B-TO-A"
/ip firewall filter print stats where comment~"SITE-B-TO-A"
/ip firewall nat print stats where comment~"SITE-B-TO-A"
/ip route print detail where routing-table=to-EGRESS-VPN
/ip ipsec installed-sa print
```

Если счётчики SITE-B не растут, первым делом проверить IP-адрес тестового клиента, использование DNS, фактическое заполнение `OFFICE-VPN-DESTINATIONS`, порядок mangle и то, не используются ли старые записи connection tracking. Если на SITE-B счётчики увеличиваются, а на SITE-A остаются нулевыми, проверять `gre-site-b-to-a`, NAT на SITE-B и `torch/sniffer` на GRE с обеих сторон. Если SITE-A видит трафик, но сайты не открываются, изучить таблицу `to-EGRESS-VPN`, ответный путь и сам Hysteria gateway.

Для проверки fail-closed отдельно имитировать недоступность GRE и Hysteria в запланированное окно. Убедиться, что выбранный трафик **не** начинает выходить напрямую через WAN. Тесты выполнять с осторожностью: они могут прервать текущие соединения пилотных клиентов.

## 8. Как безопасно расширять охват

В проекте подготовлен отдельный, **пока не применённый** этап расширения: вместо `SITE-B-PILOT-SRC` использовать уже существующий `OFFICE-VPN-SOURCES` во всех четырёх пилотных правилах (два mangle, forward allow, srcnat). Он не предназначен для автоматического перевода абсолютно всех офисных VLAN.

Не расширяйте охват, пока не подтверждены одновременно: попадание пакетов в списки, инкремент счётчиков mangle/NAT с обеих сторон, доступность выбранных сервисов, отсутствие обхода Hysteria и сохранность обычного офисного трафика. Отдельно проверьте, что списки адресов SITE-B и SITE-A согласованы; в исходных снимках они **не идентичны**.

Для быстрого отключения только пилотной маршрутизации на SITE-B (без удаления GRE и IPsec) можно выключить пилотные правила по комментариям:

```routeros
/ip firewall mangle disable [find where comment="SITE-B-TO-A | PILOT mark selected connections"]
/ip firewall mangle disable [find where comment="SITE-B-TO-A | PILOT route selected via GRE"]
/ip firewall filter disable [find where comment="SITE-B-TO-A | PILOT allow LAN to GRE"]
/ip firewall nat disable [find where comment="SITE-B-TO-A | PILOT SNAT to GRE"]
```

Это возврат к прежнему **выбору маршрута для новых соединений**, но не универсальный откат текущих conntrack-состояний: для окончательного восстановления ранее помеченные подключения иногда нужно переподключить.

## Вывод

GRE поверх уже действующего IPsec позволяет построить понятный транзитный контур между площадками, не затрагивая default route офиса. Для устойчивой эксплуатации ключевы: отдельная PBR-таблица, пилотный address-list, аккуратная приоритетность mangle относительно старого VPN, согласованный NAT и независимый fail-closed. В описанном случае межплощадочный транспорт успешно проверен; окончательное подтверждение Hysteria-выхода требует клиентского теста и ненулевых счётчиков.
