---
title: "VPN-CA: выборочный gateway для TCP/UDP через MikroTik, sing-box, NaiveProxy и Hysteria2"
description: "Обзор мини-проекта: MikroTik отправляет только выбранные назначения на локальный sing-box gateway, TCP идёт через NaiveProxy, UDP через Hysteria2, а обычный Internet остаётся на основном WAN."
category: "Сети"
tags: ["mikrotik", "routeros", "sing-box", "naiveproxy", "hysteria2", "policy-routing", "anti-dpi"]
published: 2026-09-29
updated: 2026-09-29
status: current
testedOn: ["RouterOS 7.23.5", "AlmaLinux 10.2", "sing-box 1.14.2", "Hysteria2 2.12.3", "Caddy 2.11.4"]
featured: true
lang: ru
translationKey: "networking/vpn-ca-project-overview"
---

## О проекте

Задача проекта — не строить full-tunnel VPN для всей сети, а выборочно отправлять только проблемные или заблокированные назначения через отдельный внешний edge.

Обычный трафик продолжает использовать основной WAN. Это снижает задержку, уменьшает зависимость от VPS и сохраняет привычную схему Multi-WAN.

Публичные адреса, домены, логины и секреты в серии заменены примерами.

## Архитектура

    LAN / Wi-Fi clients
            |
            v
        MikroTik
            |
            +-- destination in SELECTED-DST --------------------+
            |                                                    |
            |                                              Linux gateway
            |                                              192.168.50.61
            |                                                 /      \
            |                                            TCP /        \ UDP
            |                                               v          v
            |                                         NaiveProxy   Hysteria2
            |                                          TCP/443      UDP/443
            |                                               \          /
            |                                                v        v
            |                                             CA edge VPS
            |                                           203.0.113.10
            |
            +-- everything else --> main routing --> normal WAN

MikroTik отвечает только за классификацию и policy routing. Linux gateway принимает выбранный трафик через TUN и разделяет его по протоколу:

- TCP — NaiveProxy поверх HTTPS/HTTP2 на TCP/443;
- UDP — Hysteria2 на UDP/443;
- внешний VPS предоставляет единый egress IP.

## Почему не full tunnel

Full tunnel проще концептуально, но для домашней или офисной сети у него есть эксплуатационные минусы:

- весь трафик зависит от VPS;
- растёт RTT даже для доступных локально сервисов;
- увеличивается нагрузка на edge;
- сложнее совместить решение с существующим Multi-WAN;
- авария внешнего gateway влияет на весь Internet.

В этом проекте маршрут получает только трафик к SELECTED-DST. Всё остальное остаётся в main table.

## Почему два транспорта

TCP и UDP намеренно разделены.

NaiveProxy хорошо подходит для TCP-потоков и выглядит как обычный HTTPS/HTTP2 traffic на TCP/443.

Hysteria2 сохраняет настоящий UDP, поэтому QUIC, HTTP/3 и приложения с UDP не приходится принудительно переводить на TCP.

На edge:

    TCP/443 -> Caddy + Naive forward proxy
    UDP/443 -> Hysteria2

Для этого HTTP/3 в Caddy отключён, иначе Caddy также попытается занять UDP/443.

## Policy routing на MikroTik

Основная production-логика выглядит так:

    /routing/table
    add name=to-VPN-EDGE fib

    /ip/route
    add dst-address=0.0.0.0/0         routing-table=to-VPN-EDGE         gateway=192.168.50.61@main         distance=1

Выбранные назначения маркируются отдельно для UDP и TCP:

    /ip/firewall/mangle
    add chain=prerouting action=mark-routing         new-routing-mark=to-VPN-EDGE passthrough=no         protocol=udp         src-address-list=CLIENTS         dst-address-list=SELECTED-DST         connection-mark=no-mark         comment="VPN-EDGE | SELECTED DST | UDP"

    add chain=prerouting action=mark-routing         new-routing-mark=to-VPN-EDGE passthrough=no         protocol=tcp         src-address-list=CLIENTS         dst-address-list=SELECTED-DST         connection-mark=no-mark         comment="VPN-EDGE | SELECTED DST | TCP"

Остальной трафик не получает routing-mark.

## Что оказалось критичным

Наиболее сложными оказались не сами прокси-протоколы, а интеграционные детали.

Первая — DNS redirect на MikroTik. Если тестировать UDP через запрос к 8.8.8.8:53, существующее redirect-правило может перехватить пакет уже после mangle, поэтому на Linux gateway он не появится.

Вторая — reverse path filtering. На динамическом tun0 strict rp_filter отбрасывал уже вернувшийся через Hysteria2 ответ. Рабочая схема:

    all     = 0
    default = 0
    ens18   = 1
    tun0    = 0

Третья — старые conntrack-сессии. После переключения policy старые соединения могут продолжать использовать предыдущий VPN, пока их не завершить или не удалить выборочно.

## Резервный VPN

Старый VPN не удаляется. Его правило классификации остаётся отключённым и используется как standby.

Rollback сводится к обратному переключению mangle:

1. отключить VPN-EDGE SELECTED DST;
2. включить старое правило marking выбранных destination;
3. при необходимости очистить conntrack только для затронутого клиента.

## Состав мини-проекта

1. [Архитектура и edge: Caddy, NaiveProxy и Hysteria2](/ru/notes/networking/vpn-ca-edge-naive-hysteria2/)
2. [Локальный gateway: sing-box TUN и MikroTik policy routing](/ru/notes/networking/vpn-ca-local-gateway-sing-box-mikrotik/)
3. [Эксплуатация и диагностика: rp_filter, DNS redirect, conntrack и rollback](/ru/notes/networking/vpn-ca-operations-troubleshooting/)

## Итог

Получилась схема, в которой обходной маршрут является не новым default gateway, а отдельным сервисом policy routing:

    selected destinations
        -> MikroTik
        -> local sing-box gateway
        -> TCP: NaiveProxy
        -> UDP: Hysteria2
        -> external edge

    all other traffic
        -> main routing
        -> normal ISP uplink

Такой вариант проще эксплуатировать рядом с Multi-WAN и позволяет сохранять резервный VPN без одновременной работы двух механизмов классификации.
