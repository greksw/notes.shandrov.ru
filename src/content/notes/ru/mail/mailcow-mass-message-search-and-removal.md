---
title: "Mailcow: безопасный поиск и массовое удаление опасного письма из всех ящиков"
description: "Runbook для поиска подозрительного письма во всех ящиках Mailcow/Dovecot, проверки точного совпадения, безопасного expunge и контрольной проверки результата."
category: "Почта и сервисы"
tags: ["mailcow", "dovecot", "incident-response", "email", "security", "expunge"]
published: 2026-09-16
updated: 2026-09-16
status: current
testedOn: ["Mailcow dockerized", "Dovecot", "docker compose"]
featured: true
lang: ru
translationKey: "mail/mailcow-mass-message-search-and-removal"
---

## Контекст

Фишинговое, спамовое или иное опасное письмо может успеть попасть сразу в несколько локальных ящиков до того, как его заметят и подтвердят как вредоносное.

После подтверждения инцидента нужно быстро ответить на четыре вопроса:

1. в каких ящиках письмо есть;
2. в каких папках оно находится;
3. достаточно ли точен критерий поиска, чтобы не удалить легитимную почту;
4. действительно ли письмо исчезло после удаления.

В Mailcow для этого удобно использовать `doveadm` внутри контейнера `dovecot-mailcow`.

Разрушающая операция должна быть последней. Сначала строим и проверяем критерий поиска, затем используем тот же критерий для `expunge`.

## Рабочий каталог

```bash
cd /opt/mailcow-dockerized/
```

В примерах используется `docker compose`. Для неинтерактивного запуска из скрипта лучше добавлять `-T`.

## Не удаляйте только по отправителю, если это не подтверждено

Отображаемый `From:` легко подделать, а у того же отправителя в ящиках могут находиться и нормальные письма.

Предпочтительный порядок идентификации такой:

1. уникальный `Message-ID`;
2. `Message-ID` плюс отправитель/тема/дата для дополнительной проверки;
3. отправитель + тема + узкий временной интервал;
4. только отправитель — лишь если область удаления уже подтверждена отдельно.

Несколько условий в поиске Dovecot по умолчанию объединяются логическим AND.

## Быстрый поиск: в каких ящиках есть письма от отправителя

```bash
docker compose exec -T dovecot-mailcow \
  doveadm search -A FROM "sender@example.com"
```

С `-A` команда выводит пользователя, GUID mailbox и UID сообщения. Для быстрого подсчёта по пользователям:

```bash
docker compose exec -T dovecot-mailcow \
  doveadm search -A FROM "sender@example.com" |
awk '{count[$1]++} END {
  for (user in count)
    print count[user], user
}' |
sort -nr
```

Общее число совпадений:

```bash
docker compose exec -T dovecot-mailcow \
  doveadm search -A FROM "sender@example.com" |
wc -l
```

На этом этапе ничего не удаляется.

## Перед удалением получите читаемые данные о письмах

```bash
docker compose exec -T dovecot-mailcow \
  doveadm fetch -A \
  "user mailbox uid date.received hdr.from hdr.to hdr.subject hdr.message-id" \
  FROM "sender@example.com"
```

Полезные поля:

- `user` — владелец ящика;
- `mailbox` — папка;
- `uid` — UID сообщения внутри папки;
- `date.received` — INTERNALDATE;
- `hdr.from`;
- `hdr.to`;
- `hdr.subject`;
- `hdr.message-id`.

Если для диагностики нужен только INBOX:

```bash
docker compose exec -T dovecot-mailcow \
  doveadm fetch -A \
  "user mailbox uid date.received hdr.from hdr.subject hdr.message-id" \
  mailbox INBOX FROM "sender@example.com"
```

Для фактического удаления не стоит предполагать, что все копии всё ещё находятся в INBOX: пользователь или фильтр могли уже переместить письмо.

## Для точного инцидента лучше использовать Message-ID

После проверки одной подтверждённой вредоносной копии зафиксируйте её `Message-ID`.

Пример:

```text
<20260916.123456.abcdef@example.net>
```

Проверьте все ящики:

```bash
docker compose exec -T dovecot-mailcow \
  doveadm fetch -A \
  "user mailbox uid date.received hdr.from hdr.subject hdr.message-id" \
  HEADER Message-ID "<20260916.123456.abcdef@example.net>"
```

Подсчитайте точное количество кандидатов:

```bash
docker compose exec -T dovecot-mailcow \
  doveadm search -A \
  HEADER Message-ID "<20260916.123456.abcdef@example.net>" |
wc -l
```

Полный `Message-ID` вместе с угловыми скобками значительно безопаснее, чем поиск только по отправителю.

## Если Message-ID недостаточно

В некоторых кампаниях `Message-ID` отличается у каждого получателя. Тогда комбинируйте признаки.

```bash
docker compose exec -T dovecot-mailcow \
  doveadm fetch -A \
  "user mailbox uid date.received hdr.from hdr.subject hdr.message-id" \
  FROM "sender@example.com" \
  SUBJECT "Urgent payment request" \
  SINCE 2026-09-15 BEFORE 2026-09-17
```

