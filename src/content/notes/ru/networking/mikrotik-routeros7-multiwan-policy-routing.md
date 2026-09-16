---
title: "MikroTik RouterOS 7: multi-WAN policy routing и failover по VLAN"
description: "Production-подход к распределению разных VLAN по предпочитаемым uplink с управляемым failover и проверяемым egress path."
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

Multi-WAN становится сложным в эксплуатации, когда политика резервирования не выражена явно. Если все клиенты просто следуют main default route, через несколько месяцев уже трудно ответить на вопросы:

- какой uplink предпочитает конкретный VLAN;
- через какого провайдера он должен выйти при отказе primary;
- должны ли административные сети использовать другой backup;
- как доказать, через какого провайдера реально выходит конкретный host.

В этой схеме выбор WAN оформляется как явная routing policy: source networks сопоставляются отдельным routing tables, а в каждом table задан собственный порядок default routes.

## Пример политики

Предположим три uplink:

| Uplink | Роль |
| --- | --- |
| `WAN_A` | основной провайдер |
| `WAN_B` | общий резерв |
| `WAN_C` | отдельный резерв для выбранных VLAN |

И внутренние сети:

| Сеть | Предпочитаемый путь |
| --- | --- |
| пользовательские VLAN | `WAN_A` → `WAN_B` |
| admin VLAN | `WAN_A` → `WAN_C` |
| service VLAN | `WAN_A` → `WAN_C` |

Смысл в том, чтобы намерение читалось из конфигурации, а не восстанавливалось по NAT counters и connection tracking.

## Routing tables в RouterOS 7

Пользовательские таблицы нужно объявлять явно:

```routeros
/routing/table
add name=rt_wan_ab fib
add name=rt_wan_ac fib
```

Для простого source-based steering `/routing/rule` обычно понятнее mangle. Mangle нужен, когда условия сложнее: connection classification, protocol/port, per-connection routing и т.п.

Не смешивайте два механизма без явной причины.

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

Суффикс `@main` важен, когда next hop разрешается через main table. Custom table не должен существовать в отрыве от корректной main routing table.

## Main table должна оставаться рабочей

Router сам нуждается в предсказуемом default route, а custom tables зависят от разрешения next hop.

```routeros
/ip/route
add dst-address=0.0.0.0/0 gateway=198.51.100.1 distance=1 check-gateway=ping
add dst-address=0.0.0.0/0 gateway=203.0.113.1 distance=2 check-gateway=ping
```

Не ломайте main table ради попытки сделать policy tables «самодостаточными».

## Сначала защитите внутреннюю маршрутизацию

Source-based rule, указывающее в таблицу с default route, может случайно перехватить внутренний трафик.

Поэтому internal destinations обрабатываются раньше:

```routeros
/routing/rule
add dst-address=10.0.0.0/8 action=lookup table=main
add dst-address=172.16.0.0/12 action=lookup table=main
add dst-address=192.168.0.0/16 action=lookup table=main
```

В реальной инфраструктуре лучше использовать более узкие фактические префиксы.

## Сопоставьте VLAN с policy tables

Пользовательские сети:

```routeros
/routing/rule
add src-address=10.20.10.0/24 action=lookup table=rt_wan_ab
add src-address=10.20.11.0/24 action=lookup table=rt_wan_ab
```

Admin/service сети:

```routeros
/routing/rule
add src-address=10.20.90.0/24 action=lookup table=rt_wan_ac
add src-address=10.20.91.0/24 action=lookup table=rt_wan_ac
```

`action=lookup` допускает продолжение поиска маршрута, если выбранная таблица не может разрешить destination. `lookup-only-in-table` создаёт более жёсткую границу и может быть полезен для fail-closed поведения. Выбирайте сознательно.

## NAT должен соответствовать uplink

Routing и NAT — разные подсистемы. Можно выбрать правильный route и всё равно потерять Internet access, если srcnat не покрывает фактический egress interface.

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

Если используются статические публичные адреса или provider-specific srcnat, оставляйте их явными.

## `check-gateway=ping` — не полная проверка Internet

Ping gateway проверяет только доступность next hop. Провайдер может отвечать на gateway, но иметь проблемы выше по сети.

Если это существенный failure mode, используйте более сильную health-check схему: recursive routes, внешние probes, Netwatch или другой контролируемый механизм.

Но не усложняйте failover без необходимости. Понятная простая схема лучше красивой, но неочевидной цепочки recursive routes.

## Проверяйте routing tables напрямую

```routeros
/ip/route/print detail where routing-table=rt_wan_ab
/ip/route/print detail where routing-table=rt_wan_ac
/routing/rule/print detail
```

Под normal state должен быть активен primary route, а backup должен быть доступен с ожидаемым distance.

Порядок rules — часть политики. Internal-destination rules должны стоять раньше generic source rules.

## Проверка с реального host

Самая важная проверка — фактический egress path с host внутри нужного VLAN.

Например:

```bash
curl -4 https://ifconfig.me
```

Проверяйте минимум три состояния:

1. все uplink исправны;
2. primary недоступен;
3. primary восстановлен.

Host должен перейти на ожидаемый backup и затем вернуться на preferred uplink.

Это ловит проблемы, которые не видно по route flags: NAT mismatch, stale connections, лишние policy matches.

## Existing connections при failover

Failover не гарантирует сохранение уже установленных TCP sessions. При смене провайдера обычно меняется public source address.

Поэтому нормальная модель для простого NAT failover:

- новые соединения работают через backup;
- старые могут потребовать reconnect;
- после восстановления primary новые соединения возвращаются на preferred path.

Это не application-level HA.

## Тестируйте по одному uplink

При commissioning отключайте один WAN за раз:

```routeros
/ip/route/print where dst-address=0.0.0.0/0
```

После этого проверяйте host из каждой policy class.

Если `WAN_A` недоступен:

- user VLAN должны выйти через `WAN_B`;
- admin/service VLAN — через `WAN_C`;
- inter-VLAN и site-to-site трафик должен продолжать идти по внутренним маршрутам.

Если внутренний destination начал уходить в Internet provider — останавливайте rollout и исправляйте rule ordering.

## Failback

После возврата primary проверьте новые соединения. Existing connection-tracking entries могут продолжать жить на старом path до timeout.

Не делайте вывод о failback по старому TCP session.

## Troubleshooting

```routeros
/routing/rule/print detail
/ip/route/print detail
/routing/nexthop/print detail
/ip/firewall/nat/print stats
/ip/firewall/connection/print where src-address~"10.20."
```

Задавайте вопросы по порядку:

- source попал в нужное rule;
- выбранная table разрешает default route;
- next hop доступен;
- NAT совпал с egress interface;
- старое connection tracking не удерживает previous path.

Не очищайте всю connection table как первый шаг на production-router.

## Routing rules и mangle

Routing rules хорошо подходят для политики по source subnet, destination и ingress interface.

Mangle нужен для более сложной классификации. Если mangle выставил routing mark и маршрут разрешился, это может переопределить обычные routing rules.

Перед миграцией модели всегда проверяйте оба места:

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

## Stop conditions

Останавливайте rollout, если:

- management traffic пошёл через неожиданный WAN;
- internal/site-to-site traffic захватился Internet policy table;
- backup route не работает ещё до отключения primary;
- NAT не покрывает выбранный egress;
- DNS зависит только от одного provider path;
- route table переключилась, а реальный host egress — нет;
- mangle и routing rules влияют на один поток без документированной причины.

Failover design считается завершённым только после намеренного тестирования failure state.
