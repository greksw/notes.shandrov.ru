---
title: "MikroTik RouterOS 7: Multi-WAN, маршрутизация по политикам и отказоустойчивость VLAN"
description: "Практическая схема распределения VLAN по предпочтительным uplink с управляемым failover и проверяемым выходом в Internet."
category: "Сети"
tags: ["mikrotik", "routeros", "multi-wan", "policy-routing", "failover", "vlan"]
published: 2026-09-16
updated: 2026-09-16
status: current
testedOn: ["RouterOS 7.x", "MikroTik RB5009 / CCR class", "multi-VLAN edge routing"]
featured: true
lang: ru
translationKey: "networking/mikrotik-routeros7-multiwan-policy-routing"
---

## Контекст

Multi-WAN становится сложным в эксплуатации, когда политика резервирования не выражена явно. Через несколько месяцев уже трудно ответить:

- какой uplink предпочитает конкретный VLAN;
- через какого провайдера он должен выйти при отказе основного канала;
- должны ли административные сети использовать отдельный резерв;
- как доказать, через какого провайдера реально выходит конкретный host.

Практичный подход — выразить это через отдельные routing tables и `/routing/rule`, чтобы намерение было видно непосредственно в конфигурации.

## Пример политики

Пусть есть три uplink:

| Uplink | Роль |
| --- | --- |
| `WAN_A` | основной провайдер |
| `WAN_B` | общий резерв |
| `WAN_C` | отдельный резерв для выбранных VLAN |

И три группы сетей:

| Сеть | Предпочитаемый путь |
| --- | --- |
| пользовательские VLAN | `WAN_A` → `WAN_B` |
| административные VLAN | `WAN_A` → `WAN_C` |
| сервисные VLAN | `WAN_A` → `WAN_C` |

Смысл в том, чтобы политика читалась из конфигурации, а не восстанавливалась по NAT counters и connection tracking.

## Routing tables в RouterOS 7

Пользовательские таблицы нужно объявлять явно:

```routeros
/routing/table
add name=rt_wan_ab fib
add name=rt_wan_ac fib
```

Для простого source-based steering `/routing/rule` обычно понятнее mangle. Mangle имеет смысл, когда классификация сложнее: protocol/port, connection marking, PCC и другие условия.

Не держите два независимых механизма policy routing без явной причины.

## Default routes в policy tables

Таблица `WAN_A → WAN_B`:

```routeros
/ip/route
add dst-address=0.0.0.0/0 gateway=198.51.100.1@main \
    routing-table=rt_wan_ab distance=1 check-gateway=ping
add dst-address=0.0.0.0/0 gateway=203.0.113.1@main \
    routing-table=rt_wan_ab distance=2 check-gateway=ping
```

Таблица `WAN_A → WAN_C`:

```routeros
/ip/route
add dst-address=0.0.0.0/0 gateway=198.51.100.1@main \
    routing-table=rt_wan_ac distance=1 check-gateway=ping
add dst-address=0.0.0.0/0 gateway=192.0.2.1@main \
    routing-table=rt_wan_ac distance=2 check-gateway=ping
```

Суффикс `@main` важен, когда next hop разрешается через main table. Пользовательская таблица не должна существовать в отрыве от корректной основной таблицы маршрутизации.

## Main table должна оставаться рабочей

Сам router тоже должен иметь предсказуемый default route.

```routeros
/ip/route
add dst-address=0.0.0.0/0 gateway=198.51.100.1 distance=1 check-gateway=ping
add dst-address=0.0.0.0/0 gateway=203.0.113.1 distance=2 check-gateway=ping
```

Не ломайте main table ради попытки сделать policy tables «самодостаточными».

## Сначала защитите внутреннюю маршрутизацию

Source-based rule, указывающее в таблицу с default route, может случайно перехватить внутренний трафик.

Поэтому внутренние назначения обрабатываются раньше:

```routeros
/routing/rule
add dst-address=10.0.0.0/8 action=lookup table=main
add dst-address=172.16.0.0/12 action=lookup table=main
add dst-address=192.168.0.0/16 action=lookup table=main
```

В реальной инфраструктуре лучше использовать фактические, более узкие префиксы.

## Сопоставьте VLAN с routing tables

Пользовательские сети:

```routeros
/routing/rule
add src-address=10.20.10.0/24 action=lookup table=rt_wan_ab
add src-address=10.20.11.0/24 action=lookup table=rt_wan_ab
```

Административные и сервисные сети:

```routeros
/routing/rule
add src-address=10.20.90.0/24 action=lookup table=rt_wan_ac
add src-address=10.20.91.0/24 action=lookup table=rt_wan_ac
```

`action=lookup` допускает продолжение поиска, если выбранная таблица не нашла маршрут. `lookup-only-in-table` создаёт более жёсткую границу и подходит для fail-closed поведения.

