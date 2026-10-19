---
title: "Proxmox ↔ NetBox Drift Detection: systemd, HTTPS API и Zabbix 7.0"
description: "Практическая организация ежедневной read-only сверки Proxmox с NetBox 4.7: TLS CA, API-токен без записи, systemd timer, отдельные безопасные метрики и четыре триггера Zabbix."
category: "Мониторинг и безопасность"
tags: ["proxmox", "netbox", "drift-detection", "zabbix", "systemd", "tls", "python", "monitoring", "automation"]
published: 2026-10-19
updated: 2026-10-19
status: current
testedOn: ["NetBox 4.7.3", "Zabbix Server 7.0.31", "Zabbix Agent 7.0.22", "Proxmox VE", "systemd"]
featured: false
lang: ru
translationKey: "monitoring/proxmox-netbox-drift-audit-zabbix"
---

## От разовой инвентаризации к обнаружению расхождений

После [сбора DMI, MAC и сетевой топологии Proxmox](/ru/notes/proxmox/proxmox-netbox-hardware-inventory/) данные в NetBox были приведены в соответствие с реальным кластером. Однако разовый импорт не гарантирует актуальность: интерфейс можно переименовать, оборудование заменить, часть узлов перестанет отвечать, а аудит — вообще не запуститься.

В октябре 2026 года внедрён **ежедневный read-only Drift Audit**. Он сравнивает актуальное состояние девяти гипервизоров с NetBox, сохраняет результат локально и отдаёт Zabbix **три целочисленные метрики**. Сам NetBox инструментом аудита **никогда не изменяется**.

