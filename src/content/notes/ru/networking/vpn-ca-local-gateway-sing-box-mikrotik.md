---
title: "VPN-CA: локальный sing-box TUN и MikroTik policy routing"
description: "Настройка локального Linux gateway с sing-box: TUN, Naive outbound для TCP, Hysteria2 для UDP и выборочная маршрутизация MikroTik RouterOS 7."
category: "Сети"
tags: ["sing-box", "mikrotik", "routeros", "tun", "policy-routing", "naiveproxy", "hysteria2"]
published: 2026-09-29
updated: 2026-09-29
status: current
testedOn: ["RouterOS 7.23.5", "AlmaLinux 10.2", "sing-box 1.14.2"]
featured: false
lang: ru
translationKey: "networking/vpn-ca-local-gateway-sing-box-mikrotik"
---

[← Обзор мини-проекта](/ru/notes/networking/vpn-ca-project-overview/)

## Роль локального gateway

Linux VM находится в той же локальной сети, что и MikroTik:

    MikroTik        192.168.50.1
    Linux gateway   192.168.50.61

MikroTik отправляет на gateway только выбранные назначения. Linux не решает, какие сайты нужно перенаправлять: он получает уже классифицированный трафик и выбирает транспорт по L4 protocol.

    TCP -> NaiveProxy
    UDP -> Hysteria2

## Системная подготовка

Включаем IPv4 forwarding:

    cat > /etc/sysctl.d/90-vpngw-forwarding.conf <<'EOF'
    net.ipv4.ip_forward = 1
    EOF

    sysctl --system

Проверка:

    sysctl net.ipv4.ip_forward

## reverse path filtering

Для policy-routed TUN strict rp_filter на tun0 мешает обратному асимметричному трафику.

Рабочая политика проекта:

    net.ipv4.conf.all.rp_filter = 0
    net.ipv4.conf.default.rp_filter = 0
    net.ipv4.conf.ens18.rp_filter = 1
    net.ipv4.conf.tun0.rp_filter = 0

Файл:

    cat > /etc/sysctl.d/99-vpngw-routing.conf <<'EOF'
    net.ipv4.conf.all.rp_filter = 0
    net.ipv4.conf.default.rp_filter = 0
    net.ipv4.conf.ens18.rp_filter = 1
    net.ipv4.conf.tun0.rp_filter = 0
    EOF

    sysctl --system

Почему нужен default=0: tun0 создаётся sing-box динамически и должен сразу получить правильное значение после restart.

## TUN inbound

Упрощённый inbound sing-box:

    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "tun0",
      "address": ["172.31.255.1/30"],
      "mtu": 1500,
      "auto_route": true,
      "auto_redirect": true,
      "strict_route": false,
      "dns_mode": "disabled",
      "include_interface": ["ens18"],
      "exclude_uid": [<SING_BOX_UID>],
      "route_exclude_address": [
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "169.254.0.0/16",
        "224.0.0.0/4",
        "203.0.113.10/32"
      ]
    }

В конкретной топологии strict_route=true приводил к self-interception и timeout. Рабочим оказался strict_route=false вместе с exclude_uid процесса sing-box.

Edge IP обязательно исключается из TUN, иначе outbound может попытаться попасть обратно в самого себя.

## TCP outbound: Naive

    {
      "type": "naive",
      "tag": "naive-out",
      "server": "203.0.113.10",
      "server_port": 443,
      "username": "<USER>",
      "password": "<PASSWORD>",
      "insecure_concurrency": 0,
      "tls": {
        "enabled": true,
        "server_name": "edge.example.net"
      }
    }

В проекте используется literal IPv4 edge и отдельный TLS server_name. Это исключает нежелательный выбор недоступного IPv6 для самого edge.

## UDP outbound: Hysteria2

    {
      "type": "hysteria2",
      "tag": "hy2-out",
      "server": "203.0.113.10",
      "server_port": 443,
      "obfs": {
        "type": "salamander",
        "password": "<OBFS_PASSWORD>"
      },
      "password": "<HY2_PASSWORD>",
      "network": "udp",
      "tls": {
        "enabled": true,
        "server_name": "edge.example.net"
      }
    }

Routing внутри sing-box:

    {
      "rules": [
        {
          "network": "udp",
          "action": "route",
          "outbound": "hy2-out"
        }
      ],
      "final": "naive-out",
      "default_interface": "ens18"
    }

