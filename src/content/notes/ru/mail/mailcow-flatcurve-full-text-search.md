---
title: "Полнотекстовый поиск в Mailcow: Flatcurve, индексация и проверка скорости"
description: "Как включить Flatcurve, заполнить индексы Dovecot по ящикам, проверить поиск в общих папках и оценить нагрузку по практическим замерам."
category: "Почта и сервисы"
tags: ["mailcow", "dovecot", "flatcurve", "fts", "email", "bash"]
published: 2026-11-20
updated: 2026-11-20
status: current
testedOn: ["Mailcow Dockerized", "Dovecot 2.3.21.1", "Docker Compose"]
featured: false
lang: ru
---

На почтовом сервере с архивом около 1,6 ТБ поиск по телу письма в одном большом `INBOX` занимал около десяти минут. После включения Flatcurve и построения индекса тот же запрос вернул 77 совпадений за 0,519 секунды с учётом запуска `docker compose exec`. Поиск в общих «Входящих» из учётной записи получателя доступа вернул те же 77 совпадений за 0,311 секунды после отдельной индексации этого подключения.

| Проверка | Измеренный результат |
| --- | --- |
| Первичное заполнение индексов на сервере с архивом около 1,6 ТБ | Около 6–7 часов |
| Поиск по телу в личном `INBOX` после индексации | 77 совпадений за 0,519 с |
| Поиск по телу в общем `INBOX` после индексации подключения | 77 совпадений за 0,311 с |
| Поиск в ящике объёмом около 71 ГиБ на другом сервере | Три запроса за 2–5 с. Первый запрос с распространённым словом занял менее минуты, повторный ответил практически сразу |

Исходные десять минут наблюдались в почтовом клиенте. Два субсекундных замера сделаны на сервере через `doveadm search`. Они показывают серверное время выполнения контрольного запроса. Время от ввода слова до отрисовки результатов в клиенте включает дополнительную работу клиента и сети. Влияние прогрева кэша на первый запрос отдельно не измерялось.

## Проверка состояния FTS

Dovecot использует FTS для поиска по телу через IMAP `SEARCH BODY` и `SEARCH TEXT`. Для заголовков, включая тему и отправителя, он может использовать обычный кэш. Поэтому для контрольной проверки нужно взять слово, присутствующее именно **в теле** известного письма, и ограничить поиск одной папкой.

