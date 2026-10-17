---
title: "Очистка встроенных приложений Windows 10/11 через GPO: PowerShell Appx, Audit и Enforce"
description: "Практический кейс пользовательской GPO для инвентаризации и удаления Appx по точным именам: v1.0–v1.4, SystemApps, OneDrive, защита пользовательских данных и журналирование."
category: "Windows"
tags: ["windows", "active-directory", "gpo", "powershell", "appx", "windows-11", "security", "automation", "sysvol"]
published: 2026-10-17
updated: 2026-10-17
status: current
testedOn: ["Windows 10/11", "Windows PowerShell 5.1", "Active Directory", "User Configuration GPO"]
featured: false
lang: ru
translationKey: "windows/gpo-windows-appx-cleanup-user-logon"
---

## Задача

В доменной инфраструктуре потребовалась управляемая очистка выбранных пользовательских приложений Windows 10/11 без затрагивания остальных профилей и системных компонентов. Для этого используется **User Configuration GPO → Logon Scripts**, CMD-обёртка и PowerShell 5.1 в контексте вошедшего пользователя, **не SYSTEM**.

Исходные версии v1.0, v1.3 и v1.4 отражают развитие производственного сценария. Все опубликованные файлы обезличены и дополнительно защищены; их выполнение на Windows после адаптации не заявляется. Реальные внутренние домены, OU, имена рабочих станций и учётных записей исключены из примеров.

## Схема выполнения

```text
Active Directory → User OU / Security Filtering
    → User Configuration → Windows Settings → Scripts (Logon)
    → Run-AppCleanup.cmd → Remove-UserApps.ps1 (interactive user)
        Audit: Get-AppxPackage → FOUND / REVIEW / PROTECTED
        Enforce: Remove-AppxPackage по точным именам → REMOVED / DEFER / ERROR
    → %LOCALAPPDATA%\Example\AppCleanup\cleanup.log
```

Охват определяется привязкой GPO к OU, security filtering и результирующим набором политик, а не суффиксами учётных записей внутри скрипта. Исключения из корпоративных схем именования учитываются администратором при назначении GPO.

## Сначала Audit, затем Enforce

PowerShell-скрипт принимает `-Mode Audit` по умолчанию и не удаляет пакеты в режиме инвентаризации. Перед операциями проверяется SID пользователя: контекст `S-1-5-18` (SYSTEM) запрещён. Windows Server и RDS также пропускаются, если администратор отдельно не разрешил обработку. Повторный параллельный запуск ограничивает пользовательский mutex.

```powershell
powershell.exe -NoProfile -File .\Remove-UserApps.ps1 -Mode Audit
Get-AppxPackage | Select-Object Name, PackageFamilyName, Version, NonRemovable
gpresult /scope user /r
Get-Content "$env:LOCALAPPDATA\Example\AppCleanup\cleanup.log" -Tail 40
```

Для удаления используются **точные свойства Appx `Name`**, а не опасные маски `*Office*`, `*Xbox*`, `*Skype*`. Это не исключает бизнес-зависимостей у точно выбранных пакетов: состав списка необходимо утверждать после пилотной инвентаризации.

В производственных CMD-обёртках использовался `Enforce`. **Публичная CMD-обёртка специально запускает `Audit`**, а текущий образец PowerShell требует дополнительный параметр `-AcknowledgeAppRemoval` для удаления. Сохранённые в `history/` версии не предназначены для непосредственного удаления приложений.

## История v1.0 → v1.3 → v1.4

| Версия | Что изменилось |
| --- | --- |
| v1.0 | Точные имена Appx, Audit/Enforce, запрет SYSTEM, пользовательский mutex и журнал, инвентаризация HKCU |
| v1.3 | Расширены цели и проверки `NonRemovable`, `IsPartOfSystem`, `Windows\SystemApps`; удаление нового Outlook откладывается при работающем `olk.exe` |
| v1.4 | Добавлена точная идентичность пакета Яндекс Музыки `A025C540.Yandex.Music`, подтверждённая на одном тестовом Windows 11 |

Системные пакеты логируются как `PROTECTED` и не удаляются с принудительной сменой владельца или прав каталогов. Неизвестные совпадения попадают в `REVIEW`, но не удаляются автоматически.

## OneDrive, Outlook и ограничения

`Remove-AppxPackage` применяется **к текущему пользователю**. Скрипт не выполняет `Remove-AppxProvisionedPackage` для образа Windows, не удаляет Win32-программы всего компьютера и не меняет `C:\Windows\SystemApps`.

Для нового Outlook `Microsoft.OutlookForWindows` предусмотрена отсрочка при запущенном процессе `olk.exe`. OneDrive Desktop обрабатывается отдельно: его удаление требует явного `-RemovePerUserOneDrive` вместе с разрешённым `Enforce`, причём при активном процессе синхронизации деинсталляция откладывается. Записи в `HKCU\...\Uninstall` собираются только для анализа: произвольные `UninstallString` не запускаются.

Код возврата `0` может означать пропуск на сервере или отложенное действие, а не факт очистки. Windows Update может вернуть регистрации некоторых Appx; общего rollback и полной инвентаризации всех рабочих станций эти скрипты не обеспечивают.

## Исходный код и безопасное применение

**[GitHub: greksw/windows-appcleanup-gpo](https://github.com/greksw/windows-appcleanup-gpo)** — [актуальный скрипт](https://github.com/greksw/windows-appcleanup-gpo/blob/main/scripts/Remove-UserApps.ps1), [исторические версии и CMD](https://github.com/greksw/windows-appcleanup-gpo/tree/main/history), [документация GPO](https://github.com/greksw/windows-appcleanup-gpo/blob/main/docs/gpo-setup.ru.md), [проверка безопасности](https://github.com/greksw/windows-appcleanup-gpo/blob/main/docs/security-review.ru.md).

Перед применением: проверить список точных Appx-имён и зависимости, выполнить Audit на пилотной OU, проверить лог и пользовательский `gpresult`, согласовать Enforce и план повторной установки необходимых приложений. Статический CI на GitHub проверяет синтаксис, но не подтверждает безопасное выполнение удаления на Windows.
