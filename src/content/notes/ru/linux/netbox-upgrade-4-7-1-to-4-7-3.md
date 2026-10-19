---
title: "Обновление NetBox 4.7.1 до 4.7.3: backup, upgrade.sh, проверка HTTPS"
description: "Практический опыт безопасного обновления NetBox на AlmaLinux: PostgreSQL pg_dump, Git tags, Python 3.12, штатный upgrade.sh, миграции, Gunicorn, RQ, Nginx и проверка сертификата AD CS."
category: "Linux и инфраструктура"
tags: ["netbox", "upgrade", "almalinux", "postgresql", "pg_dump", "bash", "git", "gunicorn", "nginx", "security", "adcs"]
published: 2026-10-19
updated: 2026-10-19
status: current
testedOn: ["AlmaLinux 9.8", "NetBox 4.7.1 → 4.7.3", "Python 3.12.15", "PostgreSQL 16.15", "Gunicorn 26.2.0", "SELinux Enforcing"]
featured: false
lang: ru
translationKey: "linux/netbox-upgrade-4-7-1-to-4-7-3"
---

## Задача

После [развёртывания NetBox](/ru/notes/linux/netbox-almalinux9-deployment/) и [перехода на HTTPS с сертификатом Microsoft AD CS](/ru/notes/security/netbox-microsoft-adcs-https/) понадобилось обновить приложение **4.7.1 → 4.7.3** без замены PostgreSQL, Redis, Nginx и TLS-сертификата. Обновление выполнено **19 октября 2026 года** на виртуальной машине AlmaLinux 9.8 в Proxmox.

