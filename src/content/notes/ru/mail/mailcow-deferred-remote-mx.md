---
title: "Диагностика deferred delivery в Mailcow: локальный firewall или отказ remote MX?"
description: "Короткий evidence-driven workflow для отделения локальных SMTP connectivity problems от выборочного отказа со стороны удалённого mail server."
category: "Почта и сервисы"
tags: ["mailcow", "postfix", "smtp", "networking", "troubleshooting"]
published: 2026-09-16
updated: 2026-09-16
status: current
testedOn: ["Mailcow", "Postfix", "Linux"]
featured: true
lang: ru
translationKey: "mail/mailcow-deferred-remote-mx"
---

## Контекст

Рост deferred queue часто сразу приводит к предположению, что outbound TCP/25 заблокирован локально. Это простая гипотеза, и её нужно проверить до любых изменений firewall или NAT.

Полезная диагностика сравнивает исправные delivery paths с проблемным destination и добавляет packet-level evidence.

## Начните с очереди

Определите, затрагивают ли deferrals все destinations или только отдельные recipient domains/MX hosts.

Фиксируйте фактическую причину Postfix defer вместо того, чтобы считать все deferred messages одной и той же проблемой.

Выборочные failures уже сами по себе являются аргументом против полного локального блокирования TCP/25.

## Сравните с known-good destinations

С mail host проверьте TCP/25 connectivity до нескольких независимых крупных mail providers и отдельно до проблемного MX.

Если известные внешние MX доступны, а один конкретный destination стабильно timeout или сбрасывает соединение, область проблемы уже сужается: это не «outbound SMTP полностью сломан», а конкретный path или peer отказывается от communication.

Не меняйте firewall только потому, что один remote MX недоступен.

## Снимите packets

Короткий packet capture на external interface позволяет понять, где именно рвётся session.

Ищите:

- SYN, уходящий с local server;
- SYN/ACK или отсутствие ответа;
- TCP reset и его source;
- retransmissions;
- промежуточный ICMP response.

Reset, отправленный remote endpoint, принципиально отличается от локально сгенерированного reject или silent upstream block.

## Сопоставьте с reputation и remote policy

Если только отдельные MX hosts reject или reset sessions, тогда как обычная SMTP connectivity работает, исследуйте peer-side policy, reputation или blocklisting.

Локальный MTA может работать корректно, хотя доставка к конкретному destination продолжает оставаться deferred.

## Проверка

Обоснованный вывод должен включать совокупность evidence:

- Postfix queue/defer reason;
- успешные TCP/25 tests до независимых MX hosts;
- повторяемый failure до проблемного MX;
- packet capture, показывающий, где connection отклоняется или теряется;
- отсутствие соответствующего local firewall reject.

Такой подход позволяет не вносить production firewall changes для устранения проблемы, которая фактически находится на стороне remote peer.
