---
title: "VPN-CA: эксплуатация и диагностика selective gateway"
description: "Runbook для эксплуатации MikroTik + sing-box + NaiveProxy + Hysteria2: проверки, rp_filter, DNS redirect, tcpdump, conntrack, обновления и rollback на резервный VPN."
category: "Сети"
tags: ["operations", "troubleshooting", "mikrotik", "sing-box", "hysteria2", "naiveproxy"]
published: 2026-09-29
updated: 2026-09-29
status: current
testedOn: ["RouterOS 7.23.5", "AlmaLinux 10.2", "sing-box 1.14.2", "Hysteria2 2.12.3"]
featured: false
lang: ru
translationKey: "networking/vpn-ca-operations-troubleshooting"
---

[← Обзор мини-проекта](/ru/notes/networking/vpn-ca-project-overview/)

## Что контролировать регулярно

На MikroTik:

    /ip route print detail where routing-table=to-VPN-EDGE

    /ip firewall mangle print stats     where comment~"VPN-EDGE"

Маршрут должен быть active, а счётчики SELECTED DST должны расти при обращении к нужным сервисам.

На Linux gateway:

    systemctl is-active sing-box
    ip -br addr show tun0

    sysctl       net.ipv4.conf.default.rp_filter       net.ipv4.conf.ens18.rp_filter       net.ipv4.conf.tun0.rp_filter

Ожидается:

    default = 0
    ens18   = 1
    tun0    = 0

На edge:

    systemctl is-active caddy
    systemctl is-active hysteria-server

    ss -lntp | grep ':443'
    ss -lunp | grep ':443'

TCP/443 должен обслуживать Caddy, UDP/443 — Hysteria2.

## Как доказать маршрут

Не стоит определять путь только по тому, что сайт открылся.

Для TCP удобен egress check:

    curl -4 -sS https://api.ipify.org

Для UDP — OpenDNS:

    dig +short @208.67.222.222 myip.opendns.com A

На full-tunnel тестовом host оба должны показать IP edge.

Для production selective routing обычный сайт должен показывать IP основного WAN, а selected traffic проверяется по mangle counters и sing-box logs.

## Логи sing-box

Полезный live view:

    journalctl -u sing-box -f

TCP через TUN выглядит как:

    inbound/tun[tun-in]: inbound redirect connection from 192.168.50.x
    outbound/naive[naive-out]: outbound connection to ...

UDP:

    inbound/tun[tun-in]: inbound packet connection from 192.168.50.x
    outbound/hysteria2[hy2-out]: outbound packet connection to ...

Это позволяет быстро понять, какой outbound реально выбран.

## Проблема: packet отмечен на MikroTik, но Linux его не видит

Сначала исключить NAT redirect и firewall.

На MikroTik полезны:

    /ip firewall mangle print stats
    /ip firewall nat print detail without-paging
    /ip firewall filter print stats

Особенно опасен принудительный DNS redirect. Пакет может получить routing-mark в prerouting mangle, а затем быть превращён в локальный DNS request самого MikroTik.

На Linux:

    tcpdump -eni ens18 -nn       'host 192.168.50.100'

Если MikroTik видит egress, а ens18 нет — искать L2/VLAN. Если packet не выходит из MikroTik — искать RouterOS policy.

## Проблема: UDP дошёл до edge и вернулся в tun0, но клиент timeout

Это характерный симптом rp_filter.

Диагностический capture:

    tcpdump -lni any -nn       '((host 8.8.8.8 and udp port 53) or (host 203.0.113.10 and udp port 443))'

Плохая картина:

    ens18 In  client -> 8.8.8.8:53
    tun0 Out  client -> 8.8.8.8:53
    ens18 Out gateway -> edge:443
    ens18 In  edge:443 -> gateway
    tun0 In   8.8.8.8:53 -> client

и после tun0 In ничего нет.

Проверяем:

    sysctl net.ipv4.conf.tun0.rp_filter

Если там 1, для этой topology это ломает обратный асимметричный route.

После исправления обязательно проверить, что значение сохраняется после:

    systemctl restart sing-box

## Почему default.rp_filter тоже важен

Недостаточно один раз выполнить:

    sysctl -w net.ipv4.conf.tun0.rp_filter=0

После restart sing-box интерфейс tun0 создаётся заново.

