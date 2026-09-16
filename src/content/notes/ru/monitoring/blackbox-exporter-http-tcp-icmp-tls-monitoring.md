---
title: "Blackbox-мониторинг HTTP, TCP, ICMP и TLS через Prometheus"
description: "Production-backed схема Blackbox Exporter для readiness-проверок, TCP-доступности, ICMP-canary, TLS-валидации и контроля срока действия сертификатов."
category: "Мониторинг и безопасность"
tags: ["prometheus", "blackbox-exporter", "http", "tcp", "icmp", "tls", "monitoring"]
published: 2026-09-16
updated: 2026-09-16
status: current
testedOn: ["blackbox_exporter 0.28.0", "Prometheus", "HTTP", "TCP", "ICMP", "TLS 1.2+"]
featured: true
translationKey: "monitoring/blackbox-exporter-http-tcp-icmp-tls-monitoring"
---

## Контекст

Метрики хоста показывают, что сервер доступен и не находится под явным ресурсным давлением. Но они не доказывают, что конкретный сетевой endpoint реально доступен или что TLS-handshake продолжает проходить проверку.

В production используется отдельный слой активных проверок с узла Prometheus:

```text
Prometheus
    |
    +--> HTTP probe --> readiness / health endpoint
    |
    +--> TCP probe  --> доступность порта сервиса
    |
    +--> ICMP probe --> сетевой canary
    |
    +--> TLS probe  --> проверенный handshake + срок сертификата
                 
blackbox_exporter 0.28.0
```

Blackbox Exporter работает локально на сервере Prometheus, слушает только loopback и получает target/module через relabeling Prometheus.

## Подтверждённый production baseline

Активная конфигурация:

```text
blackbox_exporter 0.28.0
platform: linux/amd64
service account: blackbox_exporter
listener: 127.0.0.1:9115
configuration: /etc/blackbox_exporter/blackbox.yml
```

systemd-unit hardened и оставляет только capability, необходимую для ICMP:

```ini
CapabilityBoundingSet=CAP_NET_RAW
AmbientCapabilities=CAP_NET_RAW
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ProtectControlGroups=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectKernelLogs=true
LockPersonality=true
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
```

Bind на `127.0.0.1:9115` означает, что API проб не выставлен как обычный сетевой сервис.

## Модули probe

Используются четыре production-модуля.

### HTTP readiness

```yaml
http_2xx_ipv4:
  prober: http
  timeout: 10s
  http:
    method: GET
    preferred_ip_protocol: ip4
    follow_redirects: true
```

Используется для readiness/health endpoint'ов.

### TCP connect

```yaml
tcp_connect_ipv4:
  prober: tcp
  timeout: 5s
  tcp:
    preferred_ip_protocol: ip4
```

Проверяет, может ли monitoring host установить TCP-соединение с endpoint'ом.

Успешный TCP probe не доказывает корректность прикладного протокола.

### ICMP

```yaml
icmp_ipv4:
  prober: icmp
  timeout: 5s
  icmp:
    preferred_ip_protocol: ip4
```

Для этого probe exporter получает `CAP_NET_RAW`, не запуская весь сервис от root.

### SMTP TLS

```yaml
smtp_tls_ipv4:
  prober: tcp
  timeout: 10s
  tcp:
    preferred_ip_protocol: ip4
    tls: true
    tls_config:
      server_name: <smtp-hostname>
      min_version: TLS12
      insecure_skip_verify: false
```

Этот module выполняет полноценный проверяемый TLS-handshake с hostname validation и минимальной версией TLS 1.2.

Production-модуль привязан к конкретному SMTP hostname через `server_name`. Для другого TLS endpoint его нельзя механически переиспользовать без изменения hostname или отдельного module.

## Jobs в Prometheus

Сам Blackbox Exporter мониторится как локальный target.

Probe jobs используют `/probe`, передают исходный target через `__param_target`, после чего `__address__` переписывается на loopback exporter.

### HTTP

```yaml
- job_name: blackbox_http
  scrape_interval: 15s
  scrape_timeout: 12s
  metrics_path: /probe
  params:
    module: [http_2xx_ipv4]
```

### TCP

```yaml
- job_name: blackbox_tcp
  scrape_interval: 15s
  scrape_timeout: 12s
  metrics_path: /probe
  params:
    module: [tcp_connect_ipv4]
```

### ICMP

```yaml
- job_name: blackbox_icmp
  scrape_interval: 15s
  scrape_timeout: 12s
  metrics_path: /probe
  params:
    module: [icmp_ipv4]
```

### TLS

TLS job получает module из discovery label:

```yaml
- source_labels: [blackbox_module]
  target_label: __param_module
```

Это позволяет использовать разные protocol-specific modules для разных TLS endpoint'ов.

## Target inventory через file_sd

Targets вынесены из основного `prometheus.yml` в:

```text
/etc/prometheus/targets/blackbox/
```

Подтверждённый inventory включает:

```text
HTTP
  - readiness endpoint Prometheus
  - health endpoint локального notification bridge

TCP
  - listener security-системы
  - SMTP endpoint
  - XMPP client-to-server endpoint

ICMP
  - monitoring-host canary

TLS
  - SMTP TLS endpoint
```

Targets имеют labels:

```text
site
target_name
service
probe_type
criticality
```

Эти labels затем используются в alert rules.

## Runtime-проверка

На момент верификации каждый production probe возвращал:

```text
probe_success = 1
```

