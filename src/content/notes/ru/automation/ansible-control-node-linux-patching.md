---
title: "Ansible control node и безопасное обновление Linux-серверов"
description: "Лабораторная базовая схема развёртывания Ansible control node и обновления Debian- и RHEL-подобных серверов через inventory groups, become, canary rollout и контролируемые перезагрузки."
category: "Автоматизация и конфигурация"
tags: ["ansible", "linux", "patching", "automation", "ssh", "operations"]
published: 2026-09-16
updated: 2026-09-16
status: lab
testedOn: []
featured: false
lang: ru
translationKey: "automation/ansible-control-node-linux-patching"
---

## Контекст

Ansible работает без агента: control node запускает Ansible и подключается к управляемым Linux-хостам по SSH. На managed nodes обычно нужны Python и рабочая SSH-учётная запись, но отдельный Ansible daemon не требуется.

Для обновления серверов сложность не в командах `apt upgrade` или `dnf update`. Основная задача — контролировать область воздействия, привилегии, порядок выполнения, перезагрузки и обработку ошибок так, чтобы одно неудачное обновление не стало массовым инцидентом.

Эта заметка намеренно имеет статус **лаборатория**, пока точные production inventory, модель аутентификации и maintenance workflow не проверены на реальных серверах.

## Целевая схема

Для небольшого окружения достаточно одного выделенного Linux control node:

```text
Ansible control node
  -> SSH
  -> Debian/Ubuntu servers
  -> RHEL/Alma/Rocky servers
```

Playbooks, структуру inventory и несекретную конфигурацию храните в Git. Приватные ключи, become passwords и vault passwords — вне репозитория.

Пример структуры:

```text
ansible/
├── ansible.cfg
├── inventory/
│   └── hosts.yml
├── group_vars/
│   └── all.yml
└── playbooks/
    ├── preflight.yml
    ├── patch-linux.yml
    └── reboot-linux.yml
```

## Установка Ansible на control node

Текущая документация Ansible поддерживает как полный пакет `ansible`, так и более компактный `ansible-core`. Для минимального control node достаточно `ansible-core`, если используются только встроенные модули из этой заметки.

Один из чистых вариантов установки — через `pipx`:

```bash
pipx install ansible-core
```

Проверка:

```bash
ansible --version
ansible-playbook --version
```

Версию среды автоматизации лучше фиксировать или документировать, а не менять её незаметно во время несвязанного maintenance.

## Модель SSH-доступа

Используйте отдельную automation account или другую явно разрешённую административную учётную запись. Root SSH login не должен быть базовой моделью.

Учетной записи нужны:

- SSH-доступ с control node;
- доверенный SSH key;
- Python на managed node;
- privilege escalation для задач, требующих root.

Для повышения привилегий Ansible использует `become`. Будет ли sudo без пароля, с паролем или через другой механизм — это уже политика конкретного окружения.

Если нужен become password, не храните его в plaintext inventory. Используйте Ansible Vault, утверждённое хранилище секретов или интерактивный ввод.

## Inventory

Пример YAML inventory:

```yaml
all:
  children:
    linux:
      children:
        debian:
          hosts:
            deb01.example.net:
            deb02.example.net:
        rhel:
          hosts:
            rhel01.example.net:
            rhel02.example.net:

    canary:
      hosts:
        deb01.example.net:
        rhel01.example.net:
```

Общие параметры подключения можно вынести в `group_vars/all.yml`:

```yaml
ansible_user: ansible
```

Приватные ключи не коммитьте. Лучше использовать обычную SSH-конфигурацию или agent, чем прописывать пути к ключам и секреты в каждом inventory entry.

Проверьте inventory:

```bash
ansible-inventory -i inventory/hosts.yml --graph
```

## Базовый ansible.cfg

Project-local конфигурация может быть явной и при этом не ослаблять SSH trust:

```ini
[defaults]
inventory = ./inventory/hosts.yml
host_key_checking = True
retry_files_enabled = False
timeout = 20
forks = 10
interpreter_python = auto_silent
```

Не отключайте host-key checking только ради удобства первого подключения. `known_hosts` должен заполняться контролируемо.

## Первая проверка связи

До любых package changes:

```bash
ansible linux -m ansible.builtin.ping
```

Затем соберите немного фактов:

```bash
ansible linux -m ansible.builtin.setup \
  -a 'filter=ansible_distribution*'
```

Ошибки подключения нужно понять до начала patching. На первом этапе не стоит скрывать unreachable hosts через `ignore_unreachable`.

## Preflight playbook

`playbooks/preflight.yml`:

```yaml
---
- name: Preflight Linux hosts
  hosts: linux
  gather_facts: true

  tasks:
    - name: Require a supported OS family
      ansible.builtin.assert:
        that:
          - ansible_facts.os_family in ['Debian', 'RedHat']
        fail_msg: >-
          Unsupported OS family: {{ ansible_facts.os_family }}

    - name: Confirm current kernel
      ansible.builtin.command: uname -r
      register: kernel
      changed_when: false

    - name: Show current kernel
      ansible.builtin.debug:
        var: kernel.stdout
```

Сначала запускайте только на canary group:

```bash
ansible-playbook playbooks/preflight.yml --limit canary
```

## Playbook обновления

Консервативная первая версия обновляет по одному серверу.

`playbooks/patch-linux.yml`:

```yaml
---
- name: Patch Linux servers
  hosts: linux
  become: true
  gather_facts: true
  serial: 1
  any_errors_fatal: true

  tasks:
    - name: Update Debian package metadata and upgrade packages
      ansible.builtin.apt:
        update_cache: true
        cache_valid_time: 3600
        upgrade: dist
      when: ansible_facts.os_family == 'Debian'

    - name: Upgrade installed packages on RHEL-family hosts
      ansible.builtin.dnf:
        name: '*'
        state: latest
        update_only: true
        update_cache: true
      when: ansible_facts.os_family == 'RedHat'

    - name: Check whether Debian requests a reboot
      ansible.builtin.stat:
        path: /var/run/reboot-required
      register: debian_reboot_required
      when: ansible_facts.os_family == 'Debian'

    - name: Report Debian reboot requirement
      ansible.builtin.debug:
        msg: "Reboot required on {{ inventory_hostname }}"
      when:
        - ansible_facts.os_family == 'Debian'
        - debian_reboot_required.stat.exists | default(false)
```

`serial: 1` сознательно жертвует скоростью ради уменьшения blast radius. После проверки процесса размер batch можно увеличивать осознанно.

Для RHEL-подобных систем playbook выше не пытается универсально определять необходимость reboot. Это зависит от установленного инструментария и локальной политики; лучше оформить отдельной проверкой, чем делать вид, что один эвристический признак подходит всем.

## Проверка до выполнения

Синтаксис:

```bash
ansible-playbook playbooks/patch-linux.yml --syntax-check
```

Check mode как дополнительный этап ревью:

```bash
ansible-playbook playbooks/patch-linux.yml \
  --limit canary \
  --check \
  --diff
```

Check mode не является транзакционным симулятором. Реальная dependency resolution и состояние внешних repositories всё равно могут отличаться.

## Сначала canary

Реальное обновление сначала только на representative hosts:

```bash
ansible-playbook playbooks/patch-linux.yml --limit canary
```

После этого проверяйте приложения на этих серверах. Успешный package task не равен здоровому сервису.

Только потом расширяйте scope:

```bash
ansible-playbook playbooks/patch-linux.yml
```

## Перезагрузки лучше отделить

Для первого внедрения отдельный reboot playbook проще контролировать, чем автоматически перезагружать каждый обновлённый сервер.

`playbooks/reboot-linux.yml`:

```yaml
---
- name: Reboot explicitly selected Linux servers
  hosts: linux
  become: true
  gather_facts: false
  serial: 1
  any_errors_fatal: true

  tasks:
    - name: Reboot and wait for the host to return
      ansible.builtin.reboot:
        reboot_timeout: 900
```

Не запускайте его вслепую на весь inventory. Используйте явный limit:

```bash
ansible-playbook playbooks/reboot-linux.yml \
  --limit deb01.example.net
```

`ansible.builtin.reboot` ждёт перезапуск и возврат host, но не доказывает, что application stack после этого исправен.

## Rolling updates

По умолчанию Ansible работает с несколькими hosts параллельно. Keyword `serial` ограничивает размер batch и является базовым механизмом rolling maintenance.

Например:

```yaml
serial: 1
```

или после достаточной проверки:

```yaml
serial: 2
```

Для clustered systems размер batch должен следовать quorum и архитектуре сервиса, а не универсальному числу.

## Что не стоит автоматически включать в generic patch group

Не смешивайте с обычными Linux-серверами системы, у которых есть собственный порядок maintenance, например:

- hypervisor clusters;
- storage clusters;
- database clusters;
- directory-service controllers;
- mail platforms;
- firewalls и routers;
- системы со строгой application-level последовательностью обновления.

Ansible может автоматизировать и их, но им нужен workload-specific orchestration, а не общий `state: latest` play.

## Backup и rollback

Ansible не делает package upgrades транзакционными.

До обновления критичного host должен быть понятен реальный recovery path:

- VM/PBS backup;
- application-native backup;
- filesystem snapshot, если уместно;
- возврат версии package, если старая сборка ещё доступна в repository;
- документированная процедура rebuild.

Playbook может остановиться после failure. Он не может гарантировать автоматическую обратимость каждой package transaction.

## Проверка после обновления

Минимально фиксируйте:

```text
host
OS version
kernel before
kernel after
package task result
reboot performed: yes/no
SSH reachable after maintenance: yes/no
application validation: pass/fail
```

Если сервис мониторится, убедитесь, что ожидаемые alerts очистились, а health metrics вернулись к норме.

## Безопасная эксплуатационная последовательность

Практичный workflow:

```text
inventory review
  -> SSH connectivity
  -> preflight
  -> syntax check
  -> check mode
  -> canary patch
  -> application validation
  -> wider patch rollout
  -> explicit reboot set
  -> post-maintenance validation
```

Ценность Ansible не в том, что он может одновременно обновить сто серверов. Ценность в том, что одна и та же проверенная процедура повторяется предсказуемо, а scope и failure handling остаются явными.

## References

- Installing Ansible: <https://docs.ansible.com/projects/ansible/latest/installation_guide/intro_installation.html>
- Building an inventory: <https://docs.ansible.com/projects/ansible/latest/getting_started/get_started_inventory.html>
- Privilege escalation: <https://docs.ansible.com/projects/ansible/latest/playbook_guide/playbooks_privilege_escalation.html>
- `ansible.builtin.apt`: <https://docs.ansible.com/projects/ansible/latest/collections/ansible/builtin/apt_module.html>
- `ansible.builtin.dnf`: <https://docs.ansible.com/projects/ansible/latest/collections/ansible/builtin/dnf_module.html>
- `ansible.builtin.reboot`: <https://docs.ansible.com/projects/ansible/latest/collections/ansible/builtin/reboot_module.html>
- Rolling execution with `serial`: <https://docs.ansible.com/projects/ansible/latest/playbook_guide/playbooks_strategies.html>
