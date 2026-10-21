---
title: "RouterOS и NetBox: безопасный read-only IPAM drift-аудит через SSH и API"
description: "Практика автоматической сверки VLAN, Prefix и IPv4 интерфейсов MikroTik RouterOS 7 с NetBox 4.7: SSH, Python, read-only API, контроль неполных данных и исключений IPsec."
category: "Мониторинг и безопасность"
tags: ["mikrotik", "routeros", "netbox", "ipam", "ssh", "python", "drift-detection", "network-automation", "security"]
published: 2026-10-21
updated: 2026-10-21
status: current
testedOn: ["MikroTik RouterOS 7", "NetBox 4.7.3", "Python 3.11", "OpenSSH", "AlmaLinux 9", "systemd"]
featured: false
lang: ru
translationKey: "monitoring/routeros-netbox-ipam-drift-ssh-readonly"
---

## Задача: знать не только что записано в IPAM, но и что работает на маршрутизаторе

NetBox удобен как источник описания сетевой инфраструктуры: устройств, интерфейсов, VLAN, Prefix и назначенных IP-адресов. Однако наличие записи в IPAM не гарантирует, что конфигурация маршрутизатора совпадает с документацией. Изменение VLAN, перенос IP на другой интерфейс или новая динамическая адресация могут остаться незамеченными.

В эксплуатационном сценарии реализован **read-only аудит MikroTik RouterOS 7 ↔ NetBox 4.7**. Система обнаруживает отклонения, но **не пытается автоматически исправлять конфигурацию**. Сначала был проверен ручной сбор каждого источника, затем строгое сравнение и отдельно — способ классифицировать динамический адрес IKEv2/IPsec.

Все адреса, имена, VLAN ID и численные значения в примерах ниже **вымышлены**. Реальные идентификаторы площадок, токены, SSH-ключи, схемы VPN и конфигурации устройств не публикуются.

