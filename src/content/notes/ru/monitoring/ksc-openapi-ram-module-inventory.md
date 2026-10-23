---
title: "Инвентаризация физических модулей RAM через Kaspersky Security Center 15.1 Open API"
description: "Практический кейс: почему аппаратной инвентаризации KSC недостаточно для PartNumber, как собрать Win32_PhysicalMemory через Network Agent и сохранить JSON в SQLite."
category: "Мониторинг и безопасность"
tags: ["kaspersky", "ksc", "openapi", "ram", "hardware-inventory", "powershell", "python", "sqlite", "network-agent"]
published: 2026-10-22
updated: 2026-10-23
status: current
testedOn: ["Kaspersky Security Center 15.1", "KlAkOAPI 1.0.0.0", "Windows PowerShell 5.1", "Python 3.12", "AlmaLinux 9"]
featured: false
lang: ru
translationKey: "monitoring/ksc-openapi-ram-module-inventory"
---

## Задача и ограничение штатной инвентаризации

Для планирования модернизации рабочих станций недостаточно знать общий объём RAM. Нужны **физические модули**: занятый слот, производитель, `PartNumber`, ёмкость, тип DDR и заявленная/настроенная скорость.

Kaspersky Security Center 15.1 уже собирает сведения об оборудовании через Network Agent. Детализированное представление `HWInvPCSrvViewName` с фильтром `dev_type=2` позволило получить отдельные записи модулей и значения скорости/объёма (`dev_xpar2` и `dev_xpar3`). Однако в проверенном окружении поля `RamPartNum`, `RamType` и производителя не были заполнены. **Это наблюдение конкретной установки, а не универсальное утверждение обо всех конфигурациях KSC.**

Поэтому связали два источника: **KSC как каталог управляемых компьютеров и защищённый канал выполнения**, Windows CIM — как источник характеристик каждой планки памяти.

Смежный кейс: [инвентаризация установленных CAD-продуктов через KSC Open API](/ru/notes/monitoring/ksc-openapi-cad-inventory/).

## Архитектура, проверенная на одном компьютере

~~~text
Linux: Python 3.12 + KlAkOAPI
  -> HTTPS:13299 / KSC Administration Server
  -> GetNagentLocation + PrepareGatewayConnection
  -> CreateGateway -> Network Agent целевой Windows-машины
  -> NagRdu: передать ZIP -> выполнить CMD/PowerShell
  -> CheckActionState -> скачать ZIP результатов
  -> извлечь и проверить JSON
  -> SSH restricted ingest -> локальный HTTPS Inventory API
  -> SQLite, UNIQUE(computer_name, collected_at)
~~~

В пилоте **не открывали SSH/WinRM до рабочей станции** и не создавали межсегментных firewall-правил. Доступ к Network Agent проходил через уже работающий KSC. В Python дополнительно проверяли, что найден **ровно один** компьютер и его идентификатор совпадает с ожидаемым. Массовое выполнение на всём парке не входило в пилот.

## PowerShell: получение данных из Win32_PhysicalMemory

Сбор выполнялся в контексте удалённой диагностики Network Agent. Для модуля использовались поля `DeviceLocator`, `BankLabel`, `Manufacturer`, `PartNumber`, `Capacity`, `SMBIOSMemoryType`, `Speed` и `ConfiguredClockSpeed`.

Упрощённый фрагмент (полный обезличенный комплект скриптов будет опубликован отдельно после ревизии):

~~~powershell
$modules = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop)

$items = @(
    foreach ($m in $modules) {
        [ordered]@{
            Slot          = [string]$m.DeviceLocator
            Bank          = [string]$m.BankLabel
            Manufacturer  = ([string]$m.Manufacturer).Trim()
            PartNumber    = ([string]$m.PartNumber).Trim()
            CapacityGiB   = [math]::Round([double]$m.Capacity / 1GB, 2)
            SpeedMTs      = [int]$m.Speed
            ConfiguredMTs = [int]$m.ConfiguredClockSpeed
        }
    }
)
~~~

Тип памяти определялся по `SMBIOSMemoryType` (например, 24 — DDR3, 26 — DDR4, 34 — DDR5). Если BIOS/SMBIOS возвращает нули или условные строки, такие значения нужно оставлять как «неизвестно», а не выдумывать PartNumber. `SpeedMTs` и `ConfiguredMTs` — значения, сообщённые Windows, а не независимый физический замер.

Отчёт включал `ComputerName`, `CollectedAt` (UTC), `TotalRAMGiB` и массив `Modules`. В примере ниже **условное имя и условная маркировка**, не реальные данные инфраструктуры:

~~~json
{
  "ComputerName": "PC-DEMO-01",
  "CollectedAt": "2026-10-22T07:00:00Z",
  "TotalRAMGiB": 16,
  "Modules": [
    {
      "Slot": "DIMM0",
      "Bank": "BANK0",
      "Manufacturer": "Example Memory",
      "PartNumber": "EXAMPLE-DDR4-8G",
      "CapacityGiB": 8,
      "MemoryType": "DDR4",
      "SpeedMTs": 2666,
      "ConfiguredMTs": 2666
    },
    {
      "Slot": "DIMM1",
      "Bank": "BANK1",
      "Manufacturer": "Example Memory",
      "PartNumber": "EXAMPLE-DDR4-8G",
      "CapacityGiB": 8,
      "MemoryType": "DDR4",
      "SpeedMTs": 2666,
      "ConfiguredMTs": 2666
    }
  ]
}
~~~

## Передача и выполнение ZIP через NagRdu

В каталоге архива должны находиться управляющий CMD и PowerShell:

~~~text
ram-collector.zip
└── utility/
    ├── Run-RamInventory.cmd
    └── Collect-RamInventory.ps1
~~~

Обращения к API производились последовательно:

1. `NagRdu.GetUrlToUploadFileToHost()` и `KlAkAdmServer.UploadFile()`;
2. `NagRdu.ExecuteFileAsync(upload_url, "Run-RamInventory.cmd", "")`;
3. `KlAkAsyncActionStateChecker.CheckActionState(action_id)` до завершения;
4. извлечение `LastActionResult`, `GetUrlToDownloadFileFromHost()` и `DownloadFile()`.

ZIP результата содержал JSON, файл статуса и `stdout.txt`. Коллектор записывал копию в локальный каталог и, когда доступен, в каталог, указанный переменными `KLACDT_SAVE_SETTINGS` / `KLACDT_SAVE_SETTING`. Возврат JSON дополнительно дублировался в stdout между маркерами.

**Важно:** запрос `ExecuteFileAsync`, вернувший Action ID, ещё не доказывает успешное исполнение. Нужно дождаться `bFinalized=True` и проверить `bSuccededFinalized=True`, затем валидировать сам JSON.

## API и идемпотентное хранение

На отдельном Linux-узле работает FastAPI и SQLite; HTTPS слушает только loopback. Отчёт передаётся с управляющего узла через отдельную ограниченную SSH-учётную запись. API-токен хранится **только на принимающем сервере**, а не в коллекторе и не на Windows.

Таблица хранит JSON целиком и основные агрегаты. Ключ:

~~~sql
UNIQUE(computer_name, collected_at)
~~~

Повторная отправка того же отчёта возвращает `already_exists` без второй записи; новый `CollectedAt` создаёт отдельную историческую запись. Приёмная сторона проверяет размер тела запроса, имя компьютера и наличие массива модулей.

В проверенном пилоте прошёл полный цикл: **успешное асинхронное выполнение, скачивание ZIP, проверка модулей, HTTP 201 и появление новой записи в SQLite**. Это доказательство работоспособности одного устройства, а не ещё подтверждённая массовая автоматизация.

## Что учесть перед масштабированием

- Отбирать только верифицированные физические компьютеры; исключать ВМ, отключённые и нерелевантные узлы.
- Ограничить права служебной записи KSC и область администрирования, не использовать её для повседневного администрирования.
- Проверять сертификат Open API; не оставлять `verify=False`.
- Выполнять сначала 3–5 пилотных хостов, с очередью, ограничением параллелизма, тайм-аутами и журналом.
- Не считать отсутствие данных доказательством отсутствия модуля: инвентаризация зависит от Windows, SMBIOS и доступности Network Agent.
- Не публиковать реальные FQDN, IP, идентификаторы устройств, токены и выгрузки из SQLite.

Продолжение: [ошибка KSC 1184 и права для NagRdu](/ru/notes/monitoring/ksc-openapi-nagrdu-1184-rbac/) и [TLS + защищённая доставка RAM-отчётов](/ru/notes/monitoring/ksc-openapi-verified-tls-inventory-ingest/).

## Исходный код

Опубликован обезличенный комплект **[KSC Hardware Inventory v0.2.1](https://github.com/greksw/ksc-hardware-inventory)**: [Python-оркестратор KSC Open API](https://github.com/greksw/ksc-hardware-inventory/blob/main/ksc_inventory/ksc_runner.py), [PowerShell-коллектор для Network Agent](https://github.com/greksw/ksc-hardware-inventory/blob/main/collectors/ksc/utility/Collect-RamInventory.ps1), [проверка ZIP/JSON](https://github.com/greksw/ksc-hardware-inventory/blob/main/ksc_inventory/result.py) и [инструкция на русском](https://github.com/greksw/ksc-hardware-inventory/blob/main/README.ru.md). [Протокол испытаний](https://github.com/greksw/ksc-hardware-inventory/blob/main/VALIDATION.ru.md) подтверждает один реальный пилотный компьютер, но не массовое развёртывание.

### Документация

- [KSC 15.1 Open API: NagRdu::ExecuteFileAsync](https://support.kaspersky.com/help/KSC/15.1/KSCAPI/a00563_ae9345b487ba2088dea591ddfe511e790.html)
- [KSC Open API: AsyncActionStateChecker::CheckActionState](https://support.kaspersky.com/help/KSC/15/KSCAPI/a00494_a2b34b13591edd83987e08009017e5813.html)
