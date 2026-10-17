---
title: "Массовое обновление Wazuh Agents 4.14: Linux, Proxmox и Windows"
description: "Практический опыт обновления 23 Wazuh Agent до 4.14.9, сценарий Bash с check/apply, контроль AD и обход ошибки PowerShell 2.0 на Windows Server 2008 R2."
category: "Мониторинг и безопасность"
tags: ["wazuh", "agent-upgrade", "wpk", "bash", "powershell", "proxmox", "windows-server", "active-directory", "security"]
published: 2026-10-17
updated: 2026-10-17
status: current
testedOn: ["Wazuh Manager 4.14.9", "AlmaLinux 9", "Proxmox VE", "Windows Server 2022", "Windows Server 2008 R2 SP1"]
featured: false
lang: ru
translationKey: "monitoring/wazuh-agent-fleet-upgrade-4-14"
---

## Контекст

После обновления Wazuh Manager до **4.14.9** обнаружилось 23 активных агента на версиях **4.14.7–4.14.8**. Парк смешанный: Proxmox VE, Enterprise Linux 8/9, Windows Server 2022 и Windows Server 2008 R2. Задача — обновить их без повторной регистрации, сохранив работу мониторинга и критичных приложений.

**Результат: 23 из 23 агентов обновлены до Wazuh 4.14.9.** Большинство обновили удалённо через WPK. Один legacy Windows Server потребовал локальный MSI. Имена серверов, реальные IP, домены и секреты в публикации обезличены.

## 01 / Инвентаризация

На Wazuh Manager:

```bash
rpm -q wazuh-manager
systemctl is-active wazuh-manager wazuh-indexer wazuh-dashboard filebeat
/var/ossec/bin/agent_control -l
/var/ossec/bin/agent_upgrade -l
/var/ossec/bin/agent_control -i 101
```

Штатная команда обновления одного агента:

```bash
/var/ossec/bin/agent_upgrade -a 101 -v 4.14.9
```

Версию выбираем **явно**, не полагаемся на `latest`. `--force` не нужен. Для серверов с важными ролями выбираем последовательное обновление с подтверждением `Active` и правильной версии после каждого узла.

## 02 / Очередность работ

| Партия | Количество | Контроль |
|---|---:|---|
| Пилот Enterprise Linux и Proxmox | 2 | Возврат Active и новой версии |
| Мониторинг и остальные Proxmox | 10 | Состояние узлов, Ceph/HA отдельно |
| Почта, телефония и приложения Linux | 5 | Прикладные health checks |
| Windows Server 2022 / RDS | 3 | WazuhSvc, состояние ОС |
| Два контроллера AD | 2 | repadmin, dcdiag, AD DS/DNS |
| Windows Server 2008 R2 | 1 | Отдельный MSI вместо WPK |
| **Всего** | **23** | |

Для своей инфраструктуры адаптируйте порядок партий и окна обслуживания.

## 03 / Bash-автоматизация на GitHub

Подготовлен открытый набор файлов:

- [upgrade-agents.sh](https://github.com/greksw/notes.shandrov.ru/blob/main/scripts/wazuh-agent-upgrade/upgrade-agents.sh)
- [inventory.example.tsv](https://github.com/greksw/notes.shandrov.ru/blob/main/scripts/wazuh-agent-upgrade/inventory.example.tsv)
- [README — запуск и ограничения](https://github.com/greksw/notes.shandrov.ru/blob/main/scripts/wazuh-agent-upgrade/README.md)

Реальный инвентарь с именами серверов хранится **вне Git**. В примере — вымышленные имена; колонки разделены табуляцией. У каждой записи ID, имя, платформа `linux|windows` и действие `upgrade|skip`.

```bash
install -d -m 700 /root/wazuh-upgrade
install -m 700 upgrade-agents.sh /root/wazuh-upgrade/upgrade-agents.sh
install -m 600 inventory.example.tsv /root/wazuh-upgrade/inventory.tsv

# Сначала отредактировать inventory.tsv и запустить проверку:
/root/wazuh-upgrade/upgrade-agents.sh --check \
  --inventory /root/wazuh-upgrade/inventory.tsv --version 4.14.9

# В согласованное окно, после успешного preflight:
/root/wazuh-upgrade/upgrade-agents.sh --apply --yes \
  --inventory /root/wazuh-upgrade/inventory.tsv --version 4.14.9
```

Скрипт проверяет точное имя и ID, Active, платформу, совместимость версий с Manager; актуальных агентов пропускает. Обновляет **по одному**, ожидает переподключения, останавливается при ошибке, ведёт журнал и блокирует параллельные запуски. **Timeout процесса CLI не гарантирует отмены WPK-задания на агенте**. При зависании нельзя вслепую перезапускать операцию.

## 04 / Терминальные Windows Server 2022

Перед обновлением проверили CBS, Windows Update и PendingFileRenameOperations:

```powershell
$CBS = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
$WU = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
$Rename = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
[pscustomobject]@{CBS=$CBS; WU=$WU; PendingRename=[bool]$Rename}
```

На проверенных серверах CBS и WU были `False`, но файловые операции ожидали перезагрузки преимущественно из-за обновлений браузеров. Записи реестра не удаляли. Три Windows Server 2022 обновились через WPK и вернулись в Active. Это не универсальное разрешение игнорировать pending reboot.

## 05 / Контроллеры домена — по одному

До и после обновления:

```powershell
repadmin /replsummary
repadmin /showrepl dc02 /errorsonly
dcdiag /s:dc02 /test:Advertising /test:Replications /test:Services /q
Invoke-Command -ComputerName dc01,dc02 -ScriptBlock {
    Get-Service NTDS,DNS,KDC,Netlogon,WazuhSvc | Select-Object Name,Status
}
```

Все ключевые службы работали, ошибок репликации не было. Обновили второй DC, проверили AD и Wazuh, затем первый. После операции `repadmin` показывал 0 ошибок, `dcdiag /q` не выдал замечаний по выбранным тестам.

## 06 / Windows Server 2008 R2: WPK и PowerShell 2.0

На последнем сервере агент 4.14.7 оставался Active, но попытка WPK до 4.14.9 зависла на `Upgrading...`. На Windows был PowerShell 2.0, а в `do_upgrade.ps1` присутствовала команда:

```powershell
$VERSION_JSON = Get-Content $JsonFile -Raw
```

Параметр `-Raw` недоступен в PowerShell 2.0; это проверили непосредственно на endpoint. В `upgrade.log` была ошибка `Failed to extract version from JSON file VERSION.json`. MSI ещё не был запущен. Поэтому WPK не повторяли и `--force` не использовали.

## 07 / Локальный MSI с сохранением регистрации

Перед операцией в защищённую резервную копию перенесли `ossec.conf`, `client.keys`, `local_internal_options.conf` и `VERSION.json`. **`client.keys` содержит секрет регистрации**, его нельзя публиковать. Проверили цифровую подпись Wazuh, Inc. на MSI, а также контрольные суммы пакетов.

На Windows Server 2008 R2 PowerShell 2.0 использовали отдельную переменную `$MsiArguments` (не автоматическую `$args`):

```powershell
$MSI = 'C:\Wazuh-Upgrade\wazuh-agent-4.14.9-1.msi'
$Log = 'C:\Wazuh-Upgrade\install-4.14.9.log'
$MsiArguments = '/i "' + $MSI + '" /qn /norestart /L*v "' + $Log + '"'
$Process = Start-Process -FilePath "$env:windir\system32\msiexec.exe" -ArgumentList $MsiArguments -Wait -PassThru
Write-Host "MSI EXIT CODE: $($Process.ExitCode)"
```

MSI завершился с кодом `0`, версия стала 4.14.9, но `WazuhSvc` остался остановленным. После `Start-Service WazuhSvc` агент снова подключился к Manager **со старым ID** и запустил FIM. Лишь после подтверждённого восстановления устаревший маркер `upgrade_in_progress` архивировали.

Windows Server 2008 R2 давно находится вне поддержки; обновление Wazuh Agent не заменяет миграцию ОС.

## 08 / Финальная проверка

```bash
/var/ossec/bin/agent_control -l
/var/ossec/bin/agent_upgrade -l
systemctl is-active wazuh-manager wazuh-indexer wazuh-dashboard filebeat
```

```text
All agents are updated.
23/23 remote agents: 4.14.9
Manager / Indexer / Dashboard / Filebeat: active
```

Статус Active не заменяет проверок качества поступающих событий, здоровья приложений, Ceph/HA и AD DS.

**Исходный код:** [scripts/wazuh-agent-upgrade](https://github.com/greksw/notes.shandrov.ru/tree/main/scripts/wazuh-agent-upgrade).

### Документация

- [Wazuh: удалённое обновление агентов](https://documentation.wazuh.com/current/user-manual/agent/agent-management/remote-upgrading/upgrading-agent.html)
- [Wazuh: Windows agent](https://documentation.wazuh.com/current/installation-guide/wazuh-agent/wazuh-agent-package-windows.html)