В NetBox 4.7.0–4.7.1 значения API-токенов, созданных через фоновые массовые запросы, могли попадать в результаты заданий. Исправление включено в 4.7.2; токены, созданные таким способом, следует считать раскрытыми и заменить. В 4.7.3 добавлены исправления ошибок и оптимизации. Подробности — в [официальных release notes](https://netboxlabs.com/docs/netbox/release-notes/version-4.7).

Имена машин, домены, адреса и идентификаторы инфраструктуры обезличены. Команды ниже адаптированы из выполненного сеанса, а выводы о результате — из реальных проверок. **Скрипт автоматизации ниже опубликован отдельно, но не заявляется как уже отработавший в production:** реальное обновление выполнено вручную штатным скриптом NetBox.

## 01 / Состояние до обновления

| Компонент | Проверенное состояние |
| --- | --- |
| NetBox | v4.7.1, установлен через Git в `/opt/netbox` |
| ОС | AlmaLinux 9.8 |
| Python | 3.12.15 |
| PostgreSQL | 16.15 |
| Приложение | systemd `netbox`, `netbox-rq`; Nginx |
| Безопасность | SELinux Enforcing, HTTPS через корпоративный AD CS |
| Диск | 20 GiB, до обновления занято около 3.2 GiB |

```bash
cd /opt/netbox
git describe --tags --always
git status --short
systemctl is-active netbox netbox-rq nginx
python3.12 --version
runuser -u postgres -- psql -d netbox -Atc 'SELECT version();'
df -h / /opt/netbox
```

Результат: тег `v4.7.1`, три службы `active`, достаточный свободный объём диска. `git status --short` показывал три **неотслеживаемых** файла `.bak`; отслеживаемые файлы не изменялись. Такие резервные копии лучше вынести из каталога исходников после проверки.

## 02 / Резервная копия перед миграцией

До остановки приложения сохранили PostgreSQL в custom format, конфигурацию и TLS-файлы, media; затем проверили список объектов дампа. Архив с ключом и конфигурацией доступен **только root**, должен храниться в зашифрованном внешнем backup-хранилище. Пример процедуры:

```bash
umask 077
BACKUP="/root/netbox-pre-upgrade-$(date -u +%Y%m%d-%H%M%S)"
install -d -m 700 "$BACKUP"
runuser -u postgres -- pg_dump -Fc -d netbox > "$BACKUP/netbox.dump"
test -s "$BACKUP/netbox.dump"
pg_restore --list "$BACKUP/netbox.dump" > "$BACKUP/database-contents.txt"

tar -C / -czf "$BACKUP/configuration.tar.gz" \
  opt/netbox/netbox/netbox/configuration.py \
  etc/nginx \
  etc/systemd/system/netbox.service \
  etc/systemd/system/netbox-rq.service \
  etc/pki/tls/certs/netbox.lab.shandrov.ru.crt \
  etc/pki/tls/private/netbox.lab.shandrov.ru.key

tar -C /opt/netbox/netbox -czf "$BACKUP/media.tar.gz" media
sha256sum "$BACKUP"/*.gz "$BACKUP/netbox.dump" > "$BACKUP/SHA256SUMS"
```

> В этом примере TLS-имя демонстрационное; подставьте реально существующие пути из `nginx -T`. Если TLS-файлы расположены иначе, замените их пути. Само наличие дампа и успешное чтение каталога `pg_restore --list` не доказывают возможности полного восстановления: регулярно проверяйте восстановление на тестовом стенде.

В нашем сеансе получены: `netbox.dump` ≈ **2.4 MiB**, `configuration.tar.gz` ≈ **17 KiB**, `media.tar.gz` ≈ **150 B** (только `.gitkeep`). Успешность backup была подтверждена проверкой списка содержимого, не тестовым восстановлением.

## 03 / Штатное обновление Git-инсталляции

`upgrade.sh` из официального проекта пересоздаёт Python virtualenv, устанавливает зависимости, применяет миграции и перестраивает статику, документацию и индексы. Если применяются плагины или дополнительные Python-библиотеки, **до обновления** проверьте их совместимость и `local_requirements.txt`. В данном сеансе `local_requirements.txt` отсутствовал.

```bash
cd /opt/netbox

git diff --quiet && git diff --cached --quiet || exit 1
git fetch origin --tags
git rev-parse --verify refs/tags/v4.7.3

systemctl stop netbox netbox-rq
git checkout --detach v4.7.3

# Не используем umask 077 при генерации публичной статики
umask 022
PYTHON=/usr/bin/python3.12 ./upgrade.sh
```

Результат из журнала: успешная установка библиотек, сообщение `No migrations to apply`, проверка кабельных путей без пропусков, сборка документации и **453** скопированных статических файлов. В конце `Upgrade complete!`.

> **Не откатывайте просто Git-тег**, если миграции БД уже стартовали или завершились. Откат может потребовать восстановления согласованной резервной копии базы, конфигурации и media. Запланируйте сервисное окно.

## 04 / Запуск и диагностика

```bash
systemctl start netbox netbox-rq
systemctl is-active netbox netbox-rq nginx
nginx -t
git -C /opt/netbox describe --tags --exact-match

runuser -u netbox -- /opt/netbox/venv/bin/python \
  /opt/netbox/netbox/manage.py check
runuser -u netbox -- /opt/netbox/venv/bin/python \
  /opt/netbox/netbox/manage.py migrate --check

journalctl -u netbox -u netbox-rq -p err \
  --since '15 minutes ago' --no-pager
getenforce
```

**Подтверждённый результат:** три службы `active`, Nginx `syntax is ok`, тег `v4.7.3`, Django `System check identified no issues (0 silenced)`, неприменённых миграций нет, ошибок в журнале нет, `SELinux: Enforcing`.

После обновления Gunicorn слушал только `127.0.0.1:8001`, использовал пять worker-процессов. Фоновый `netbox-rq` работал с очередями `high`, `default`, `low`.

## 05 / Проверка памяти и HTTPS после обновления

Виртуальная машина имеет около **7.5 GiB RAM**, доступно около **5.4 GiB**, swap **0 из 4 GiB**; диск 20 GiB, занято 3.3 GiB (17%). Systemd показывал приблизительно **1.06 GiB** для `netbox.service` и **220 MiB** для `netbox-rq.service`. Значения актуальны на момент проверки и не являются гарантированной нормой для всех установок.

TLS остаётся на Nginx: сертификат подписан внутренним корпоративным Root CA, имя присутствует в SAN, срок действия сертификата — **19.10.2026–18.10.2028**. Команды для контроля:

```bash
curl -sS -o /dev/null \
  -w 'HTTP: %{http_code}\nTLS verification: %{ssl_verify_result}\n' \
  --max-time 10 \
  https://netbox.lab.shandrov.ru/

openssl x509 -in /etc/pki/tls/certs/netbox.lab.shandrov.ru.crt \
  -noout -subject -issuer -dates -ext subjectAltName
```

Фактический вывод `curl`: **HTTP 302**, **TLS verification: 0**. Здесь `302` означает ожидаемое перенаправление приложения, а нулевой код проверки означает успешную проверку TLS-цепочки и имени **со стороны сервера, где выполнялся `curl`**. Проверку входа в браузере и доверия других клиентов выполняют отдельно. Не используйте `curl -k` для проверок сертификата.

## 06 / Скрипт обслуживания на GitHub

Для повторяемого обслуживания подготовлен [Bash-скрипт `netbox-upgrade.sh`](https://github.com/greksw/notes.shandrov.ru/blob/main/scripts/netbox-upgrade.sh). Это **новый инструмент**, а не скрипт, которым выполнялось описанное выше обновление. Он предусматривает явный номер целевой версии, режим предварительной проверки, обязательный `--confirm`, резервирование PostgreSQL и конфигурации, контролируемую остановку сервисов, штатный `upgrade.sh` и проверки после запуска. Автоматического downgrade/restore нет намеренно.

```bash
# Перед запуском скачайте и изучите файл; доверяйте только собственному репозиторию.
bash -n netbox-upgrade.sh
sudo ./netbox-upgrade.sh --check --target v4.7.3
sudo ./netbox-upgrade.sh --apply --target v4.7.3 --confirm \
  --tls-cert /etc/pki/tls/certs/netbox.lab.shandrov.ru.crt \
  --tls-key /etc/pki/tls/private/netbox.lab.shandrov.ru.key \
  --url https://netbox.lab.shandrov.ru/
```

> Команды `--apply` приведены для **будущих обновлений со старой версии**. Если NetBox уже находится на `v4.7.3`, ничего повторно делать не нужно. Проверьте алгоритм на тестовом окружении и сохраните внешнюю резервную копию.

## Результат

Обновление **NetBox 4.7.1 → 4.7.3** завершилось штатно без замены операционной системы, PostgreSQL, Redis, Nginx и сертификата AD CS. Следующие эксплуатационные задачи — автоматический backup с тестами восстановления, срок действия TLS-сертификатов, наблюдение за очередями RQ и контролируемые будущие обновления.

## Источники

- [NetBox — официальный порядок обновления](https://netboxlabs.com/docs/netbox/installation/upgrading/)
- [NetBox 4.7 — release notes](https://netboxlabs.com/docs/netbox/release-notes/version-4.7)
- [NetBox — штатный `upgrade.sh`](https://github.com/netbox-community/netbox/blob/main/upgrade.sh)