В Mailcow выпуска `2025-01` Flatcurve заменил Solr. При обновлении Mailcow отключал FTS до ручного включения. Блок `fts = flatcurve` может уже присутствовать в настройках Dovecot. Состояние работающего сервиса проверяйте по окружению контейнера и загруженным IMAP-плагинам. [Примечания к выпуску Mailcow 2025-01](https://mailcow.email/posts/2025/release-2025-01/) · [Dovecot 2.3 FTS](https://doc.dovecot.org/2.3/configuration_manual/fts/)

```bash
cd /opt/mailcow-dockerized
docker compose exec -T dovecot-mailcow printenv SKIP_FTS FTS_HEAP FTS_PROCS
docker compose exec -T dovecot-mailcow cat /etc/dovecot/mail_plugins_imap
printf '\n'
docker compose exec -T dovecot-mailcow doveconf -n |
  sed -n '/^service indexer-worker {/,/^}/p'
docker compose exec -T dovecot-mailcow df -hT /var/vmail /var/vmail_index
```

В проверенной сборке с Dovecot 2.3 при активном FTS в списке присутствуют оба плагина: `fts` и `fts_flatcurve`. `df` показывает свободное место на файловых системах. Если оба пути находятся на одном томе, это один общий запас. В расчёт роста заложите индексы общих папок и текущий темп роста почты. [Документация Mailcow по FTS](https://docs.mailcow.email/manual-guides/Dovecot/u_e-dovecot-fts/)

## Включение и выбор лимита памяти

Перед изменениями сохраните исходный `mailcow.conf` и запланируйте короткий перерыв IMAP для пересоздания контейнера Dovecot.

```bash
install -m 600 mailcow.conf "/root/mailcow.conf.before-fts-$(date +%Y%m%d-%H%M%S)"
```

В `mailcow.conf` задайте `SKIP_FTS=n`. Для первого прохода достаточно `FTS_PROCS=1`. Параметр `FTS_HEAP` задаёт предел виртуальной памяти одного `indexer-worker`. На одном сервере журнал показал `Out of memory` при `vsz_limit=128 MB` на большой общей папке. При достаточном запасе RAM подняли лимит до 512 МБ и обработали её за 8 минут 9 секунд. На сервере с 5,4 ГиБ RAM Flatcurve уже работал с 128 МБ и одним воркером. Ручной проход по десяти ящикам успешно дополнил существующие индексы. Mailcow рекомендует для систем с памятью менее 8 ГБ оставаться на 128 МБ или рассматривать 256 МБ с учётом нагрузки. [Настройки FTS в Mailcow](https://docs.mailcow.email/manual-guides/Dovecot/u_e-dovecot-fts/#fts-full-text-search-specific-options-in-mailcowconf)

```bash
docker compose up -d --no-deps --pull never dovecot-mailcow
```

После пересоздания повторите проверку плагинов и `vsz_limit`, затем проверьте IMAP и входящую доставку тестовым письмом. Для отката восстановите сохранённый `mailcow.conf` и примените его той же командой. Compose сохраняет подключённые тома при пересоздании контейнера. [Docker Compose up](https://docs.docker.com/reference/cli/docker/compose/up/)

## Первичное заполнение индекса

Проиндексируйте одну папку с известным медленным запросом. Запишите время обработки, свободное место и время повторного поиска по телу. `doveadm index` добавляет в FTS недостающие сообщения, когда плагин активен. При повторном проходе уже обработанная папка может вывести `Cache is already up to date`. Проверка действительным поиском подтверждает пользовательский результат.

```bash
time docker compose exec -T dovecot-mailcow \
  doveadm -v index -u 'user@example.com' INBOX

(
  set -o pipefail
  time docker compose exec -T dovecot-mailcow \
    doveadm search -u 'user@example.com' MAILBOX INBOX BODY 'контрольное' |
    wc -l
)
```

Для большого архива запускайте оставшиеся ящики последовательно. Flatcurve может дополнять индекс автоматически при доставке или при первом поиске. Свободное место проверяйте между заданиями. На сервере с большим архивом за весь ручной проход доступное место по `df` уменьшилось приблизительно на 17 ГиБ. Это изменение занятого объёма общей файловой системы за время работ. Точный прирост каталога FTS отдельно не измерялся. [Команды индексирования в Mailcow](https://docs.mailcow.email/manual-guides/Dovecot/u_e-dovecot-fts/#reindex-fts-full-text-search-database)

## Поиск в общей папке

Проверьте, какой путь `INDEX=` прописан в конфигурации общего пространства имён. В проверенной конфигурации Mailcow общий индекс находился по отдельному пути для получателя доступа. Успешный поиск под владельцем ещё не подтверждает, что индекс общего подключения заполнен. [Общие ящики в Dovecot 2.3](https://doc.dovecot.org/2.3/configuration_manual/shared_mailboxes/shared_mailboxes/) · [Генерация shared namespace в Mailcow](https://github.com/mailcow/mailcow-dockerized/blob/master/data/Dockerfiles/dovecot/docker-entrypoint.sh)

```bash
docker compose exec -T dovecot-mailcow \
  doveadm mailbox list -8 -u 'delegate@example.com' 'Shared/owner@example.com/*'
docker compose exec -T dovecot-mailcow \
  doveadm acl rights -u 'delegate@example.com' 'Shared/owner@example.com/INBOX'
```

При наличии права `read` индексируйте точный путь под получателем доступа. Запрос `BODY` затем выполняйте с теми же пользователем и путём. Для массового обхода надёжнее передавать маски с именами владельцев. Один общий шаблон `Shared/*` в проверенной конфигурации пропускал доступные папки.

```bash
docker compose exec -T dovecot-mailcow \
  doveadm -v index -u 'delegate@example.com' 'Shared/owner@example.com/INBOX'
```

При ошибке `indexer failed to index mailbox` сопоставьте время запроса с журналом Dovecot. Например, `Out of memory` вместе с `vsz_limit=128 MB` указывает на лимит процесса.

```bash
docker compose logs --since=20m --no-color dovecot-mailcow 2>&1 |
  grep -Ei 'indexer|flatcurve|xapian|vsz_limit|out of memory' |
  tail -n 60
```

## Диск, RAM и очистка

Индекс Flatcurve сохраняется на постоянном томе. Linux кэширует читаемые страницы в RAM. При использовании `tmpfs` после перезагрузки пришлось бы снова читать архив и строить индекс. На сервере из примера 6–7 часов первичной индексации и субсекундный серверный поиск на SSD позволили оставить постоянный том. [Page cache в документации ядра Linux](https://docs.kernel.org/admin-guide/mm/concepts.html#page-cache)

При штатном удалении через `doveadm expunge` Flatcurve обрабатывает удаление документов. Полная пересборка после очистки корзины обычно не требуется. Физический размер файлов Xapian может меняться при последующем уплотнении. Для удаления по сроку нахождения письма в корзине применяется `SAVEDBEFORE`. Срок хранения выбирается отдельно для конкретной системы. [События Flatcurve для Dovecot 2.3](https://slusarz.github.io/dovecot-fts-flatcurve/events.html) · [Очистка корзины Mailcow через doveadm](/ru/notes/applications/mailcow-trash-cleanup-doveadm/)

## Скрипты

[Набор Bash-скриптов на GitHub](https://github.com/greksw/notes.shandrov.ru/tree/main/scripts/mailcow-fts) включает диагностику, планирование и последовательную индексацию, а также замер поиска. Примеры и ограничения описаны в README.
