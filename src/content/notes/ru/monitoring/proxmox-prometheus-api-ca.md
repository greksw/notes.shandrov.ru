---
title: "Мониторинг Proxmox VE в Prometheus через API token и доверенный CA"
description: "Production-подход к сбору метрик Proxmox без отключения TLS verification и без использования полноценной administrator account."
category: "Мониторинг и безопасность"
tags: ["proxmox", "prometheus", "tls", "api", "monitoring"]
published: 2026-09-16
updated: 2026-09-16
status: current
testedOn: ["Proxmox VE 9.x", "Prometheus 3.x", "AlmaLinux 9"]
featured: true
lang: ru
translationKey: "monitoring/proxmox-prometheus-api-ca"
---

## Контекст

Prometheus exporter нужен доступ к Proxmox API, но ради мониторинга не следует использовать переиспользуемый administrator password, а TLS verification не нужно отключать только для того, чтобы HTTPS-запросы начали работать.

Здесь используются три независимых уровня:

1. отдельная Proxmox account с read-only permissions;
2. API token, привязанный к этой account;
3. явное доверие к Proxmox cluster CA на monitoring host.

## Модель доступа

Создайте отдельную monitoring identity в Proxmox и выдайте только те права, которые нужны для inventory и сбора метрик. Для read-only exporter роль `PVEAuditor` — более подходящая baseline, чем `Administrator`.

Для exporter используйте отдельный API token. Разделение token и user account позволяет независимо отзывать и ротировать token и не хранить interactive password в exporter configuration.

## TLS trust

Не используйте `verify_ssl: false` как постоянное решение.

Экспортируйте соответствующий Proxmox root CA, передайте его на monitoring system по доверенному administrative channel и установите как root-owned certificate file. Настройте exporter process на использование этого CA bundle при HTTPS-соединениях с Proxmox API.

Для Python-based exporter это можно сделать через environment процесса, например задав `REQUESTS_CA_BUNDLE` с путём к установленному CA file.

## Схема Prometheus

Если это упрощает alerting и dashboards, разделяйте cluster-level и node-level collection логически. Типичная схема использует отдельный service port для Proxmox exporter и явные Prometheus jobs как для Proxmox API, так и для обычных `node_exporter` targets на каждом hypervisor.

Это позволяет различать разные типы отказов:

- host metrics отсутствуют, но API здоров;
- API metrics отсутствуют, но nodes доступны;
- недоступен один node;
- collection сломан на уровне всего cluster.

## Проверка

Validation не должна ограничиваться ответом HTTP 200.

- убедитесь, что exporter service работает под ожидаемой account;
- проверьте, что CA bundle действительно используется и certificate errors не подавляются;
- запросите exporter endpoint напрямую;
- выполните `promtool check config` перед reload Prometheus;
- убедитесь, что все ожидаемые Proxmox и node-exporter targets находятся в состоянии `UP`;
- сопоставьте возвращаемый список nodes и VM с реальным cluster inventory.

## Заметки по безопасности

API token остаётся secret, даже если его permissions read-only. Храните его вне repository, ограничьте права на configuration file и ротируйте token при любом exposure.

Read-only token вместе с проверяемым TLS создаёт существенно более безопасную failure boundary, чем administrator credential в сочетании с отключённой проверкой сертификатов.
