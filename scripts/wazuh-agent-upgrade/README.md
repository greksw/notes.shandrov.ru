# Wazuh Agent fleet upgrade

Контролируемое последовательное обновление Wazuh Agent через Manager (standalone, RPM-based Linux). Проверено на смешанной среде Wazuh 4.14.9: Proxmox, Enterprise Linux и Windows Server 2022. Реальный перечень машин и секреты **не включены**.

## Файлы

- `upgrade-agents.sh` — Bash 4+; проверка и обновление агентов.
- `inventory.example.tsv` — пример инвентаря (разделитель TAB). Копию с реальными ID и именами храните вне Git.

Требования: root, rpm, systemctl, flock, timeout, sort, tee, /var/ossec/bin/agent_control и agent_upgrade.

## Запуск

```bash
install -d -m 700 /root/wazuh-upgrade
install -m 700 upgrade-agents.sh /root/wazuh-upgrade/upgrade-agents.sh
install -m 600 inventory.example.tsv /root/wazuh-upgrade/inventory.tsv
# Изменить ID, имена, платформы, порядок и политику upgrade/skip
/root/wazuh-upgrade/upgrade-agents.sh --check --inventory /root/wazuh-upgrade/inventory.tsv --version 4.14.9
# Только в окно обслуживания и после успешного preflight
/root/wazuh-upgrade/upgrade-agents.sh --apply --yes --inventory /root/wazuh-upgrade/inventory.tsv --version 4.14.9
```

Опционально: `--command-timeout 900` (секунд для одной команды обновления), `--reconnect-timeout 300` (секунд для повторного подключения). Журналы в `/var/log/wazuh-upgrade-*.log`. Параллельные экземпляры блокируются через flock.

Preflight проверяет имена, ID, семейство ОС, Active, версии Manager и Agent. Уже обновлённые агенты пропускаются. Обновление выполняется строго последовательно без `--force`, с остановкой при первой ошибке. **Тайм-аут локальной CLI не отменяет ранее отправленное WPK-задание на endpoint** — до повторного запуска диагностируйте состояние удалённого агента.

Для Windows Server 2008/2003 WPK-запуск заблокирован: используйте `skip` и отдельную локальную MSI-процедуру. На одном Windows Server 2008 R2 с PowerShell 2.0 WPK 4.14.9 остановился на неподдерживаемом `Get-Content -Raw`. Локально проверили подлинность MSI, сохранили `ossec.conf` и `client.keys`, установили MSI, отдельно запустили WazuhSvc и подтвердили исходный ID, Active и 4.14.9. Не публикуйте `client.keys`.

Результат `Active + версия` не заменяет проверки AD DS, DNS, Ceph/HA и прикладных сервисов. Этот инструмент предназначен для standalone Wazuh Manager; для кластерной конфигурации используйте документированный API.

[Официальная документация Wazuh](https://documentation.wazuh.com/current/user-manual/agent/agent-management/remote-upgrading/upgrading-agent.html).