`SINCE` и `BEFORE` работают по внутренней дате получения сообщения. Для поля `Date:` самого письма используются `SENTSINCE` / `SENTBEFORE`.

Критерий, который прошёл dry run, должен без изменений использоваться и в destructive-команде.

## Массовое удаление подтверждённого письма

Для удаления Dovecot требует явного mailbox expression. Чтобы пройти по всем папкам всех пользователей, используйте wildcard.

Для уникального `Message-ID`:

```bash
docker compose exec -T dovecot-mailcow \
  doveadm expunge -A \
  mailbox '*' \
  HEADER Message-ID "<20260916.123456.abcdef@example.net>"
```

Если инцидент действительно подтверждён только по отправителю:

```bash
docker compose exec -T dovecot-mailcow \
  doveadm expunge -A \
  mailbox '*' \
  FROM "sender@example.com"
```

Вторая команда значительно шире. Используйте её только если нужно удалить все письма, соответствующие этому отправителю.

## Проверка после expunge

Сразу повторите тот же поиск.

```bash
docker compose exec -T dovecot-mailcow \
  doveadm search -A \
  HEADER Message-ID "<20260916.123456.abcdef@example.net>" |
wc -l
```

Ожидаемый результат:

```text
0
```

Если совпадения остались, сначала снова посмотрите их через `doveadm fetch`. Не запускайте второй широкий `expunge` вслепую.

## Что сохранить в incident record

Минимально полезно зафиксировать:

- дату и время инцидента;
- адрес отправителя;
- тему;
- `Message-ID`, если он есть;
- число найденных сообщений и затронутых пользователей;
- критерий поиска;
- команду expunge;
- результат контрольного поиска;
- дополнительные действия по пользователям, если они требовались.

Не сохраняйте тело письма и вложения без необходимости: потенциально вредоносный контент должен храниться только там, где это действительно нужно для расследования.

## Удаление письма не завершает incident response

Если письмо содержало фишинговую ссылку, вложение или OAuth lure, могут понадобиться дополнительные действия:

- определить пользователей, которые открыли письмо;
- сбросить пароли;
- отозвать активные сессии или application tokens;
- проверить endpoints;
- заблокировать sender/domain/URL indicators;
- проверить mail logs на другие варианты кампании.

Удаление письма — это containment, а не весь incident response.

## Отдельная задача: очистка старых сообщений из Trash

Тот же `doveadm` можно использовать для управляемого retention в корзине.

Если имя корзины в системе неизвестно, сначала проверьте реальные mailbox names:

```bash
docker compose exec -T dovecot-mailcow \
  doveadm mailbox list -A | sort -u | grep -Ei '(^|/)(Trash|Deleted)($|/)'
```

Для стандартной папки `Trash` сначала посчитайте сообщения старше 14 дней:

```bash
echo "=== Trash messages saved more than 14 days ago ==="

docker compose exec -T dovecot-mailcow \
  doveadm search -A mailbox Trash savedbefore 14d |
awk '{count[$1]++} END {
  for (user in count)
    print count[user], user
}' |
sort -nr

echo "=== Total ==="

docker compose exec -T dovecot-mailcow \
  doveadm search -A mailbox Trash savedbefore 14d |
wc -l
```

Это только предварительная проверка.

`SAVEDBEFORE` ориентируется на дату сохранения/копирования сообщения в mailbox Dovecot, а не на исходный заголовок `Date:`. Для очистки Trash это обычно именно то, что нужно: срок хранения считается от момента помещения сообщения в корзину.

После проверки количества:

```bash
echo "=== Expunge Trash older than 14 days ==="

docker compose exec -T dovecot-mailcow \
  doveadm expunge -A mailbox Trash savedbefore 14d

echo "expunge_rc=$?"

echo "=== Remaining matches ==="

docker compose exec -T dovecot-mailcow \
  doveadm search -A mailbox Trash savedbefore 14d |
wc -l
```

Mailcow документирует тот же подход для автоматической очистки папок через `doveadm expunge`.

## Stop conditions

Не переходите к `expunge`, если:

- в выборке есть легитимные письма;
- отправитель не является достаточно уникальным индикатором;
- конкретное письмо ещё не проверено через `fetch`;
- количество совпадений неожиданно велико;
- область удаления не подтверждена;
- непонятно имя mailbox или namespace;
- локальная политика требует recovery path, а его нет.

Надёжная последовательность выглядит так:

```text
identify -> fetch -> count -> review -> expunge -> search again -> document
```

## Ссылки

- Dovecot `doveadm search`: <https://doc.dovecot.org/main/core/man/doveadm-search.1.html>
- Синтаксис search query: <https://doc.dovecot.org/2.4.2/core/man/doveadm-search-query.7.html>
- Dovecot `doveadm fetch`: <https://doc.dovecot.org/2.4.1/core/man/doveadm-fetch.1.html>
- Dovecot `doveadm expunge`: <https://doc.dovecot.org/main/core/man/doveadm-expunge.1.html>
- Mailcow expunge guide: <https://docs.mailcow.email/manual-guides/Dovecot/u_e-dovecot-expunge/>