Поэтому policy должна включать:

    net.ipv4.conf.default.rp_filter = 0

а физический интерфейс можно оставить strict:

    net.ipv4.conf.ens18.rp_filter = 1

## Проблема: Hysteria2 неясно работает или нет

Сначала отделить Hysteria2 от TUN.

Если отдельный minimal sing-box config умеет переслать UDP DNS через Hysteria2, значит:

- client implementation работает;
- TLS/SNI/auth/obfs работают;
- edge Hysteria2 работает;
- UDP relay edge работает.

Тогда оставшаяся проблема находится в TUN, NFQUEUE, Linux forwarding или обратном route.

Это намного эффективнее, чем одновременно менять server и client configs.

## Одновременный capture двух концов

Local gateway:

    tcpdump -lni any -nn       '((host 8.8.8.8 and udp port 53) or (host 203.0.113.10 and udp port 443))'

Edge:

    tcpdump -lni eth0 -nn       '((udp port 443) or (host 8.8.8.8 and udp port 53))'

Рабочая цепочка:

    client -> tun0
    gateway -> edge UDP/443
    edge -> DNS UDP/53
    DNS -> edge
    edge -> gateway UDP/443
    tun0 -> client

Если видны все точки, transport исправен.

## Старые соединения после изменения policy

RouterOS connection tracking может удерживать connection-mark старого VPN.

Проверка конкретного клиента:

    /ip firewall connection print detail     where src-address~"192.168.50.141"     and connection-mark=old-vpn-mark

Удалять лучше только его старые сессии:

    /ip firewall connection remove     [find where src-address~"192.168.50.141"     and connection-mark=old-vpn-mark]

Не нужно сбрасывать весь conntrack роутера.

## Резервный VPN и rollback

Старый VPN остаётся настроенным, но его classification rule выключено.

Аварийный rollback:

1. отключить два правила VPN-EDGE SELECTED DST;
2. включить старое правило marking SELECTED-DST;
3. удалить старые VPN-EDGE conntrack sessions только у проблемных клиентов;
4. проверить внешний маршрут.

Так rollback занимает минуты и не требует пересборки IPsec или другого резервного VPN.

## Обновление компонентов

Рекомендуемый порядок:

1. сохранить текущие configs;
2. проверить свободное место и systemd status;
3. обновить edge Hysteria2;
4. проверить UDP transport отдельно;
5. обновить Caddy/Naive;
6. проверить TCP;
7. обновить sing-box;
8. выполнить sing-box check;
9. restart;
10. проверить tun0 и rp_filter;
11. провести TCP и UDP end-to-end tests.

Не обновлять сразу все три компонента без промежуточной проверки.

## Что резервировать

Local gateway:

    /etc/sing-box/
    /etc/sysctl.d/99-vpngw-routing.conf
    firewalld configuration

Edge:

    Caddyfile
    Hysteria2 config
    systemd unit overrides
    секреты отдельно от публичной документации

MikroTik:

    /export show-sensitive=no

Экспорт без секретов подходит для документации, но не заменяет защищённый backup RouterOS.

## Минимальный аварийный checklist

Если selected site перестал работать:

1. active ли route to-VPN-EDGE;
2. доступен ли Linux gateway;
3. active ли sing-box;
4. существует ли tun0;
5. tun0.rp_filter равен 0;
6. растёт ли SELECTED DST counter;
7. есть ли naive-out или hy2-out в journal;
8. есть ли TCP/UDP 443 до edge;
9. отвечает ли edge;
10. при необходимости выполнить rollback на standby VPN.

## Вывод

Главный урок проекта — диагностировать маршрут по слоям.

Не начинать с изменения proxy config, если ещё не доказано, что packet дошёл до proxy. И наоборот, не менять MikroTik, если capture уже показывает нормальную отправку и возврат через edge.

Именно последовательная проверка MikroTik -> ens18 -> tun0 -> outbound -> edge -> Internet -> обратно позволяет быстро найти реальную точку потери.

### Серия

- [Обзор](/ru/notes/networking/vpn-ca-project-overview/)
- [Edge](/ru/notes/networking/vpn-ca-edge-naive-hysteria2/)
- [Local gateway](/ru/notes/networking/vpn-ca-local-gateway-sing-box-mikrotik/)
