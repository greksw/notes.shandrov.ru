---
title: "Mailcow: безопасная массовая очистка Trash через doveadm"
description: "Практический Bash-скрипт для предварительного подсчёта и массового удаления писем старше заданного срока из Trash во всех ящиках Mailcow с контрольной проверкой после expunge."
category: "Приложения и сервисы"
tags: ["mailcow", "dovecot", "doveadm", "email", "bash", "operations"]
published: 2026-09-24
updated: 2026-09-24
status: current
testedOn: ["Mailcow Dockerized", "Dovecot 2.3.21.1", "Docker Compose"]
featured: false
lang: ru
translationKey: "applications/mailcow-trash-cleanup-doveadm"
---

У Mailcow есть штатный механизм очистки старых сообщений через Dovecot `doveadm expunge`. Для единичной команды этого достаточно, но при массовом удалении из десятков ящиков хотелось получить более безопасную процедуру: сначала увидеть объём операции, затем удалить и после этого автоматически проверить результат.

В итоге получился небольшой Bash-скрипт с двумя режимами — `check` и `expunge`.

## 01 / ЗАДАЧА

Политика простая:

- обработать все почтовые ящики Mailcow;
- работать только с папкой `Trash`;
- удалять сообщения с `savedbefore 14d`;
- перед удалением показать количество сообщений по каждому пользователю;
- без явного `expunge` ничего не удалять;
- после операции проверить, что подходящих сообщений не осталось.

Схема:

```text
all Mailcow users
        |
        v
mailbox Trash
        |
        v
savedbefore 14d
        |
        +--> check: count only
        |
        +--> expunge: delete
                    |
                    v
             verification search
```

## 02 / ПОЧЕМУ SAVEDBEFORE, А НЕ BEFORE

В Dovecot это принципиально разные критерии.

Для нашей задачи используется:

```text
savedbefore 14d
```

Dovecot описывает `savedbefore` как поиск по времени, когда сообщение было сохранено или скопировано в mailbox. В документации `doveadm expunge` приведён аналогичный пример удаления сообщений из Spam, которые были saved/copied туда более двух недель назад.

То есть критерий подходит для retention-политики корзины: нас интересует время нахождения сообщения в `Trash`, а не исходная дата письма.

Mailcow также приводит штатный пример:

```bash
docker compose exec dovecot-mailcow \
  doveadm expunge -A mailbox 'Junk' savedbefore 7d
```

Для `Trash` применяется тот же search query.

## 03 / СНАЧАЛА ПРОВЕРЯЕМ ПОИСК

Перед написанием скрипта полезно убедиться, что Dovecot действительно находит нужные сообщения:

```bash
cd /opt/mailcow-dockerized

docker compose exec -T dovecot-mailcow \
  doveadm search -A mailbox 'Trash' savedbefore 14d |
head -30
```

При `-A` в выводе присутствует пользователь, GUID mailbox и UID сообщения.

Количество:

```bash
docker compose exec -T dovecot-mailcow \
  doveadm search -A mailbox 'Trash' savedbefore 14d |
wc -l
```

Разбивка по пользователям:

```bash
docker compose exec -T dovecot-mailcow \
  doveadm search -A mailbox 'Trash' savedbefore 14d |
awk '{count[$1]++} END {
  for (user in count)
    print count[user], user
}' |
sort -nr
```

Mailcow отдельно документирует использование первого поля `doveadm search -A` для подсчёта сообщений по пользователям.

## 04 / ПОЧЕМУ НЕДОСТАТОЧНО ПРОСТО PIPE В WC

На первый взгляд можно написать:

```bash
docker compose exec -T dovecot-mailcow \
  doveadm search -A mailbox 'Trash' savedbefore 14d |
wc -l
```

Для ручной диагностики это удобно. Для эксплуатационного скрипта есть проблема: если первая команда завершится ошибкой, последующий `wc` может успешно вернуть `0`.

В результате ошибка Dovecot будет выглядеть как отсутствие сообщений.

Поэтому в скрипте включён строгий режим:

```bash
set -Eeuo pipefail
```

А результат поиска сначала сохраняется во временный файл. Код возврата `doveadm` проверяется отдельно, и только затем выполняются `wc` и `awk`.

## 05 / СКРИПТ

Публичная версия лежит в этом же GitHub-репозитории:

```text
scripts/mailcow-trash-cleanup/mailcow-trash-cleanup.sh
```

Установка:

```bash
install -m 700 \
  mailcow-trash-cleanup.sh \
  /root/mailcow-trash-cleanup.sh
```

Основные настройки:

```bash
MAILCOW_DIR="/opt/mailcow-dockerized"
MAILBOX="Trash"
AGE="14d"
MODE="${1:-check}"
```