**Код сравнения и адаптеры:** [NetBox Inventory Toolkit](https://github.com/greksw/netbox-inventory-toolkit), [PR с RouterOS IPAM Audit](https://github.com/greksw/netbox-inventory-toolkit/pull/16). В указанном PR находится библиотечная часть; локальные эксплуатационные обвязки не следует считать опубликованным универсальным установщиком.

## 01 / Архитектура и границы доверия

```text
MikroTik RouterOS 7                           NetBox 4.7
  SSH, dedicated read-only account             HTTPS GET, token v2 (write disabled)
  pinned SSH host key                          trusted private CA
           |                                          |
           v                                          v
  RouterOSSSHReader                            NetBoxReader
    /interface vlan                              Device / Interface
    /ip address                                  VLAN / Prefix / IPAddress
           |                                          |
           +----------------+-------------------------+
                            v
                   Python snapshot normalize
                            v
                    IPAM compare (read-only)
                            |
                 CLEAN / DRIFT / ERROR
```

SSH-аудитор использует отдельную учётную запись RouterOS с минимальной группой `ssh,read` и ограничением по IP-адресу узла мониторинга. В отличие от группы со стандартными расширенными правами, такая запись не должна иметь `write`, `policy`, `sensitive` и возможности вносить изменения. Клиент использует выделенный приватный ключ, `IdentitiesOnly=yes`, `BatchMode=yes`, `StrictHostKeyChecking=yes`, заранее проверенный `known_hosts` и отключённое перенаправление SSH-агента.

Для NetBox применяется отдельная техническая учётная запись с правами **только просмотра** `Device`, `Interface`, `VLAN`, `Prefix` и `IPAddress`. API Token v2 создаётся с `Write enabled = off`; по возможности ограничивается исходным IP и сроком действия. HTTPS проверяется по доверенному CA, без `verify=False` или `curl -k`.

## 02 / Как именно собираются данные RouterOS

Не требуется открывать RouterOS `www-ssl` или включать HTTP REST API. Два заранее разрешённых SSH-запроса сериализуют вывод RouterOS в JSON:

```routeros
:put [:serialize to=json value=[/interface vlan print as-value] options=json.no-string-conversion]
:put [:serialize to=json value=[/ip address print as-value] options=json.no-string-conversion]
```

В `routeros/ssh_source.py` эти команды жёстко заданы. Клиент не принимает произвольную команду от вызывающего кода. Ответ проверяется как массив JSON; сетевые ошибки, некорректный формат и чрезмерный объём данных приводят к `ERROR`.

Из RouterOS извлекаются VLAN ID, имя и родительский интерфейс VLAN, флаг `disabled`, а также CIDR-адрес, интерфейс и флаги `dynamic`/`disabled` IPv4. **Сырые ответы не нужно выводить в Prometheus, логи или публичный CI:** они раскрывают внутреннюю топологию.

## 03 / Читаем NetBox через HTTPS GET

Адаптер NetBox проверяет идентичность маршрутизатора по имени, площадке и роли `router`, после чего читает интерфейсы, VLAN-группу, связанные префиксы и назначенные интерфейсам IP-адреса. Доступны только заранее разрешённые GET-endpoints:

```text
/api/dcim/devices/
/api/dcim/interfaces/
/api/ipam/vlans/
/api/ipam/prefixes/
/api/ipam/ip-addresses/
```

Запросы учитывают пагинацию, а итоговые выборки проверяются на полноту. Это принципиально: ошибка API или отсутствие части объектов не должны случайно превращаться в «нулевое расхождение».

## 04 / Что сравнивается, а что пока не сравнивается

Аудитор проверяет **не только количество объектов**:

| Область | Инвариант |
|---|---|
| VLAN | Набор VLAN ID RouterOS соответствует набору VLAN ID выбранной группы NetBox |
| Prefix | Для каждого VLAN сравнивается подсеть активного статического адреса VLAN-интерфейса с Prefix в NetBox |
| IPv4 | Точное совпадение пар `(CIDR, interface)` для активных статических адресов |
| Качество данных | Повторяющиеся записи, неверные типы, повреждённый или устаревший snapshot не принимаются |
| Полнота | Количество объектов сверяется с заранее согласованным baseline |
| Динамика | Неожиданные динамические и отключённые адреса требуют рассмотрения |

При этом действующий алгоритм **не сравнивает** все поля RouterOS, например bridge VLAN filtering, PVID, trunk/access-порты, маршруты, VRF, DHCP или фактическое состояние VPN. Имя родительского интерфейса VLAN валидируется, но не является самостоятельным инвариантом сравнения с NetBox. Модель рассчитана на один ожидаемый Prefix для каждого выбранного VLAN.

Важная деталь классификации: **расхождение с утверждённым количеством VLAN или статических IP — `ERROR` (недостаточная достоверность baseline), а не `DRIFT`**. Точные несовпадения записей при корректной полноте дают `DRIFT`.

## 05 / Пример вызова Python API

Ниже — **адаптируемый фрагмент**, а не скрипт, который можно применять без настройки. Используются исключительно адреса из диапазонов документации. Код предполагает наличие модулей из PR и уже подготовленных приватных файлов ключа, токена, `known_hosts` и сертификата CA.

```python
from pathlib import Path
from routeros.ssh_source import RouterOSSSHReader
from routeros.ipam_sources import (
    NetBoxReader, routeros_snapshot, netbox_snapshot,
)
from routeros.ipam_audit import compare

router = RouterOSSSHReader(
    host="192.0.2.1", username="audit",
    identity_file="/etc/ipam-audit/routeros.key",
    known_hosts_file="/etc/ipam-audit/known_hosts",
)
ros = routeros_snapshot(router)

netbox = NetBoxReader(
    origin="https://netbox.example.net",
    token=Path("/etc/ipam-audit/netbox.token").read_text().strip(),
    ca_file="/etc/ipam-audit/trusted-ca.pem",
)
nb = netbox_snapshot(
    netbox, router_name="edge-router-01",
    site_slug="office", vlan_group_slug="office-vlans",
)

result = compare(
    ros, nb,
    expected_vlans=8,
    expected_static_addresses=12,
)
print(result["status"], result["differences"], result["categories"])
```

`8` и `12` — **условные значения**: их заменяют утверждёнными параметрами конкретной инфраструктуры. Секреты запрещено помещать в Git, командную строку и журналы. Любая ошибка сбора или проверки схемы должна завершаться кодом `2`, а не `0`.

## 06 / Динамический IPsec Mode Config: почему нельзя игнорировать весь dynamic

В реальной проверке был обнаружен один `dynamic=true` IPv4, добавленный в runtime RouterOS. Строгий аудит корректно сообщал `DRIFT` с категорией `dynamic_review_required`. При расследовании выяснилось, что такой адрес может быть связан с клиентским **IKEv2 Mode Config**, а не с DHCP.

Перед согласованием исключения оператор независимо проверяет идентичность IPsec peer/identity, активную Phase 2, динамическую policy с соответствующим host-IP и динамический NAT `ipsec mode-config` с корректной connection mark. IP-адрес и интерфейс фиксируются как **точечное рассмотренное исключение**. Если они меняются или исчезают, аудит снова покажет отклонение.

```python
result = compare(
    ros, nb,
    expected_vlans=8,
    expected_static_addresses=12,
    approved_dynamic=(("198.51.100.10/24", "wan1"),),
)
```

Это **условный пример после ручного подтверждения**. Текущие snapshots не содержат достаточных данных IPsec policy/NAT, поэтому **сам Python-аудитор пока не перепроверяет происхождение адреса при каждом запуске**. Исключение нельзя трактовать как автоматическую проверку IPsec, и не следует одобрять все `dynamic` подряд.

## 07 / Интерпретация итогов

| Код | Статус | Что означает |
|---|---|---|
| `0` | `CLEAN` | Данные полны; сравниваемые инварианты совпали; рассмотренные исключения учтены |
| `1` | `DRIFT` | Есть конкретные расхождения или неожиданные runtime-адреса |
| `2` | `ERROR` | Сбой связи, повреждённая/устаревшая выборка, несогласованная полнота или ошибка проверки |

Положительный результат означает совпадение **в пределах описанной модели**, а не полное равенство конфигураций RouterOS и NetBox. Система не меняет маршрутизатор и не выполняет автосинхронизацию IPAM.

## Результат и продолжение

Read-only сверка была успешно пройдена вручную, затем вынесена в локальную команду аудитора. Следующий уровень — регулярное выполнение и мониторинг результата через Prometheus. Его разбираем отдельно: [IPAM-аудит в Prometheus: Textfile Collector, systemd и Alertmanager](/ru/notes/monitoring/routeros-netbox-ipam-prometheus-alerting/).

**Практический вывод:** надёжный IPAM drift detection начинается не с автоматического исправления сетевой конфигурации, а с проверяемого baseline, узких прав на чтение и явного разделения `CLEAN`, `DRIFT` и `ERROR`.