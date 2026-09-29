---
title: "VPN-CA: edge на Caddy + NaiveProxy + Hysteria2"
description: "Развёртывание внешнего edge для выборочного gateway: Caddy и NaiveProxy на TCP/443, Hysteria2 на UDP/443, TLS, firewall и контрольные проверки."
category: "Сети"
tags: ["caddy", "naiveproxy", "hysteria2", "almalinux", "tls", "proxy"]
published: 2026-09-29
updated: 2026-09-29
status: current
testedOn: ["AlmaLinux 10.2", "Caddy 2.11.4", "Hysteria2 2.12.3"]
featured: false
lang: ru
translationKey: "networking/vpn-ca-edge-naive-hysteria2"
---

[← Обзор мини-проекта](/ru/notes/networking/vpn-ca-project-overview/)

## Роль edge

Внешний VPS завершает оба транспортных протокола и даёт единый egress IP:

    Internet clients
          |
          | TCP/443
          v
       Caddy
    forward_proxy
          |
          +--> Internet

    local gateway
          |
          | UDP/443
          v
      Hysteria2
          |
          +--> Internet

В примерах используется:

    edge.example.net
    203.0.113.10

Реальные адреса, логины и секреты публиковать не нужно.

## Базовые требования

Для VPS достаточно небольших ресурсов, если через него проходит только selected traffic:

- 1–2 vCPU;
- 1–2 GB RAM;
- публичный IPv4;
- AlmaLinux 10 или другой современный Linux;
- TCP/443 и UDP/443 снаружи;
- корректная DNS A-запись для TLS.

Перед настройкой полезно убедиться, что IPv4 routing обычного VPS работает независимо от прокси.

    ip -4 addr
    ip route
    curl -4 https://api.ipify.org

## Caddy и Naive forward proxy

Используется Caddy с модулем forward_proxy. На TCP/443 он одновременно даёт нормальный HTTPS front и Naive-compatible forward proxy.

Ключевой момент — отключить HTTP/3, чтобы UDP/443 остался свободным для Hysteria2.

Упрощённый глобальный блок:

    {
        order forward_proxy before file_server

        servers {
            protocols h1 h2
        }
    }

Пример site block:

    edge.example.net {
        forward_proxy {
            basic_auth USER PASSWORD
            hide_ip
            hide_via
            probe_resistance
        }

        root * /var/www/edge
        file_server
    }

Front полезен не только как маскировка. Он позволяет обычным браузером проверить TLS, SNI и HTTP/2 независимо от proxy CONNECT.

## Проверка TCP front

После запуска Caddy:

    curl -sSI --http2 https://edge.example.net/

Ожидается обычный HTTP response без ошибок сертификата.

Проверяем сокет:

    ss -lntp | grep ':443'

TCP/443 должен принадлежать Caddy.

## Hysteria2 на UDP/443

Hysteria2 использует тот же hostname и TLS identity, но слушает UDP/443.

Упрощённая конфигурация:

    listen: :443

    tls:
      cert: /path/to/fullchain.pem
      key: /path/to/privkey.pem
      sniGuard: strict

    obfs:
      type: salamander
      salamander:
        password: CHANGE_ME

    auth:
      type: password
      password: CHANGE_ME

    udpIdleTimeout: 60s

Секреты лучше держать вне статьи и вне shell history.

Если сертификаты выдаёт Caddy, Hysteria2 должен иметь только необходимые права чтения. Не нужно делать каталоги сертификатов world-readable.

## systemd

Сервис Hysteria2 должен стартовать автоматически и перезапускаться при сбое.

Минимальные эксплуатационные проверки:

    systemctl is-enabled hysteria-server
    systemctl is-active hysteria-server
    journalctl -u hysteria-server -n 50 --no-pager

Название unit может отличаться в зависимости от способа установки.

## Firewall

На edge нужны оба 443:

    firewall-cmd --permanent --add-service=https
    firewall-cmd --permanent --add-port=443/udp
    firewall-cmd --reload

Проверка:

    firewall-cmd --list-all

Важно не перепутать: service=https обычно открывает только TCP/443.

## Проверяем Hysteria2 отдельно от TUN

Перед интеграцией с sing-box полезно доказать, что Hysteria2 работает сам по себе.

Для UDP лучше использовать реальный UDP payload, например DNS forwarding. Если тест подтверждает только TCP внутри Hysteria2, это ещё не доказывает рабочий UDP relay.

На edge во время теста удобно смотреть:

    tcpdump -lni eth0 -nn       '((udp port 443) or (host 8.8.8.8 and udp port 53))'

Рабочая последовательность выглядит так:

    client -> edge UDP/443
    edge -> 8.8.8.8:53
    8.8.8.8:53 -> edge
    edge UDP/443 -> client

## Почему один IP и один порт удобны

Снаружи проект использует один адрес и один номер порта:

    TCP/443 -> Naive
    UDP/443 -> Hysteria2

Это упрощает firewall, DNS и диагностику.

При этом конфликта нет, потому что TCP и UDP — разные транспортные сокеты.

## Контрольный checklist edge

- DNS A указывает на VPS;
- TLS сертификат валиден;
- Caddy отвечает по HTTP/2;
- HTTP/3 в Caddy отключён;
- Caddy слушает TCP/443;
- Hysteria2 слушает UDP/443;
- firewall разрешает оба протокола;
- Naive CONNECT даёт egress IP VPS;
- Hysteria2 реально пересылает UDP payload.

## Дальше

Следующая часть: [локальный sing-box gateway и MikroTik policy routing](/ru/notes/networking/vpn-ca-local-gateway-sing-box-mikrotik/).

### Ссылки

- [NaiveProxy](https://github.com/klzgrad/naiveproxy)
- [Caddy forwardproxy](https://github.com/caddyserver/forwardproxy)
- [Hysteria2 documentation](https://v2.hysteria.network/)
