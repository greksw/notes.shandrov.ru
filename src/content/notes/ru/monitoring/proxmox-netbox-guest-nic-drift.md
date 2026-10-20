---
title: "Инвентаризация QEMU/LXC в NetBox: vNIC, безопасный импорт и ежедневный drift-аудит"
description: "Production-кейс: Python-сбор QEMU/LXC из Proxmox VE, VMInterface и MAC в NetBox 4.7, транзакционный импорт, systemd timer, Zabbix 7.0 и защита от ложных расхождений."
category: "Мониторинг и безопасность"
tags: ["proxmox", "netbox", "qemu", "lxc", "python", "virtualization", "zabbix", "systemd", "drift-detection", "automation"]
published: 2026-10-20
updated: 2026-10-20
status: current
testedOn: ["Proxmox VE", "NetBox 4.7.3", "Python 3", "PostgreSQL", "systemd", "Zabbix 7.0.31"]
featured: false
lang: ru
translationKey: "monitoring/proxmox-netbox-guest-nic-drift"
---

## Контекст: от инвентаризации оборудования к виртуальным машинам

В предыдущих материалах были разобраны [учёт физических узлов Proxmox и их сетевых интерфейсов](/ru/notes/proxmox/proxmox-netbox-hardware-inventory/) и [ежедневная read-only сверка оборудования с NetBox через Zabbix](/ru/notes/monitoring/proxmox-netbox-drift-audit-zabbix/). Следующий практический этап — перенести аналогичный контроль на **QEMU VM и LXC**.

Однократная регистрация виртуальной машины в NetBox не гарантирует актуальность её сетевых адаптеров, размещения, CPU/RAM и MAC. При этом слепо синхронизировать обнаруженные значения с NetBox опасно: у выключенных шаблонных VM могут намеренно сохраняться дубли MAC, а мост в конфигурации Proxmox не всегда является объектом, пригодным для прямой связи в модели NetBox.

В октябре 2026 года внедрён и проверен полный цикл: **сбор → preview → ручной review → Django dry-run → одобренный импорт → ежедневная сверка → Zabbix**. Описанная реализация эксплуатируется как механизм обнаружения расхождений, **не как система автоматического изменения VM**.