Самая важная строка здесь:

```bash
MODE="${1:-check}"
```

Без аргументов скрипт всегда переходит в безопасный режим `check`.

## 06 / CHECK MODE

Запуск:

```bash
/root/mailcow-trash-cleanup.sh check
```

или просто:

```bash
/root/mailcow-trash-cleanup.sh
```

Скрипт:

1. проверяет Dovecot;
2. считает все сообщения в `Trash`;
3. ищет `savedbefore 14d`;
4. группирует результат по пользователям;
5. показывает итог;
6. завершает работу до блока удаления.

Пример:

```text
============================================================
 Mailcow Trash cleanup
 Mailbox : Trash
 Age     : 14d
 Mode    : check
============================================================

Total messages in Trash : 8120
Older than 14d          : 5300

CHECK ONLY.
No messages were deleted.
```

Перед первым массовым удалением этот режим обязателен.

## 07 / EXPUNGE MODE

После проверки:

```bash
/root/mailcow-trash-cleanup.sh expunge
```

Фактическая операция:

```bash
docker compose exec -T dovecot-mailcow \
  doveadm expunge -A mailbox "$MAILBOX" savedbefore "$AGE"
```

Во время большого удаления Dovecot может выводить много строк:

```text
doveadm(user@example.org): Info: expunge: box=Trash, uid=..., msgid=<...>, size=...
```

Это нормальный информационный вывод.

## 08 / КОНТРОЛЬ ПОСЛЕ УДАЛЕНИЯ

Успешный return code самого `expunge` — ещё не вся проверка.

После него скрипт повторяет:

```bash
doveadm search -A mailbox "$MAILBOX" savedbefore "$AGE"
```

Нормальный итог:

```text
Expunge completed successfully.

=== Verification ===
Remaining messages older than 14d: 0

OK: all matching Trash messages were expunged.
```

Если сообщения остаются, выводится их распределение по пользователям, а скрипт завершается кодом `3`.

## 09 / ТИПОВЫЕ ОШИБКИ

### doveadm: command not found

На host OS `doveadm` может отсутствовать. В Mailcow команда выполняется внутри Dovecot container:

```bash
docker compose exec -T dovecot-mailcow doveadm ...
```

### doveadm: unrecognized option: -

Не следует использовать:

```bash
doveadm --version
```

Для проверки версии Dovecot:

```bash
docker compose exec -T dovecot-mailcow \
  dovecot --version
```

### Invalid mailbox name: Name is empty

Такое бывает при ручном запуске:

```bash
doveadm search -A mailbox "$MAILBOX"
```

если переменная `MAILBOX` в текущем shell не задана.

При ручной диагностике лучше явно писать:

```bash
mailbox 'Trash'
```

В скрипте значение задаётся заранее:

```bash
MAILBOX="Trash"
```

## 10 / ИЗМЕНЕНИЕ RETENTION

Например, хранить удалённые письма 30 дней:

```bash
AGE="30d"
```

После любого изменения:

```bash
/root/mailcow-trash-cleanup.sh check
```

и только после проверки:

```bash
/root/mailcow-trash-cleanup.sh expunge
```

Не стоит без отдельного анализа менять `MAILBOX="Trash"` на wildcard вроде `%`: это может расширить область удаления на остальные папки.

## 11 / АВТОМАТИЗАЦИЯ

Mailcow документирует запуск `doveadm expunge` через cron. Например:

```cron
0 4 * * * /root/mailcow-trash-cleanup.sh expunge
```

Но сначала лучше выполнить несколько ручных циклов `check -> expunge -> verification`.

Для полностью unattended-варианта я бы дополнительно добавил:

- `flock` от параллельного запуска;
- отдельный log-файл;
- logrotate;
- уведомление при ненулевом exit code;
- компактный summary вместо полного потока `Info: expunge`.

## 12 / ИТОГ

Прямой `doveadm expunge` решает задачу одной строкой. Но для эксплуатации важнее не краткость команды, а контролируемость операции.

В этом варианте процесс выглядит так:

```text
search
  |
  +--> count total
  |
  +--> count by user
  |
  v
explicit expunge
  |
  v
verification search
  |
  +--> 0 matches = success
```

Скрипт не заменяет backup и retention policy, но делает массовую очистку `Trash` предсказуемой и проверяемой.

## Ссылки

- [Mailcow: Expunge a Users mails](https://docs.mailcow.email/manual-guides/Dovecot/u_e-dovecot-expunge/)
- [Mailcow: More Examples with DOVEADM](https://docs.mailcow.email/manual-guides/Dovecot/u_e-dovecot-more/)
- [Dovecot: doveadm-expunge](https://doc.dovecot.org/main/core/man/doveadm-expunge.1.html)