Выбирайте это сознательно.

## NAT должен соответствовать выбранному uplink

Routing и NAT — разные подсистемы. Можно выбрать правильный маршрут и всё равно потерять Internet access, если srcnat не соответствует фактическому egress interface.

Для простого случая удобно использовать interface list:

```routeros
/interface/list
add name=WAN
/interface/list/member
add list=WAN interface=ether1
add list=WAN interface=ether2
add list=WAN interface=ether3

/ip/firewall/nat
add chain=srcnat out-interface-list=WAN action=masquerade
```

Если используются статические публичные адреса или provider-specific srcnat, оставляйте правила явными.

## `check-gateway=ping` не проверяет весь Internet

Ping gateway проверяет только next hop. Провайдер может отвечать на gateway, но иметь проблемы дальше по сети.

Если такой failure mode важен, используйте более сильную health-check схему: recursive routes, Netwatch, внешние probes или другой контролируемый механизм.

Не усложняйте failover без необходимости. Простая понятная схема лучше сложной цепочки, смысл которой теряется через полгода.

## Проверяйте routing tables напрямую

```routeros
/ip/route/print detail where routing-table=rt_wan_ab
/ip/route/print detail where routing-table=rt_wan_ac
/routing/rule/print detail
```

В normal state должен быть активен основной route, а backup должен оставаться доступным с ожидаемым distance.

Порядок routing rules — часть политики. Правила для внутренних destination должны стоять раньше общих source rules.

## Проверяйте с реального host

Главная проверка — фактический выход в Internet с host внутри нужного VLAN.

Например:

```bash
curl -4 https://ifconfig.me
```

Проверяйте минимум три состояния:

1. все uplink исправны;
2. основной uplink недоступен;
3. основной uplink восстановлен.

Host должен перейти на ожидаемый backup и затем вернуться на preferred uplink.

Так выявляются ошибки, которые не видны только по route flags: неверный NAT, старые connections и лишние policy matches.

## Existing connections при failover

Failover не гарантирует сохранение уже установленных TCP sessions. При смене провайдера обычно меняется публичный source address.

Нормальная модель для простого NAT failover:

- новые соединения идут через backup;
- старые могут потребовать reconnect;
- после восстановления primary новые соединения возвращаются на preferred path.

Это не application-level HA.

## Тестируйте отказ по одному uplink

При commissioning отключайте один WAN за раз и проверяйте route state:

```routeros
/ip/route/print where dst-address=0.0.0.0/0
```

Затем тестируйте host из каждой policy class.

Если `WAN_A` недоступен:

- пользовательские VLAN должны выйти через `WAN_B`;
- admin/service VLAN — через `WAN_C`;
- inter-VLAN и site-to-site трафик должен продолжать идти по внутренним маршрутам.

Если внутренний destination начал уходить через Internet provider, останавливайте rollout и исправляйте порядок routing rules.

## Failback

После возврата primary проверяйте новые соединения. Старые записи connection tracking могут продолжать жить на резервном пути до timeout.

Не оценивайте failback по одному старому TCP session.

## Troubleshooting

```routeros
/routing/rule/print detail
/ip/route/print detail
/routing/nexthop/print detail
/ip/firewall/nat/print stats
/ip/firewall/connection/print where src-address~"10.20."
```

Проверяйте по порядку:

- source попал в нужное rule;
- выбранная table разрешает default route;
- next hop доступен;
- NAT соответствует egress interface;
- старое connection tracking не удерживает предыдущий путь.

Не очищайте всю connection table как первый шаг на production-router.

## Routing rules и mangle

Routing rules хорошо подходят для политики по source subnet, destination и ingress interface.

Mangle нужен для более сложной классификации. Если mangle уже выставляет routing mark и маршрут разрешился, это может переопределить обычные routing rules.

Перед изменением модели проверяйте оба места:

```routeros
/ip/firewall/mangle/print detail
/routing/rule/print detail
```

Не оставляйте две независимые policy systems активными случайно.

## Change management

Безопасная последовательность:

1. создать routing tables;
2. добавить и проверить routes;
3. добавить internal-destination rules;
4. добавить одну source policy;
5. проверить один test host;
6. повторить для следующей группы VLAN;
7. протестировать failover и failback.

При удалённой работе держите Safe Mode доступным.

## Условия остановки

Останавливайте rollout, если:

- management traffic пошёл через неожиданный WAN;
- внутренний или site-to-site трафик захвачен Internet policy table;
- backup route не работает ещё до отключения primary;
- NAT не покрывает выбранный egress;
- DNS зависит только от одного provider path;
- routing table переключилась, а реальный host egress — нет;
- mangle и routing rules влияют на один поток без документированной причины.

Схема failover считается завершённой только после намеренного тестирования реального отказа.
