---
title: "KSC Open API: как диагностировать ошибку 1184 при NagRdu и ExecuteFileAsync"
description: "Практическая диагностика Access denied через PxgError и CheckActionState: отдельные ACL-области Connectivity и Common, Gateway Connection и минимизация полномочий."
category: "Мониторинг и безопасность"
tags: ["kaspersky", "ksc", "openapi", "rbac", "nag-rdu", "troubleshooting", "automation"]
published: 2026-10-22
updated: 2026-10-23
status: current
testedOn: ["Kaspersky Security Center 15.1", "KlAkOAPI 1.0.0.0", "Python 3.12"]
featured: false
lang: ru
translationKey: "monitoring/ksc-openapi-nagrdu-1184-rbac"
---

## Симптом: Gateway подключается, но удалённая диагностика запрещена

При разработке RAM-инвентаризации через KSC Open API удалось авторизоваться, найти целевую машину и получить токен шлюза, но вызов `NagRdu.GetCurrentHostState()` возвращал `1184: Доступ запрещён`.

~~~text
KSC connected: True
Matches: 1
Gateway prepared: YES
Gateway connected: True
NagRdu.GetCurrentHostState(): Error code 1184
~~~

Сам по себе `Gateway connected: True` означает лишь успешное создание соединения; **он не подтверждает права на каждую операцию**.

В пилоте использовалась отдельная служебная учётная запись KSC. Настройки выполнялись через MMC с учётом ACL Сервера администрирования и группы, содержащей пилотный компьютер. Доменный администратор Windows не обязательно является администратором KSC. Штатная административная запись KSC имела 2FA; отключать её ради отладки не стали.

## Что проверяли и почему без эффекта

Сначала проверили роль пользователя, наследование ACL и точный Host ID. Затем сравнили последовательность подключения с примерами поставляемого SDK:

~~~python
location = KlAkCgwHelper(server).GetNagentLocation(host_id).RetVal()
token = KlAkGatewayConnection(server).PrepareGatewayConnection(
    [paramParams(location)]
).OutPar("wstrAuthKey")
agent = KlAkAdmServer.CreateGateway(ksc_url, token, ca_file)
~~~

Проверка совпадала с подходом SDK. Вставка `server.Disconnect()` перед `CreateGateway()` сама по себе ошибку не устранила. Методам удалённой диагностики требуются **не только правильные параметры, но и разрешения в соответствующей функциональной области**.

## Диагностика PxgError вместо угадывания прав

Вызов возвращал HTTP `200`, но JSON-ответ содержал `PxgError`. Это **прикладная ошибка KSC**, а не успешное выполнение операции.

При анализе кодов ошибок безопасно выводить только диагностические поля, а не HTTP-заголовки с авторизацией или токен шлюза. В частности, полезны `code`, `module`, `file`, `line` и `message`.

Ключевое сообщение в проверенном случае:

~~~text
Access is denied. Account "<service-user>" doesn't have enough rights
{Read, Write, Execute, CreateTunnel}
from area {...|FUNC_AREA_CONNECTIVITIES}
~~~

После разрешения **Read / Write / Execute / CreateTunnel** в функциональной области «Управление системой → Подключения» (в рамках разрешённого ACL) проверка `NagRdu.GetCurrentHostState()` завершилась успешно.

Важно: это **фактически запрошенный набор для данной операции на KSC 15.1**, а не рекомендация выдавать такие права всем пользователям. `CreateTunnel` требовался проверкой прав, хотя клиент использовал `PrepareGatewayConnection`, а не отдельный TCP-туннель.

## Второй уровень авторизации: ExecuteFileAsync

Следующая ошибка возникла **после успешной загрузки ZIP**. `ExecuteFileAsync()` возвращал Action ID, однако проверка состояния сообщала:

~~~text
ASYNC FINALIZED: True
ASYNC SUCCEEDED: False
ASYNC STATE CODE: 0
ERROR DESCRIPTION: Доступ запрещен.
ERROR CODE: 1184
~~~