Исходники: [netbox-inventory-toolkit](https://github.com/greksw/netbox-inventory-toolkit). Реальные сетевые адреса, домены, hostnames и значения секретов в примерах заменены демонстрационными.

## 01 / Контур безопасности и архитектура

```text
Proxmox host: pvesh + read-only SSH to cluster peers
                     │
                     ▼
         daily drift_audit.py
          │                   │
          │                   └── HTTPS GET → NetBox 4.7 API
          ▼
     private JSON 0600
          │
          └── systemd ExecStopPost → sanitized metrics.json
                                      (root:zabbix, 0640)
                                                  │
                                           Zabbix Agent
                                                  │ TLS PSK, passive checks
                                                  ▼
                                             Zabbix Server
                                             4 alert triggers
```

Права разделены: `root` получает инвентаризацию, а пользователь `zabbix` видит только числа. Приватный JSON и файл с NetBox API-токеном недоступны агенту. У Zabbix нет доступа к Django ORM или возможности менять NetBox.

Сервер NetBox использует доверенный корпоративный CA; клиент проверяет сертификат, без `verify=False` или `curl -k`.

## 02 / Проверка API без права записи

Для NetBox 4.7 создаём **отдельный API v2 token** с разрешениями просмотра `Device` и `Interface`, отключённым флажком **Write enabled** и, по возможности, ограничением по исходному IP. На гипервизоре конфигурация хранится вне репозитория:

```ini
# /etc/netbox-inventory/drift.env — mode 0600, root:root
NETBOX_URL=https://netbox.example.net
NETBOX_TOKEN=nbt_EXAMPLE_ID.EXAMPLE_SECRET
NETBOX_CA_FILE=/etc/netbox-inventory/ca.pem
```

Пример содержит **заглушку**, не рабочий токен. Публичный CA-файл переносится по доверенному административному каналу; приватный ключ CA передавать нельзя.

```bash
curl --cacert /etc/netbox-inventory/ca.pem \
  -I https://netbox.example.net/
```

Возврат `302` на страницу логина после успешной TLS-проверки допустим: веб-страница без cookie переадресует пользователя. Это не заменяет проверку прав API-токена при первом аудите.

## 03 / Dry-run, затем свежий сбор

Первый запуск проверяли на уже снятом и сверенном снимке, чтобы отдельно протестировать NetBox API:

```bash
cd /root/netbox-inventory-toolkit
set -a
. /etc/netbox-inventory/drift.env
set +a

python3 netbox/drift_audit.py \
  --inventory output/proxmox-inventory-v03.json \
  --output-dir /var/lib/netbox-inventory \
  --site-slug example-office \
  --role-slug hypervisor \
  --expected-nodes 9

unset NETBOX_TOKEN
```

Затем выполнили **живую проверку**, уже без параметра `--inventory`: скрипт сам обращается к `pvesh` и доверенному SSH на узлах.

```bash
python3 netbox/drift_audit.py \
  --output-dir /var/lib/netbox-inventory \
  --cluster-label example-pve \
  --site-slug example-office \
  --role-slug hypervisor \
  --expected-nodes 9
```

Оба варианта вернули:

```text
STATUS: CLEAN
devices_checked: 9
interfaces_source: 362
interfaces_netbox: 362
physical_macs_checked: 20
serials_checked: 7
differences: 0
```

**Коды выхода:** `0` — совпадение; `1` — найдены расхождения; `2` — ошибка сбора, API или формата данных. Код `2` нельзя интерпретировать как «расхождений нет».

Проверяются устройства, имена интерфейсов, доступные DMI-серийники и текущие MAC физических NIC. Не следует приписывать этому аудиту проверку конфигураций всех VM, физических кабелей или связности VLAN.

## 04 / Ежедневный systemd timer

В репозитории есть образцы `deploy/systemd/netbox-inventory-drift.service` и `.timer`. Пути к файлам, site slug и имя роли адаптируйте к своему окружению. Служба запускается однократно и читает закрытый `EnvironmentFile`.

```bash
install -m 0644 deploy/systemd/netbox-inventory-drift.service \
  /etc/systemd/system/
install -m 0644 deploy/systemd/netbox-inventory-drift.timer \
  /etc/systemd/system/
systemctl daemon-reload

systemd-analyze verify /etc/systemd/system/netbox-inventory-drift.service
systemctl start netbox-inventory-drift.service
journalctl -u netbox-inventory-drift.service -n 30 --no-pager

systemctl enable --now netbox-inventory-drift.timer
systemctl list-timers --all netbox-inventory-drift.timer
```

Проверенное расписание: **ежедневно около 05:10**, рандомизированная задержка до 20 минут, `Persistent=true` для пропущенного запуска. В работе наблюдали успешный запуск службы и планирование следующего запуска на утро следующего дня.

Обратите внимание на `SuccessExitStatus=1`: systemd воспринимает завершённый аудит с обнаруженными изменениями как *выполненную проверку*, а не ошибку запуска. Поэтому сам статус службы не подходит для мониторинга расхождений.

## 05 / Как безопасно отдать результат Zabbix

Файлы `source-latest.json` и `drift-latest.json` остаются `0600 root:root`. Не нужно делать их доступными пользователю `zabbix`.

`netbox/zabbix_bridge.py` вызывается через `ExecStopPost` и атомарно пишет только три показателя в отдельный файл `root:zabbix 0640`:

| Key | Смысл |
| --- | --- |
| `netbox.audit.status` | `0` CLEAN, `1` DRIFT, `2` ERROR |
| `netbox.audit.differences` | Число расхождений; при ERROR не показатель отсутствия drift |
| `netbox.audit.timestamp` | Unix timestamp последней попытки аудита |

Шаблон `deploy/zabbix/netbox-inventory-drift.conf` задаёт `UserParameter` для обычного **пассивного Zabbix Agent**. При отказе самого аудита мост экспортирует `status=2`, а не старое успешное значение.

```bash
zabbix_agentd -t netbox.audit.status
zabbix_agentd -t netbox.audit.differences
zabbix_agentd -t netbox.audit.timestamp
```

В реальной проверке получены `0`, `0`, корректный Unix timestamp; файл метрик имел права `640 root:zabbix`.

## 06 / TLS PSK и четыре триггера

Для пассивного опроса сервер должен обращаться к `zabbix-agent` на порту 10050. Когда в агенте стоит `TLSAccept=psk`, обычный `zabbix_get` **без PSK** получает отказ `unencrypted connections are not allowed`. Это не неисправность UserParameter. В Zabbix для хоста должны совпадать PSK Identity и PSK, а тип трёх items должен быть именно **Zabbix agent**, не `Zabbix agent (active)`.

Созданы четыре триггера в шаблоне (техническое имя шаблона в примере — `Template NetBox Inventory Drift`):

```text
last(/Template NetBox Inventory Drift/netbox.audit.status)=1
last(/Template NetBox Inventory Drift/netbox.audit.status)=2
now()-last(/Template NetBox Inventory Drift/netbox.audit.timestamp)>93600
nodata(/Template NetBox Inventory Drift/netbox.audit.status,15m)=1
```

Уровни: **Warning / High / Average / Average**, соответственно. Тег всех событий: `component=netbox-drift`. После внедрения Zabbix показывал **4/4 включённых триггера, все в OK**, а три метрики поступали каждые пять минут.

Чтобы создать триггеры через API, предусмотрен `zabbix/configure_template_api.py` с dry-run по умолчанию и явным `--apply`. Важная особенность Zabbix API: `trigger.get` без `expandExpression=true` может вернуть `{functionid}` вместо исходного выражения. Посимвольное сравнение таких строк породило ложные конфликты после успешного создания; исправленный скрипт использует `expandExpression` и повторно обнаруживает существующие четыре триггера без дубликатов.

## 07 / Где заканчивается текущая реализация

**Zabbix здесь контролирует состояние, но отдельные Trigger actions для этого кейса намеренно не включали.** В инфраструктуре уже используется Grafana/Prometheus/Loki для централизованных оповещений; дублировать их в Zabbix решили не делать. Экспорт трёх показателей в Prometheus и правило Grafana Alerting — возможный следующий этап, **пока не заявленный как внедрённый**.

Проверенный результат — read-only ежедневный аудит, защищённый экспорт трёх метрик, четыре корректно работающих триггера и отсутствие расхождений на момент теста. Это не означает, что доставка уведомлений Zabbix уже настроена.

### Ссылки

- [NetBox Inventory Toolkit — collector, drift audit, Zabbix bridge и CLI](https://github.com/greksw/netbox-inventory-toolkit)
- [Инвентаризация DMI/MAC Proxmox в NetBox](/ru/notes/proxmox/proxmox-netbox-hardware-inventory/)
- [Мониторинг Proxmox через API и доверенный CA](/ru/notes/monitoring/proxmox-prometheus-api-ca/)
