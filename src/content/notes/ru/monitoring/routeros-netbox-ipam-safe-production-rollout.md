---
title: "Безопасная миграция IPAM-аудитора в production: GitHub release, systemd rollback и проверка на следующий день"
description: "Практический кейс обновления работающего RouterOS ↔ NetBox IPAM-аудита без остановки мониторинга: pinned commit, 121 offline-тест, shadow exporter, drop-in systemd, Prometheus и контроль таймера."
category: "Мониторинг и безопасность"
tags: ["netbox", "mikrotik", "routeros", "ipam", "prometheus", "systemd", "github", "rollback", "drift-detection", "operations"]
published: 2026-10-26
updated: 2026-10-26
status: current
testedOn: ["MikroTik RouterOS 7", "NetBox 4.7.3", "Python 3.11", "AlmaLinux 9", "Node Exporter", "Prometheus", "systemd"]
featured: false
lang: ru
translationKey: "monitoring/routeros-netbox-ipam-safe-production-rollout"
---

## Задача: обновить работающий аудит, не потеряв контроль

Ранее были реализованы [read-only сверка RouterOS с NetBox](/ru/notes/monitoring/routeros-netbox-ipam-drift-ssh-readonly/) и [экспорт её результатов в Prometheus с алертами](/ru/notes/monitoring/routeros-netbox-ipam-prometheus-alerting/). Но первоначальный рабочий вариант использовал частные локальные скрипты. После объединения [PR #16 в NetBox Inventory Toolkit](https://github.com/greksw/netbox-inventory-toolkit/pull/16) появилась универсальная версия: SSH-сборщик, HTTPS GET-клиент NetBox, CLI, экспортёр метрик, тесты и шаблоны systemd.

Задача была не в повторной установке сервиса, а в **контролируемой замене исполняемого кода без изменения действующего таймера, правил Prometheus и настроек RouterOS/NetBox**.

Все серверные имена, пути с привязкой к конкретной компании, IP-адреса, числа инвентарных объектов и детали VPN здесь обезличены. Показанные команды — воспроизводимый план с параметрами, которые необходимо согласовать для своей среды. Не запускайте переход на production только на основании этой статьи.

## 01 / Контракт миграции

Главное правило: новый код обязан сохранить семантику состояния независимо от внутренней реализации.

| Код процесса | Смысл | Метрика состояния | Действие |
| --- | --- | --- | --- |
| \`0\` | \`CLEAN\`: полные данные, расхождений нет | \`0\` | Ничего не менять |
| \`1\` | \`DRIFT\`: проверенное расхождение | \`1\` | Разобрать изменение |
| \`2\` | \`ERROR\`: неполные данные или отказ чтения | \`2\` | Восстановить аудит |

Универсальный CLI читает частный JSON-конфиг \`root:root 0600\`. В нём находятся адрес RouterOS, имена выбранных объектов NetBox, пути к SSH-ключу, CA и токену, утверждённые базовые количества и точечные исключения динамических адресов. **Сам токен хранится в отдельном закрытом файле**, а не в репозитории.

У RouterOS используются только заранее разрешённые SSH-команды чтения VLAN и IPv4. NetBox опрашивается через HTTPS GET с проверкой сертификата и view-only API token. Возможностей автоматической записи или «исправления» конфигурации в этом контуре нет.

## 02 / Версия по фиксированному commit SHA, без зависимости от Git

На сервере аудита утилита \`git\` может отсутствовать. Это не причина изменять рабочий каталог: достаточно взять архив **конкретного проверенного коммита**, а не меняющуюся ветку \`main\`.

Пример с предварительно выбранным полным SHA:

\`\`\`bash
REV="REVIEWED_FULL_COMMIT_SHA"
STAGE="/opt/netbox-inventory-toolkit-$(printf '%s' "$REV" | cut -c1-7)"
TMP="$(mktemp -d)"
# Сначала сверить REV с просмотренным PR и результатом GitHub CI.
curl -fLsS \
  "https://codeload.github.com/greksw/netbox-inventory-toolkit/tar.gz/$REV" \
  -o "$TMP/source.tar.gz"
tar -tzf "$TMP/source.tar.gz" >/dev/null
install -d -m 0755 "$STAGE"
tar -xzf "$TMP/source.tar.gz" -C "$STAGE" \
  --strip-components=1 --no-same-owner
cd "$STAGE"
python3.11 -m compileall -q routeros tests
python3.11 -m unittest discover -s tests -q
\`\`\`

При внедрении были успешно выполнены **121 offline-тест**. Вывод тестовых заглушек может содержать строки \`CREATE ...\` для Zabbix — это не свидетельствует о записи в продуктивный Zabbix. Реальные маршрутизатор и NetBox тестами не менялись.

Фиксация commit SHA обеспечивает воспроизводимость версии, но не заменяет проверку доверия к GitHub, состава архива и требований вашей цепочки поставки ПО.

## 03 / Сначала параллельный аудит, затем shadow exporter

Новая версия запускалась независимо от действующего systemd-unit:

\`\`\`bash
cd "/opt/netbox-inventory-toolkit-REVIEWED_SHA"
python3.11 -m routeros.run_local_audit \
  --config /etc/netbox-inventory/routeros-ipam.json
echo "Audit RC: $?"
\`\`\`

Конфиг \`/etc/netbox-inventory/routeros-ipam.json\` создаётся по [безопасному примеру](https://github.com/greksw/netbox-inventory-toolkit/blob/main/examples/routeros-ipam.json.example). До запуска проверьте \`stat\`, владельца и отсутствие прав доступа для группы и остальных пользователей; не публикуйте содержимое.

Только после \`CLEAN\` и подтверждения утверждённого baseline проверяется экспортёр в **отдельной временной директории**, не в боевом textfile collector:

\`\`\`bash
TMP_METRICS="$(mktemp -d /root/ipam-shadow.XXXXXX)"
cd "/opt/netbox-inventory-toolkit-REVIEWED_SHA"
python3.11 -m routeros.textfile_export --output-dir "$TMP_METRICS"
grep -E '^netbox_routeros_ipam_audit_(status|differences) ' \
  "$TMP_METRICS/netbox-routeros-ipam.prom"
# После сравнения результатов убрать временный каталог.
\`\`\`

Сверяются не только два нулевых значения, но и счётчики VLAN, статических/динамических IPv4 и свежесть timestamp. У универсального экспортёра отдельные метрики количества получили новые суффиксы (\`_static_ipv4\` вместо старых локальных \`_static_ips\`), поэтому проверять нужно **смысл и значения**, а не буквальное совпадение всех имён.

Ключевые метрики, использованные существующими алертами, сохранились:

\`\`\`text
netbox_routeros_ipam_audit_status
netbox_routeros_ipam_audit_differences
netbox_routeros_ipam_audit_timestamp_seconds
\`\`\`

Экспортёр атомарно заменяет один \`.prom\`-файл. Публичные числовые метрики получают права \`0644\` для чтения непривилегированным \`node_exporter\`; закрытые ключи, конфиг и токен остаются \`0600\`. Для SELinux необходимо сохранить корректный контекст каталога.

## 04 / Переключение через systemd drop-in

Исходный unit **не редактировался**. Перед переключением сохранены копии его конфигурации, действующего \`.prom\` и текущего \`systemctl cat\`. Для новой версии создан отдельный drop-in:

\`\`\`ini
# /etc/systemd/system/netbox-routeros-ipam.service.d/90-universal-exporter.conf
[Service]
WorkingDirectory=/opt/netbox-inventory-toolkit-REVIEWED_SHA
ExecStart=
ExecStart=/usr/bin/python3.11 -m routeros.textfile_export --output-dir /var/lib/node_exporter/textfile_collector
SuccessExitStatus=1
\`\`\`

Пустая строка \`ExecStart=\` очищает исходную команду, следующая задаёт новую. \`SuccessExitStatus=1\` разрешает трактовать \`DRIFT\` как **завершённую проверку с найденным отклонением**, не как технический сбой unit. В Prometheus при этом остаётся статус \`1\`; код \`2\` является ошибкой.

После \`systemd-analyze verify\` и \`daemon-reload\` был сделан **один контролируемый ручной запуск** oneshot-service. Проверялись \`Result=success\`, \`ExecMainStatus=0\`, эффективный \`WorkingDirectory\`, права \`.prom\`, \`node_textfile_scrape_error=0\` и реальные метрики Node Exporter.

Откат не требует переписывать весь unit: удалить **только добавленный drop-in**, выполнить \`systemctl daemon-reload\` и запустить прежний сервис. Делать это следует по подготовленному внутреннему плану и с сохранённой копией конфигурации. Не стирайте другие drop-in-файлы.

## 05 / Важнее ручного запуска — проверка на следующий день

Успешный \`systemctl start\` доказывает лишь разовый запуск. Для завершения миграции необходим независимый **первый запуск по расписанию**.

В проверенном случае он состоялся **22 октября 2026 года**: systemd завершил oneshot с кодом \`0\`, журнал зафиксировал \`ROUTEROS IPAM METRICS: CLEAN\`, \`Differences: 0\`; дата модификации файла метрик совпала с временем запуска. Prometheus получил новое значение \`audit_timestamp_seconds\`, Node Exporter не сообщил ошибок.

Универсальный read-only чек-лист:

\`\`\`bash
systemctl list-timers --all netbox-routeros-ipam.timer
systemctl show netbox-routeros-ipam.service \
  -p Result -p ExecMainStatus -p WorkingDirectory
journalctl -u netbox-routeros-ipam.service --since today --no-pager
stat -c '%y %a %U:%G' \
  /var/lib/node_exporter/textfile_collector/netbox-routeros-ipam.prom
\`\`\`

В Prometheus проверялись \`up == 1\`, \`node_textfile_scrape_error == 0\`, \`netbox_routeros_ipam_audit_status == 0\`, ноль расхождений и свежий timestamp. Все четыре правила — \`Drift\`, \`AuditError\`, \`AuditStale\`, \`AuditMissing\` — имели \`state=inactive\` и \`health=ok\`.

При проверке сразу после перезагрузки Prometheus новые правила могут временно иметь \`state=unknown\`/\`health=unknown\` до первой оценки. Это ещё не ошибка: необходимо дождаться установленного \`evaluation_interval\` и перепроверить \`/api/v1/rules?type=alert\`.

## 06 / Что не считается проверенным

- Путь Alertmanager до receiver был проверен командой \`amtool config routes test\`; это **не является сквозным тестом доставки** конкретного IPAM-уведомления. Успешные исторические email/webhook-метрики говорят лишь о предыдущих отправках.
- Один динамический IKEv2/IPsec Mode Config IPv4 был включён в **точечное вручную согласованное исключение**. Аудитор проверяет его наличие, но не доказывает в каждом цикле связь с активным IPsec peer, policy и NAT.
- Это мониторинг расхождений, а не полноценная CMDB-синхронизация и не инструмент автоматического исправления RouterOS.

## Результат

Миграция прошла как \`предварительные тесты → фиксированная версия → параллельная сверка → shadow metrics → systemd drop-in → проверка Prometheus → первый независимый запуск по расписанию\`.

Таким образом, публикация универсального исходного кода на GitHub не стала отдельным рисковым «большим обновлением» production: работающий аудит был сохранён до доказанного совпадения результатов новой реализации.

Связанные материалы: [read-only IPAM-аудит](/ru/notes/monitoring/routeros-netbox-ipam-drift-ssh-readonly/), [Prometheus/Alertmanager](/ru/notes/monitoring/routeros-netbox-ipam-prometheus-alerting/) и [публичная документация live rollout](https://github.com/greksw/netbox-inventory-toolkit/blob/main/docs/routeros-ipam-live-monitoring.md).