Исходный код и воспроизводимые образцы: [NetBox Inventory Toolkit](https://github.com/greksw/netbox-inventory-toolkit). [Краткий кейс для портфолио](https://shandrov.ru/projects/proxmox-netbox-inventory/) объясняет архитектуру и результат; здесь — технические решения и проверка.

## 01 / Архитектура и разделение прав

```text
Proxmox VE cluster
  pvesh GET: resources, QEMU/LXC configurations
        |
        v
  Python guest collector  → private JSON (0600)
        |
        +---- HTTPS GET, trusted CA, view-only token ----> NetBox 4.7 API
        |                                                    |
        v                                                    v
  Reviewed vNIC preview                           Existing VM + VMID mapping
        |
        +---- one-time approved Django ORM transaction → VMInterface + MAC
        |
        +---- independent daily guest drift audit -- HTTPS GET --+
                                                                  |
        private report (root-only)                                |
                  |                                               |
        systemd ExecStopPost → sanitized integers                 |
                  |                                               |
             Zabbix Agent → Zabbix Server: items + triggers <------+
```

Сборщик и ежедневный аудитор используют только `pvesh GET` и HTTPS `GET`. Для чтения NetBox используется отдельный токен без разрешений записи. **Разовый импорт** VMInterface — другой сценарий: он выполняется локально в Django NetBox с правами сервисного пользователя, после резервной копии и явного подтверждения.

Файлы инвентаризации и отчётов содержат внутренние идентификаторы, поэтому имеют права `0600` и не публикуются. Агент Zabbix получает лишь три целочисленные метрики через отдельный файл `root:zabbix 0640` — без конфигураций, токенов, MAC и VMID.

## 02 / Сбор QEMU/LXC на узле Proxmox

`collectors/proxmox_guests.py` читает реестр гостей и конфигурации каждого VM/CT, оставляя ограниченный набор полей: VMID, тип, узел, состояние питания, выделенные vCPU и RAM, `netN`, MAC, имя моста и явный VLAN tag, если он указан.

Скрипт не копирует полный конфиг гостя и не записывает диски, ключи доступа или пароли.

```bash
cd /root/netbox-inventory-toolkit

python3 collectors/proxmox_guests.py \
  --expected-guests YOUR_APPROVED_GUEST_COUNT \
  --cluster-label example-pve \
  --output output/proxmox-guests.json
```

`YOUR_APPROVED_GUEST_COUNT` нужно заменить согласованным количеством машин. Несовпадение — ошибка полноты, а не повод автоматически принять новый состав кластера. Приватный файл `output/` исключён из Git.

Уточнение: значение vCPU для QEMU отражает **настроенную максимальную CPU-топологию**, а не нагрузку процессора. Имя `vmbr*` относится к мосту *хоста Proxmox*. Присваивать его напрямую полю `VMInterface.bridge` в NetBox нельзя: семантика объектов различается.

## 03 / Preview и проверка идентичности NetBox

Сначала сверяем сохранённые виртуальные машины по пользовательскому полю `proxmox_vmid`. Дополнительно сравниваются тип QEMU/LXC, текущий узел размещения, состояние, CPU и RAM. Для vNIC проверяются имя, MAC и мост.

```bash
set -a
. /etc/netbox-inventory/drift.env
set +a

python3 netbox/preview_guest_nics.py \
  --inventory output/proxmox-guests.json \
  --cluster example-pve \
  --expected-guests YOUR_APPROVED_GUEST_COUNT \
  --output output/guest-nics-preview.json

unset NETBOX_TOKEN
```

В закрытом env-файле — `NETBOX_URL`, `NETBOX_TOKEN`, `NETBOX_CA_FILE`. Сертификат сервера проверяется через доверенный CA, TLS-проверка не отключается.

Превью создаёт список планируемых интерфейсов и явно показывает предупреждения. Два важных случая из эксплуатации:

- **Дубликат MAC у выключенного эталонного гостя и рабочей VM.** Обе VM остаются учтены, но для шаблона MAC удерживается без назначения в NetBox; рабочей машине MAC назначается. Не требуется менять исходную конфигурацию шаблона.
- **Ссылка на отсутствующий host bridge у выключенного шаблона.** Аудит отмечает ситуацию, но не создаёт bridge и не пытается угадать VLAN. Имя моста сохраняется текстом в описании VMInterface для дальнейшего review.

Эти исключения должны быть **одобрены человеком**, а не скрыты правилом «игнорировать все ошибки».

## 04 / Защищённый импорт VMInterface

Для применения используется `netbox/import_guest_nics.py` через `manage.py shell` на самом сервере NetBox 4.7. До операции выполняются проверяемый `pg_dump -Fc`, приватная передача preview с правами `0600`, контроль возраста отчёта и Django dry-run:

```python
# Фрагмент для NetBox Django shell.
# Значения cluster, количества и списка held_vmids согласуются локально.
from import_guest_nics import run

run(
    "/path/to/private/guest-nics-preview.json",
    cluster="example-pve",
    expected_vms=YOUR_VM_COUNT,
    expected_nics=YOUR_NIC_COUNT,
    expected_macs=YOUR_ASSIGNABLE_MAC_COUNT,
    held_vmids=(YOUR_STOPPED_TEMPLATE_VMID,),
    apply=False,
)
```

Это **иллюстративный фрагмент**, а не готовая команда: константы `YOUR_*` нужно определить в локальной среде; перед запуском импортируемый модуль должен быть доступен Python. Режим `apply=False` не создаёт объектов. Применение требует `apply=True` и отдельной строки подтверждения `APPLY_REVIEWED_GUEST_INTERFACES`, после сверки контрольных количеств и свежести данных. Модуль дополнительно проверяет текущее состояние ORM и выполняет изменения в одной транзакции `transaction.atomic()`.

Внедрение подтвердило создание виртуальных интерфейсов, назначение неконфликтующих MAC и сохранение одного документированного исключения. Затем отдельный Django-аудит проверил состояние объектов. **IPAM, VLAN, параметры VM и конфигурация Proxmox не изменялись.**

Важно: этот импортёр рассчитан на утверждённый начальный сценарий, где каждой VM соответствует одна vNIC. Это не универсальный непрерывный синхронизатор любых топологий; после появления дополнительных интерфейсов нужен новый review и расширение модели.

## 05 / Отдельный read-only аудит гостей

В отличие от импортёра, `netbox/audit_guest_nics.py` всегда работает **только на чтение**. Он повторно собирает состояние Proxmox и сравнивает NetBox API, включая пользовательские поля, CPU/RAM, имена vNIC, MAC и описания host bridge.

```bash
cd /root/netbox-inventory-toolkit

set -a
. /etc/netbox-inventory/drift.env
set +a

python3 netbox/audit_guest_nics.py \
  --cluster example-pve \
  --expected-guests YOUR_APPROVED_GUEST_COUNT \
  --held-vmid YOUR_STOPPED_TEMPLATE_VMID \
  --output-dir /var/lib/netbox-guest-audit

unset NETBOX_TOKEN
```

Коды выхода принципиально разделены: `0` — `CLEAN`, `1` — `DRIFT`, `2` — `ERROR`. Неудачный запрос API, повреждённый ответ или неполный сбор не должны превращаться в ложный `CLEAN`.

В выполненной приёмочной проверке наборы VMID, VMInterface, назначенных MAC и разрешённое исключение совпали, `differences=0`. Следующий автоматический запуск и искусственное срабатывание ошибок проверяются отдельно.

## 06 / systemd timer и Zabbix

Для гостей подготовлены **отдельные** unit-файлы `deploy/systemd/netbox-guest-drift.service` и `.timer`. Таймер оборудования от этого не зависит.

Переменные окружения записываются локально в защищённый файл, без конфиденциальных значений в Git:

```ini
# /etc/netbox-inventory/guest-audit.env (root:root 0600)
GUEST_CLUSTER=example-pve
GUEST_EXPECTED_GUESTS=YOUR_APPROVED_GUEST_COUNT
GUEST_HELD_VMID=YOUR_STOPPED_TEMPLATE_VMID
```

```bash
# После адаптации путей, настройки env и успешного ручного аудита:
systemctl daemon-reload
systemd-analyze verify /etc/systemd/system/netbox-guest-drift.service
systemctl start netbox-guest-drift.service
journalctl -u netbox-guest-drift.service -n 30 --no-pager

systemctl enable --now netbox-guest-drift.timer
systemctl list-timers --all netbox-guest-drift.timer
```

Пример расписания: каждый день в 05:45 с задержкой до 15 минут; аудит физического оборудования запускается раньше. `SuccessExitStatus=1` означает, что найденный drift — это завершённая проверка, а не ошибка запуска службы. **Определять «всё чисто» по одному `systemctl is-active` нельзя.**

Затем `netbox/zabbix_guest_bridge.py` через `ExecStopPost` экспортирует только три числа:

| Zabbix item | Значение |
| --- | --- |
| `netbox.guest.audit.status` | `0` CLEAN, `1` DRIFT, `2` ERROR |
| `netbox.guest.audit.differences` | Количество расхождений; при ERROR неизвестно |
| `netbox.guest.audit.timestamp` | Unix timestamp последней попытки аудита |

```bash
zabbix_agentd -t netbox.guest.audit.status
zabbix_agentd -t netbox.guest.audit.differences
zabbix_agentd -t netbox.guest.audit.timestamp
```

В Zabbix 7.0 шаблон создаётся через `zabbix/configure_guest_template_api.py`: сначала dry-run, затем явный `--apply`, после — повторная проверка `EXISTS`. Три пассивных numeric-unsigned items опрашиваются раз в пять минут; четыре триггера контролируют drift, error, устаревание отчёта свыше 26 часов и отсутствие опроса 15 минут.

Финальная проверка **Monitoring → Latest data** подтвердила серверный приём: статус `0`, расхождения `0`, корректное время аудита. Существующий аппаратный шаблон при этом сохранён.

## 07 / Границы решения и дальнейшая эксплуатация

- **Нет автоматического remediation.** При DRIFT инженер изучает разницу и отдельно решает, менять NetBox или реальную конфигурацию Proxmox.
- **Нет гарантии готового оповещения.** Zabbix items и triggers заведены, но проверка их реального срабатывания и маршрутизации уведомлений — самостоятельный этап. Actions в рамках проекта не включались.
- **Фиксированное контрольное количество VM.** Добавление нового гостя до обновления утверждённого baseline вызывает ERROR, чтобы новый объект не прошёл незамеченным.
- **Ограниченная модель.** Не проверяются сетевая доступность VLAN, IP внутри гостевой ОС, кабели, все параметры VM или полноценный жизненный цикл IPAM. Это предмет отдельных интеграций.

Для продления процесса важны регулярный просмотр результатов, управление контрольными исключениями, проверяемые резервные копии NetBox и review изменений через GitHub Actions.

### Связанные материалы

- [Проект в портфолио — Proxmox, NetBox и Zabbix](https://shandrov.ru/projects/proxmox-netbox-inventory/)
- [Исходники и тесты NetBox Inventory Toolkit](https://github.com/greksw/netbox-inventory-toolkit)
- [Инвентаризация оборудования Proxmox](/ru/notes/proxmox/proxmox-netbox-hardware-inventory/)
- [Ежедневный аудит физических узлов и Zabbix](/ru/notes/monitoring/proxmox-netbox-drift-audit-zabbix/)
