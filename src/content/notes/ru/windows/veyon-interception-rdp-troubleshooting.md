---
title: "Veyon и нестабильный RDP: диагностика Interception, UpperFilters и GPO"
description: "Практический кейс Veyon 4.11.3–4.11.4 на Windows: ошибки RDP, проверка драйверов Interception, UpperFilters, безопасное удаление и контроль развёртывания через GPO."
category: "Windows"
tags: ["veyon", "rdp", "interception", "windows", "active-directory", "gpo", "powershell", "upperfilters", "troubleshooting", "scheduled-tasks", "kaspersky"]
published: 2026-10-29
updated: 2026-10-29
status: current
testedOn: ["Veyon 4.11.3–4.11.4", "Windows 10 22H2", "Active Directory", "PowerShell 5.1", "Group Policy Preferences", "Windows OpenSSH"]
featured: false
lang: ru
translationKey: "windows/veyon-interception-rdp-troubleshooting"
---

## Симптомы и границы кейса

После централизованной установки Veyon Service на доменных Windows-компьютерах появились непостоянные сбои RDP: чёрный экран после авторизации, разрыв соединения, иногда код клиента **0x10b**. При этом TCP/3389 отвечал, служба Remote Desktop Services работала, компьютер был доступен по SSH и другим каналам. После перезагрузки RDP мог временно работать, а затем сбой повторялся.

В октябре 2026 года проверили несколько рабочих станций с Veyon 4.11.3 и 4.11.4. На части машин аудит подтвердил **загруженные драйверы Interception** и записи `keyboard` / `mouse` в `UpperFilters`. На одной проблемной станции выполнили контролируемое отключение Interception, а затем применили новую конфигурацию Veyon без него.

**Результат на момент публикации:** драйверы остановлены, фильтры Interception исключены из цепочек клавиатуры и мыши, Veyon Service работает, новая конфигурация развёртывания успешно применена; новых ошибок TerminalServices Event ID 36 после применения не зарегистрировано. **Долговременная устойчивость RDP пока не доказана.** Активный сеанс и успешное завершение скрипта не заменяют проверку изображения, ввода и повторных подключений.

Имена хостов, домена, пользователей, GPO, группы операторов и адреса ниже обезличены.

## 1. Почему Interception — важная гипотеза

Interception — драйвер-фильтр клавиатуры и мыши, применяемый Veyon для некоторых функций блокировки ввода. В [официальной документации Veyon](https://docs.veyon.io/en/latest/admin/platform-notes.html) указано, что драйвер **может конфликтовать с RDP**, и описан порядок его отключения и удаления.

Различайте три состояния:

1. `Windows/UseInterceptionDriver=false` — Veyon настроен не использовать драйвер.
2. Фильтры `keyboard` и `mouse` отсутствуют в `UpperFilters` — драйвер выведен из классовой цепочки устройств.
3. Службы драйверов `keyboard` и `mouse` имеют состояние `STOPPED` — драйверы сейчас не загружены.

**Одного пункта недостаточно.** В нашем случае настройка Veyon уже имела значение `false`, однако драйверы оставались загруженными и присутствовали в `UpperFilters`.

## 2. Проверяем службы, сеансы и события RDP

На проблемной станции (локально или по SSH):

~~~powershell
Get-Service VeyonService, TermService |
  Select-Object Name, Status, StartType

qwinsta
quser
~~~

С другой машины:

~~~powershell
Test-NetConnection PC-TEST-01 -Port 3389
Test-NetConnection PC-TEST-01 -Port 11100
~~~

Положительный TCP-тест не гарантирует создания RDP-сеанса. Статус `Active` не подтверждает, что пользователь видит изображение и может пользоваться вводом; `Disconnected` сам по себе не является неисправностью.

Для журнала `Microsoft-Windows-TerminalServices-LocalSessionManager/Operational`:

~~~powershell
$Boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime

$Errors = @(
  Get-WinEvent -FilterHashtable @{
    LogName   = 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'
    StartTime = $Boot
    Id        = 36
  } -ErrorAction SilentlyContinue
)

[pscustomobject]@{
  Computer         = $env:COMPUTERNAME
  LastBoot         = $Boot
  RdpEvent36Count  = $Errors.Count
}

$Errors | Select-Object -First 10 TimeCreated, Id, Message | Format-List
~~~

В исследованном случае встречались коды переходов состояний сеанса `0x800708CA` и `0x8007000C`. В журнале `Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Operational` отмечались `Failed to create Input devices` и `0x80070057`.

**Это признаки сбоя инициализации, но не однозначное доказательство конфликта Interception.** Сопоставляйте их с событиями после изменения драйверов.

## 3. Проверяем Interception и UpperFilters

~~~powershell
sc.exe query keyboard
sc.exe query mouse
~~~

До исправления обе службы имели состояние `RUNNING`. Для классов клавиатуры и мыши смотрим `UpperFilters`:

~~~powershell
$Classes = [ordered]@{
  Keyboard = '{4D36E96B-E325-11CE-BFC1-08002BE10318}'
  Mouse    = '{4D36E96F-E325-11CE-BFC1-08002BE10318}'
}

foreach ($Entry in $Classes.GetEnumerator()) {
  $Path = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$($Entry.Value)"
  $Key = Get-Item -LiteralPath $Path
  $Filters = @($Key.GetValue('UpperFilters'))

  [pscustomobject]@{
    Class = $Entry.Key
    UpperFilters = $Filters -join ', '
    InterceptionPresent = $Filters -contains $Entry.Key.ToLowerInvariant()
  }
}
~~~

Пример до исправления:

~~~text
Keyboard: keyboard, klkbdctl.KES-XX, kbdclass, klfltdev.KES-XX
Mouse:    mouse, mouclass, klfltdev.KES-XX
~~~

После вывода Interception из цепочки:

~~~text
Keyboard: klkbdctl.KES-XX, kbdclass, klfltdev.KES-XX
Mouse:    mouclass, klfltdev.KES-XX
~~~

`kbdclass` и `mouclass` — штатные компоненты Windows. `klkbdctl...` и `klfltdev...` встречались в обследованной среде с Kaspersky Endpoint Security. Состав фильтров может отличаться.

**Не очищайте UpperFilters целиком и не удаляйте системные или защитные фильтры вручную:** это может привести к потере локального ввода.

## 4. Значение UseInterceptionDriver в реестре и Veyon

Проверяем не только наличие параметра, но и его фактическое значение:

~~~powershell
$Path = 'HKLM:\SOFTWARE\Veyon Solutions\Veyon\Windows'
$Key = Get-Item -LiteralPath $Path

[pscustomobject]@{
  ValueExists = $Key.GetValueNames() -contains 'UseInterceptionDriver'
  Value = $Key.GetValue('UseInterceptionDriver')
}
~~~

Ожидается существующее значение `false`. Когда параметр отсутствует, возможна работа со значением по умолчанию — включено.

Дополнительно экспортируем эффективную конфигурацию:

~~~powershell
$Cli = 'C:\Program Files\Veyon\veyon-cli.exe'
$Export = Join-Path $env:TEMP (
  'veyon-audit-' + [guid]::NewGuid().ToString('N') + '.json'
)

try {
  & $Cli config export $Export | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Veyon export failed: $LASTEXITCODE"
  }

  $Cfg = Get-Content -LiteralPath $Export -Raw -Encoding UTF8 |
    ConvertFrom-Json

  [pscustomobject]@{
    SettingPresent = $null -ne $Cfg.Windows.PSObject.Properties['UseInterceptionDriver']
    Value = $Cfg.Windows.UseInterceptionDriver
  }
}
finally {
  Remove-Item -LiteralPath $Export -Force -ErrorAction SilentlyContinue
}
~~~