Для анализа асинхронной операции нужно читать `pStateData` и вложенные сведения `KLBLAG_ERROR_INFO`; `lStateCode=0` сам по себе не заменяет диагностический код.

Подробный ответ KSC показал:

~~~text
KLBLAG_ERROR_MODULE: KLSTD
KLBLAG_ERROR_FNAME: .../transport/avt/access_check_impl.cpp
KLBLAG_ERROR_MSG: Access is denied. Account "<service-user>"
doesn't have enough rights {Read, Write, Execute}
from area {...|FUNC_AREA_COMMON}
~~~

Это **другая область**, «Общие функции → Базовая функциональность». При предоставлении необходимых Read / Write / Execute, подтверждении применённых ACL и повторном запуске задача завершилась успешно.

| Операция | Область проверки в этом пилоте | Требуемые KSC права |
| --- | --- | --- |
| Доступ к `NagRdu` | `FUNC_AREA_CONNECTIVITIES` | Read, Write, Execute, CreateTunnel |
| Асинхронное исполнение | `FUNC_AREA_COMMON` | Read, Write, Execute |

**Практический вывод:** сообщения KSC позволяют определить точный набор привилегий. Если ошибка остаётся после изменения ACL, проверяйте права на уровне Сервера администрирования, группы устройств, наследование и явные запреты. Не включайте все права подряд и не выдавайте роль полного администратора для обхода проблемы.

## Безопасный контроль асинхронной операции

При ответе `ExecuteFileAsync` сохраните `Action ID`. Затем проверяйте `CheckActionState` до финализации. Не делайте автоматический повтор операции, если неизвестно, запускалась ли команда на агенте: это может вызвать двойное выполнение.

~~~python
state = checker.CheckActionState(action_id)
finalized = bool(state.OutPar("bFinalized"))
succeeded = bool(state.OutPar("bSuccededFinalized"))

if finalized and not succeeded:
    details = state.OutPar("pStateData")
    # Диагностировать KLBLAG_ERROR_INFO;
    # не считать request accepted доказательством успеха.
~~~

В проверенной версии SDK время `lNextCheckDelay` передавалось в миллисекундах. При некорректной интерпретации частота опроса или ожидание искажались. Для длительных операций нужен общий тайм-аут и журнал состояний.

## Ограничения эксплуатации

Разрешения `Write`, `Execute` и `CreateTunnel` чувствительны: их нужно назначать **отдельной технической учётной записи**, по возможности в ограниченной области устройств. Выдача этих прав глобально на сервере KSC требует отдельной оценки риска. В пилоте выполнялся один проверенный Windows-хост, с жёсткой сверкой GUID перед запуском.

После устранения прав была подтверждена успешная загрузка ZIP, удалённое исполнение PowerShell, скачивание отчёта и запись результата в SQLite. Это не означает, что массовый запуск уже проверен.

Продолжение: [сбор модулей RAM через KSC Open API](/ru/notes/monitoring/ksc-openapi-ram-module-inventory/) и [TLS + защищённая доставка](/ru/notes/monitoring/ksc-openapi-verified-tls-inventory-ingest/).

## Код и воспроизводимый пилот

В [репозитории KSC Hardware Inventory](https://github.com/greksw/ksc-hardware-inventory) опубликован [Python-оркестратор](https://github.com/greksw/ksc-hardware-inventory/blob/main/ksc_inventory/ksc_runner.py) с проверкой Host GUID, подключением через Gateway и контролем асинхронного выполнения. Отдельно см. [инструкцию для KSC Open API](https://github.com/greksw/ksc-hardware-inventory/blob/main/README.ru.md) и [правила безопасности](https://github.com/greksw/ksc-hardware-inventory/blob/main/SECURITY.md). Набор привилегий, требуемый для конкретных вызовов, определяется ответом KSC; права на выполнение нельзя выдавать без ограничения области устройств.

### Документация

- [Kaspersky Security Center: Online Help](https://support.kaspersky.com/help/KSC/15.1/en-US/)
- [Kaspersky Open API: официальное описание](https://support.kaspersky.com/help/KSC/15.1/KSCAPI/)