Получается простая модель: весь UDP, который уже пришёл в TUN, идёт через Hysteria2; TCP — через Naive.

## Проверка конфигурации

Перед restart:

    sing-box check -c /etc/sing-box/config.json

После restart:

    systemctl restart sing-box
    systemctl is-active sing-box
    ip -br addr show tun0

Критично повторно проверить rp_filter после пересоздания TUN:

    sysctl       net.ipv4.conf.default.rp_filter       net.ipv4.conf.ens18.rp_filter       net.ipv4.conf.tun0.rp_filter

## firewalld

В проекте tun0 помещён в отдельную zone, а forwarding между физическим интерфейсом и TUN разрешён policy.

Смысл конфигурации:

    ens18 -> public
    tun0  -> vpngw-tun

    public -> vpngw-tun  ACCEPT
    vpngw-tun -> public  ACCEPT

NAT на Linux gateway для TUN не требуется: sing-box сам завершает proxy connections.

## MikroTik routing table

На RouterOS создаётся отдельная FIB table:

    /routing/table
    add name=to-VPN-EDGE fib

Маршрут:

    /ip/route
    add dst-address=0.0.0.0/0         routing-table=to-VPN-EDGE         gateway=192.168.50.61@main         distance=1         comment="VPN-EDGE | default via Linux gateway"

Main table не меняется.

## Selected destination routing

Предположим:

    CLIENTS      -> клиенты, для которых разрешён selective gateway
    SELECTED-DST -> адреса сервисов, которым нужен обходной путь

Правила:

    /ip/firewall/mangle
    add chain=prerouting action=mark-routing         new-routing-mark=to-VPN-EDGE passthrough=no         protocol=udp         src-address-list=CLIENTS         dst-address-list=SELECTED-DST         connection-mark=no-mark         comment="VPN-EDGE | SELECTED DST | UDP"

    add chain=prerouting action=mark-routing         new-routing-mark=to-VPN-EDGE passthrough=no         protocol=tcp         src-address-list=CLIENTS         dst-address-list=SELECTED-DST         connection-mark=no-mark         comment="VPN-EDGE | SELECTED DST | TCP"

Всё, что не входит в SELECTED-DST, остаётся в main routing.

## Отдельный full-tunnel test host

Для диагностики удобно временно иметь один лабораторный host, весь внешний TCP/UDP которого уходит через gateway.

Для него можно использовать отдельный source list и два mangle rule с условием dst-address-list=!LOCAL_NETS.

Такой тест позволяет проверить Naive и Hysteria2 независимо от наполнения SELECTED-DST.

После валидации full-tunnel test rules лучше не использовать как production policy.

## DNS redirect на MikroTik

Если MikroTik принудительно перенаправляет клиентский DNS на себя:

    chain=dstnat action=redirect protocol=udp         in-interface-list=LAN_VLANS dst-port=53

то full-tunnel тест через внешний DNS может не дойти до Linux gateway.

Для лабораторного source list нужен bypass перед redirect.

Для production selected-destination схемы redirect обычно можно оставить: MikroTik продолжает резолвить домены и наполнять destination address-list.

## Старый VPN как standby

Старый VPN лучше не удалять. Достаточно отключить старое правило marking selected destination, чтобы оно не конкурировало с новой policy.

При аварии VPN-EDGE правила можно быстро переключить обратно.

## Проверка

TCP egress:

    curl -4 -sS --max-time 15 https://api.ipify.org

UDP egress через тестовый full-tunnel host:

    dig +time=10 +tries=1 +short       @208.67.222.222 myip.opendns.com A

Оба теста должны показать egress IP edge.

Для production selected routing внешний IP обычного сайта должен остаться IP основного WAN.

## Дальше

Эксплуатация, поиск неисправностей и rollback: [VPN-CA operations](/ru/notes/networking/vpn-ca-operations-troubleshooting/).

### Ссылки

- [sing-box TUN](https://sing-box.sagernet.org/configuration/inbound/tun/)
- [sing-box Naive outbound](https://sing-box.sagernet.org/configuration/outbound/naive/)
- [sing-box Hysteria2 outbound](https://sing-box.sagernet.org/configuration/outbound/hysteria2/)