Полный экспорт не публикуйте: он может содержать сведения об авторизации и внутренней конфигурации. В пилоте реестр и экспорт подтвердили `false`.

## 5. Штатное удаление установленного драйвера

Порядок в [документации Veyon](https://docs.veyon.io/en/latest/admin/platform-notes.html): **отключить использование Interception → перезагрузить Windows → выполнить штатный uninstall**. Новые установки выполняются с параметром `/NoInterception`.

На целевом ПК с административными правами:

~~~powershell
& 'C:\Program Files\Veyon\veyon-cli.exe' config set Windows/UseInterceptionDriver false
~~~

Перед изменениями нужны резервная копия, согласованное окно обслуживания, сохранённые пользовательские данные и **проверенная физическая консоль**. SSH и NoMachine — дополнительные каналы управления, но не полная замена консоли при сбое драйверов ввода.

Штатное удаление:

~~~powershell
& 'C:\Program Files\Veyon\interception\install-interception.exe' /uninstall
~~~

Команда выполняется **на рабочей станции**, не на контроллере домена. В PowerShell нельзя копировать выражение `%~dp0` из batch-файла.

В одном из тестов деинсталлятор сообщил:

~~~text
Error deleting \system32\drivers\keyboard.sys
~~~

Затем аудит показал: записи Interception уже исчезли из `UpperFilters`, но драйверы были загружены до перезагрузки. После контролируемой перезагрузки оба стали `STOPPED` с кодом 1077, штатные фильтры Windows и Kaspersky сохранились.

**Это наблюдение конкретной машины, не универсальное разрешение перезагружать ПК после ошибки.** Если деинсталлятор отработал частично, сначала проверяйте файлы, службы и фильтры. Не удаляйте `keyboard.sys` / `mouse.sys` вручную, не применяйте `sc delete`, `pnputil` и массовое редактирование `UpperFilters` без отдельного плана восстановления.

## 6. Читаем UpperFilters на нескольких компьютерах

С административного сервера при доступном WMI/DCOM можно выполнять безопасный аудит:

~~~powershell
$Computers = @('PC-TEST-01', 'PC-TEST-02')
$HKLM = [uint32]2147483650

$Paths = @{
  Keyboard = 'SYSTEM\CurrentControlSet\Control\Class\{4D36E96B-E325-11CE-BFC1-08002BE10318}'
  Mouse    = 'SYSTEM\CurrentControlSet\Control\Class\{4D36E96F-E325-11CE-BFC1-08002BE10318}'
}

foreach ($PC in $Computers) {
  try {
    $Reg = [WmiClass]"\\$PC\root\default:StdRegProv"

    foreach ($Name in @('Keyboard', 'Mouse')) {
      $Response = $Reg.GetMultiStringValue($HKLM, $Paths[$Name], 'UpperFilters')
      if ($Response.ReturnValue -ne 0) {
        throw "$Name read failed: $($Response.ReturnValue)"
      }
      $Filters = @($Response.sValue)

      [pscustomobject]@{
        Computer = $PC
        Class = $Name
        InterceptionPresent = $Filters -contains $Name.ToLowerInvariant()
        UpperFilters = $Filters -join ', '
        Status = 'OK'
      }
    }
  }
  catch {
    [pscustomobject]@{
      Computer = $PC
      Class = '-'
      InterceptionPresent = $null
      UpperFilters = ''
      Status = $_.Exception.Message
    }
  }
}
~~~

Ошибка RPC означает **«не проверено»**, а не отсутствие Interception.

## 7. Проверяем GPO, чтобы драйвер не вернулся

На рабочих станциях Veyon развёртывался через Group Policy Preferences, запланированное задание и PowerShell от `SYSTEM`. Старый скрипт устанавливал Veyon 4.11.3 с аргументами:

~~~powershell
$Version = '4.11.3.0'
$psi.Arguments = '/S /NoMaster'
~~~

Параметр `/NoInterception` отсутствовал. Импортируемый JSON также **не задавал явно** `Windows.UseInterceptionDriver=false`. Ежедневное задание GPP с действием `Update` создавало риск повторного применения старой конфигурации.

При этом production-скрипт закреплял SHA-256 установщиков и JSON, проверял подпись, группу операторов, порт TCP/11100 и отклонял неизвестные версии. Поэтому **не меняйте JSON или EXE прямо в действующем пакете**: сначала подготовьте отдельную, полностью согласованную версию.

Пилотные компьютеры исключили через:

~~~text
Computer Configuration → Preferences → Control Panel Settings
  → Scheduled Tasks → Veyon-AutoDeploy
    → Common → Item-level targeting
~~~

Правила `Computer Name is not PC-TEST-01` и остальные исключения должны быть объединены оператором **AND**. Существующие локальные задания отдельно отключили и проверили после обновления GPO.

~~~powershell
schtasks.exe /Query /S PC-TEST-01 /TN 'Veyon-AutoDeploy' /FO LIST /V
~~~

Отключение локального задания без изменения GPO недостаточно: GPP может снова включить его.

## 8. Пилот нового развёртывания и контроль после применения

Новая пилотная редакция предусматривала:

- Veyon 4.11.4 с `/S /NoMaster /NoInterception`;
- корпоративную конфигурацию с `Windows.UseInterceptionDriver=false`;
- проверки SHA-256, подписи установщика, доменной группы доступа и ограниченного Firewall TCP/11100;
- **отказ от автоматического удаления** ранее установленных активных фильтров;
- режим `-WhatIfCheck`;
- рабочее применение от `NT AUTHORITY\SYSTEM` через временное Scheduled Task.

Сначала провели dry-run от администратора и отдельно от SYSTEM: оба завершились кодом 0 без установки, импорта или перезапуска служб. Рабочий пилот также завершился `SUCCESS` и кодом 0; TaskScheduler Event ID **201** подтвердил завершение действия. После проверки временную задачу удалили.

Контрольные признаки:

| Проверка | Ожидаемый результат |
| --- | --- |
| VeyonService / TermService | Running |
| Реестр и экспорт Veyon | `UseInterceptionDriver=false` |
| Службы драйверов `keyboard` / `mouse` | STOPPED |
| Классовые `UpperFilters` | Нет `keyboard` / `mouse` от Interception |
| `kbdclass`, `mouclass`, защитные фильтры | Сохранены |
| Старое задание GPO | Не включается повторно |
| Лог развёртывания / Event 201 | SUCCESS, код 0 |
| RDP Event ID 36 | Нет новых событий за контрольный период |
| RDP и Veyon Master | Реально работают экран, ввод и переподключение |
| Проверка на следующий рабочий день | По возможности без перезагрузки |

**Вывод:** конфликт Interception с RDP — обоснованная гипотеза, согласующаяся с документацией и собранными данными. Удаление из стека устройств и применение новой конфигурации подтверждены. Окончательное устранение первопричины требует устойчивой работы RDP в течение наблюдаемого периода.

## Источники и связанные материалы

- [Veyon — Platform specific notes](https://docs.veyon.io/en/latest/admin/platform-notes.html)
- [Veyon — Release notes](https://docs.veyon.io/en/latest/admin/release-notes.html)
- [Microsoft — Remote Desktop disconnected errors](https://learn.microsoft.com/en-us/troubleshoot/windows-server/remote/troubleshoot-remote-desktop-disconnected-errors)
- [Предыдущий кейс: Veyon, AD и GPO](/ru/notes/windows/veyon-workgroup-ad-authentication-gpo-diagnostics/)
