---
title: "Ansible control node для production-обновления Linux-серверов"
description: "Production-схема Ansible для массового обновления AlmaLinux-серверов: role-based inventory, raw/DNF workflow, определение обновления ядра и безопасное развитие maintenance-процесса."
category: "Автоматизация и конфигурация"
tags: ["ansible", "linux", "patching", "automation", "ssh", "operations"]
published: 2026-09-16
updated: 2026-09-16
status: current
testedOn: ["AlmaLinux 10.2 control node", "Ansible Core 2.16.16", "AlmaLinux managed hosts"]
featured: true
lang: ru
translationKey: "automation/ansible-control-node-linux-patching"
---

## Контекст

В production уже используется отдельный Ansible control node для массового обновления Linux-серверов.

Control node работает на AlmaLinux 10.2 с Ansible Core 2.16.16. Inventory разделяет обычные AlmaLinux-серверы, Proxmox VE nodes, Proxmox Backup Server и role-based группы: monitoring, backup, mail, Asterisk и Wazuh.

Текущий production playbook обновляет только группу `almalinux_servers`. Hypervisor и backup infrastructure присутствуют в inventory, но не входят в тот же generic update play.

Такое разделение важнее, чем сложность самого playbook: массовая автоматизация безопасна только тогда, когда область воздействия остаётся явной.

## Текущая production-схема

Фактический inventory построен по ролям. В обезличенном виде он выглядит так:

```text
@all
├── @almalinux_servers
├── @proxmox_ve_nodes
├── @proxmox_pbs_nodes
├── @asterisk_servers
├── @monitoring_servers
├── @backup_servers
├── @mail
├── @mail2
├── @mail3
├── @mail4
└── @wazuh
```

Role-groups при необходимости пересекаются с более общей OS-group. Это позволяет адресовать либо семейство систем, либо отдельную прикладную роль.

Перед maintenance полезно проверять effective inventory:

```bash
ansible-inventory --graph
```

Для production это простой, но важный guardrail: сначала убедиться, что playbook затронет именно ожидаемые hosts.

## Control node

Текущий production baseline:

```text
OS: AlmaLinux 10.2
Ansible: ansible-core 2.16.16
Config: /etc/ansible/ansible.cfg
```

Быстрые проверки:

```bash
ansible --version
ansible-inventory --graph
```

Важнее не конкретный способ установки Ansible, а зафиксированная runtime-версия и понятный config path.

## Текущий production playbook обновления

Сейчас используется `raw`, чтобы update path не зависел от Python modules на managed host.

Обезличенный вариант:

```yaml
---
- name: Update AlmaLinux servers
  hosts: almalinux_servers
  become: true

  tasks:
    - name: Update all packages
      ansible.builtin.raw: dnf update -y
      register: update_result
      changed_when: "'Nothing to do' not in update_result.stdout"

    - name: Remove old dependencies
      ansible.builtin.raw: dnf autoremove -y
      when: update_result.changed

    - name: Clean DNF cache
      ansible.builtin.raw: dnf clean all
      when: update_result.changed

    - name: Check whether a newer kernel was installed
      ansible.builtin.raw: |
        CURRENT_KERNEL=$(uname -r)
        LATEST_KERNEL=$(rpm -q kernel --last | head -1 | awk '{print $1}' | sed 's/kernel-//')
        if [ "$CURRENT_KERNEL" != "$LATEST_KERNEL" ]; then
          echo "kernel_updated"
        else
          echo "kernel_not_updated"
        fi
      register: kernel_check
      changed_when: false

    - name: Schedule reboot after kernel update
      ansible.builtin.raw: shutdown -r +1 "Reboot after kernel update"
      when:
        - update_result.changed
        - "'kernel_updated' in kernel_check.stdout"

    - name: Final status
      ansible.builtin.debug:
        msg: |
          {{ inventory_hostname }} - UPDATE COMPLETE
          {% if update_result.changed %}
          System updated
          {% if 'kernel_updated' in kernel_check.stdout %}
          Reboot scheduled
          {% endif %}
          {% else %}
          No updates required
          {% endif %}
```

Это реальный production baseline, но он намеренно простой.

## Зачем здесь `raw`

`ansible.builtin.raw` отправляет команду напрямую через SSH и не требует обычного Python module subsystem на managed host.

Это полезно для bootstrap и для серверов, где наличие Python ещё нельзя считать гарантированным.

Но есть и ограничения:

- нет обычной module-level idempotence;
- check mode практически не помогает для package operation;
- `changed` приходится определять по stdout;
- parsing зависит от текста package manager и locale;
- error handling ближе к shell, чем к структурированным Ansible modules.

Поэтому `raw` здесь допустим как осознанный compatibility choice, но не обязательно как конечная форма automation.

## Как сейчас определяется необходимость reboot

Production play сравнивает running kernel с самым новым установленным kernel package и планирует reboot через минуту, если они различаются:

```bash
shutdown -r +1 "Reboot after kernel update"
```

Плюс этого подхода в том, что package update успевает завершиться до начала reboot.

Минус — Ansible не ждёт возврата host. Поэтому финальный `debug` не доказывает, что сервер успешно загрузился и приложение снова работает.