для всех четырёх jobs:

```text
blackbox_http
blackbox_tcp
blackbox_icmp
blackbox_tls
```

Это важнее одной только YAML-валидации: runtime подтверждает DNS, routing, firewall path, listener и TLS validation с точки мониторинга.

## Мониторинг notification pipeline

Blackbox layer используется не только для общих endpoint checks, но и для контроля пути доставки уведомлений.

Текущие правила независимо проверяют:

```text
health локального XMPP bridge
TCP-доступность SMTP
TCP-доступность XMPP
SMTP TLS handshake
```

Отдельно мониторятся собственные counters Alertmanager по ошибкам доставки. Поэтому транспортная доступность и фактическая ошибка отправки уведомления не смешиваются в один сигнал.

Диагностика получается многоуровневой:

```text
TCP probe failed
  -> сеть / routing / listener

TCP работает, TLS probe failed
  -> TLS / сертификат / hostname validation

probes работают, Alertmanager фиксирует failures
  -> notification integration / application problem
```

## Контроль срока действия сертификата

TLS job экспортирует:

```text
probe_ssl_earliest_cert_expiry
```

Production rules используют два окна:

```text
warning:  меньше 30 дней, но не меньше 14
critical: меньше 14 дней
```

На момент проверки у сертификата оставалось примерно 80 дней.

Типовой запрос оставшегося срока:

```promql
(
  probe_ssl_earliest_cert_expiry{job="blackbox_tls"}
  - time()
) / 86400
```

Expiry alerts дополнительно требуют `probe_success == 1`, чтобы ошибка TLS handshake не маскировалась под обычное предупреждение об истечении сертификата.

## Alerting по probe_success

Production alerts используют `probe_success == 0` с задержкой, а не реагируют на одиночный пропуск.

Для критичных SMTP/XMPP/bridge проверок используется hold порядка двух минут.

ICMP target присутствует в discovery и в runtime успешно отвечает, но в проверенном активном rule section отдельный ICMP alert не подтверждён. Поэтому он здесь не выдумывается.

## Семантика HTTP probe

HTTP `2xx` probe подтверждает успешный ответ указанного endpoint'а с узла мониторинга.

Это не означает, что приложение целиком исправно. Readiness endpoint сильнее простого TCP connect, но слабее полноценной synthetic business transaction.

## Семантика TCP probe

Успешный TCP connect подтверждает только следующее:

```text
DNS resolution прошёл, если использовался hostname
маршрут до endpoint существует
TCP handshake завершился
listener принял соединение
```

Он не доказывает SMTP delivery, XMPP session establishment, authentication или корректность бизнес-логики.

Поэтому для SMTP существует отдельный TLS probe, а ошибки фактической отправки контролируются через Alertmanager.

## ICMP canary

ICMP target используется как простой canary для проверки самого probe path.

Это не замена полноценному мониторингу сети. Для маршрутизаторов, коммутаторов и WAN-путей остаются отдельные SNMP/routing/device-specific telemetry layers.

## Валидация

Проверка exporter:

```bash
/usr/local/bin/blackbox_exporter --version
systemctl status blackbox_exporter --no-pager
ss -lntp | grep ':9115'
```

После изменения modules/targets недостаточно проверить только конфиг — нужно подтвердить runtime series через Prometheus.

Проверка всех probes:

```promql
probe_success{job=~"blackbox_http|blackbox_tcp|blackbox_icmp|blackbox_tls"}
```

Проверка срока сертификата:

```promql
(probe_ssl_earliest_cert_expiry{job="blackbox_tls"} - time()) / 86400
```

## Процедура изменения

При добавлении нового probe:

1. определить нужный тип проверки: HTTP, TCP, ICMP или TLS;
2. переиспользовать существующий module только при совпадении семантики;
3. для другого TLS hostname/protocol policy создать отдельный module;
4. добавить target в соответствующий file_sd файл;
5. сохранить единые labels `target_name`, `service`, `probe_type`, `criticality`;
6. проверить конфиг Prometheus;
7. reload Prometheus;
8. убедиться, что runtime target появился;
9. проверить `probe_success` и необходимые protocol metrics;
10. добавлять alert только когда для такого отказа существует реальная операционная реакция.

## Rollback

Перед изменениями сохранить предыдущие версии:

```text
/etc/blackbox_exporter/blackbox.yml
/etc/prometheus/prometheus.yml
/etc/prometheus/targets/blackbox/*.yml
соответствующего Prometheus rule file
```

Rollback: вернуть module/target/rule, снова проверить конфиг и подтвердить возврат runtime series в ожидаемое состояние.

## Ограничения

- TCP check не является application transaction.
- HTTP health endpoint доказывает только то, что реализует сам endpoint.
- ICMP может фильтроваться даже при рабочем прикладном трафике.
- TLS module с фиксированным `server_name` привязан к конкретному endpoint.
- Метрика certificate expiry имеет смысл только при успешном TLS probe.
- Проверка с одного Prometheus host описывает доступность только с этой точки наблюдения.

## Ссылки

- Blackbox Exporter: <https://github.com/prometheus/blackbox_exporter>
- Prometheus relabel configuration: <https://prometheus.io/docs/prometheus/latest/configuration/configuration/#relabel_config>
- Prometheus file-based service discovery: <https://prometheus.io/docs/prometheus/latest/configuration/configuration/#file_sd_config>
- Prometheus alerting rules: <https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/>