Это важно разделять:

```text
package update completed != maintenance completed
```

## Inventory уже снижает blast radius

Отдельные группы для Proxmox VE и PBS уже есть, а массовый update play нацелен только на `almalinux_servers`.

Это правильная схема. Hypervisor и backup nodes должны обслуживаться отдельными runbook'ами, потому что там важны reboot order, VM placement, storage state и cluster health.

То же относится к mail, databases, directory services и другим stateful/clustered workloads: Ansible может управлять ими, но не обязательно через один общий update play.

## Что стоит улучшить следующим этапом

Текущий workflow работает, но его можно сделать безопаснее без полной переделки.

### 1. Добавить canary group

Сначала обновлять один-два representative hosts:

```text
canary -> validate -> wider group
```

Это снижает blast radius при проблемном package/repository update.

### 2. Добавить rolling batches

Сейчас playbook не задаёт `serial`, поэтому Ansible может работать с несколькими hosts параллельно согласно стратегии и `forks`.

Для infrastructure servers лучше начинать консервативно:

```yaml
serial: 1
```

После стабилизации процесса batch можно увеличить.

### 3. Вынести `dnf autoremove`

`dnf autoremove` меняет package state сильнее, чем обычный update. Его лучше сделать отдельной reviewed maintenance operation, а не автоматическим следствием любого обновления.

Для critical hosts сначала стоит увидеть, какие packages будут удалены.

### 4. Перейти на DNF module, когда Python гарантирован

Если Python стабильно присутствует на managed AlmaLinux hosts, package task можно перевести на structured module:

```yaml
- name: Upgrade installed packages
  ansible.builtin.dnf:
    name: '*'
    state: latest
    update_only: true
    update_cache: true
```

Тогда не придётся определять `changed` по строке `Nothing to do`.

### 5. Сделать reboot управляемым Ansible task

Более зрелая схема может использовать:

```yaml
- name: Reboot and wait for the server
  ansible.builtin.reboot:
    reboot_timeout: 900
```

Это хотя бы подтверждает возврат SSH. Но application health всё равно нужно проверять отдельно.

### 6. Добавить post-update validation по ролям

Для каждой role нужно определить, что означает «сервер здоров после обновления».

Примеры:

```text
monitoring server -> monitoring service active + UI/API reachable
mail server       -> containers/services healthy + SMTP checks
Wazuh             -> manager/indexer/dashboard services healthy
Asterisk          -> service active + SIP/AMI/health check
backup server     -> backup service/storage available
```

Успешный exit code package manager недостаточен для production validation.

## Рекомендуемый staged workflow

Безопасное развитие текущей схемы:

```text
inventory review
  -> connectivity check
  -> canary update
  -> service validation
  -> rolling update wider group
  -> reboot only where required
  -> wait for host return
  -> application validation
  -> record failures and exceptions
```

Так сохраняется реальный production use case, но automation перестаёт усиливать риск одного неудачного package или reboot decision.

## Пример более безопасного AlmaLinux play

Это целевая схема, а не утверждение, что production уже работает именно так:

```yaml
---
- name: Rolling AlmaLinux update
  hosts: almalinux_servers
  become: true
  gather_facts: true
  serial: 1
  any_errors_fatal: true

  tasks:
    - name: Upgrade installed packages
      ansible.builtin.dnf:
        name: '*'
        state: latest
        update_only: true
        update_cache: true

    - name: Record running kernel
      ansible.builtin.command: uname -r
      register: running_kernel
      changed_when: false

    - name: Show running kernel
      ansible.builtin.debug:
        var: running_kernel.stdout
```

Определение reboot requirement и role-specific validation лучше добавлять явно, а не прятать внутрь общего package step.

## Backup и rollback

Ansible не делает package upgrades транзакционными.

До обновления важных серверов должен быть понятен recovery mechanism:

- VM/PBS backup;
- application-native backup;
- snapshot, если уместно;
- package downgrade path, если поддерживается;
- rebuild procedure для disposable/reproducible systems.

Успешный playbook не заменяет recovery plan.

## Operational checklist

Перед массовым обновлением:

```text
[ ] inventory target проверен
[ ] excluded infrastructure подтверждена
[ ] backup/recovery path известен
[ ] выбран первый host или canary
[ ] maintenance window понятен
```

После:

```text
[ ] package task completed
[ ] rebooted hosts returned
[ ] services validated
[ ] monitoring returned to normal
[ ] failures documented
```

## References

- Ansible `raw` module: <https://docs.ansible.com/projects/ansible/latest/collections/ansible/builtin/raw_module.html>
- Ansible `dnf` module: <https://docs.ansible.com/projects/ansible/latest/collections/ansible/builtin/dnf_module.html>
- Ansible `reboot` module: <https://docs.ansible.com/projects/ansible/latest/collections/ansible/builtin/reboot_module.html>
- Rolling execution with `serial`: <https://docs.ansible.com/projects/ansible/latest/playbook_guide/playbooks_strategies.html>
- Privilege escalation: <https://docs.ansible.com/projects/ansible/latest/playbook_guide/playbooks_privilege_escalation.html>
