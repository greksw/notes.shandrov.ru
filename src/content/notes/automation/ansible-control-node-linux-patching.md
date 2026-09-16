---
title: "Ansible control node for production Linux patching"
description: "A production-backed Ansible setup for mass-updating AlmaLinux servers, with role-based inventory, raw DNF workflow, kernel-change detection and a safer roadmap for staged maintenance."
category: "Automation & Configuration"
tags: ["ansible", "linux", "patching", "automation", "ssh", "operations"]
published: 2026-09-16
updated: 2026-09-16
status: current
testedOn: ["AlmaLinux 10.2 control node", "Ansible Core 2.16.16", "AlmaLinux managed hosts"]
featured: true
translationKey: "automation/ansible-control-node-linux-patching"
---

## Context

This environment already uses a dedicated Ansible control node in production for mass Linux package updates.

The control node runs AlmaLinux 10.2 with Ansible Core 2.16.16. The inventory separates ordinary AlmaLinux servers from Proxmox VE nodes, Proxmox Backup Server and role-specific groups such as monitoring, backup, mail, Asterisk and Wazuh.

The current production update workflow intentionally targets the AlmaLinux server group only. Hypervisors and backup infrastructure are present in inventory but are not included in the same generic update play.

That separation is more important than making the first playbook sophisticated: broad automation is useful only when the target scope remains explicit.

## Current production layout

The actual inventory is more role-oriented than a minimal tutorial inventory. A sanitized representation looks like this:

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

The role groups overlap with the broader operating-system group where appropriate. This makes it possible to target either an OS family or one application role without duplicating host definitions conceptually.

Inspect the effective inventory before maintenance:

```bash
ansible-inventory --graph
```

For production work, this is a useful guardrail: verify the intended target set before running a destructive or reboot-capable playbook.

## Control node

Current production baseline:

```text
OS: AlmaLinux 10.2
Ansible: ansible-core 2.16.16
Config: /etc/ansible/ansible.cfg
```

Useful checks:

```bash
ansible --version
ansible-inventory --graph
```

The exact installation method is less important than documenting the runtime version and configuration path used by the automation environment.

## Current production update playbook

The current playbook uses `raw` commands so the update path does not depend on Python modules on the managed host.

Sanitized version:

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

This is a real production baseline, but it is intentionally simple.

## Why `raw` can be useful

`ansible.builtin.raw` sends the command directly over the configured connection without requiring the normal Python module subsystem on the managed host.

That makes it useful for bootstrap work and for hosts where Python availability cannot yet be assumed.

The trade-off is important:

- no normal module-level idempotence;
- no useful check-mode simulation for the package operation;
- change detection must be inferred from command output;
- stdout parsing can depend on locale and package-manager wording;
- error handling is more shell-oriented than module-oriented.

So `raw` is a valid operational choice, but it should be treated as an explicit compatibility decision rather than the end state of the automation design.

## Current reboot behaviour

The production play compares the running kernel with the newest installed kernel package and schedules a reboot one minute later when they differ:

```bash
shutdown -r +1 "Reboot after kernel update"
```

This has one useful property: the package update task can finish before reboot starts.

It also has a limitation: Ansible does not wait for the host to return, so the playbook's final success message does not prove that the server booted successfully or that its application became healthy again.

That distinction should stay explicit:

```text
package update completed != maintenance completed
```

## Inventory isolation is already doing useful risk control

The current inventory contains separate groups for Proxmox VE and PBS. The mass-update play targets `almalinux_servers`, not the whole inventory.

That is the correct direction. Hypervisor and backup nodes should have workload-specific maintenance procedures because reboot order, quorum, VM placement and storage state matter there.

The same principle applies to mail, databases, directory services and other clustered or stateful workloads: they can still be managed by Ansible, but not necessarily with one generic update play.

## What should be improved next

The current workflow works, but several changes would make it safer and more observable without discarding the existing implementation.

### 1. Add an explicit canary group

Instead of immediately targeting every ordinary Linux server, first update one or two representative hosts:

```text
canary -> validate -> wider group
```

This reduces blast radius when a repository or package introduces a problem.

### 2. Add rolling batches

The current play does not specify `serial`, so Ansible may operate on several hosts in parallel according to its normal strategy and fork count.

For infrastructure servers, start conservatively:

```yaml
serial: 1
```

or a small percentage once the process is proven.

### 3. Separate `dnf autoremove`

`dnf autoremove` changes package state beyond simply applying updates. It is better treated as a separate reviewed maintenance action rather than an automatic consequence of every package update.

For critical hosts, inspect what will be removed before making it part of a generic unattended path.

### 4. Prefer the DNF module once Python is guaranteed

When Python is consistently available on managed AlmaLinux hosts, the package task can move from shell parsing to the Ansible DNF module:

```yaml
- name: Upgrade installed packages
  ansible.builtin.dnf:
    name: '*'
    state: latest
    update_only: true
    update_cache: true
```

This gives Ansible structured task semantics rather than relying on the string `Nothing to do`.

### 5. Make reboot a controlled Ansible task

A mature version can use `ansible.builtin.reboot` for explicitly approved hosts:

```yaml
- name: Reboot and wait for the server
  ansible.builtin.reboot:
    reboot_timeout: 900
```

That verifies that SSH becomes available again, although application health still needs a separate check.

### 6. Add post-update service validation

For every role, define what "healthy after update" means.

Examples:

```text
monitoring server -> monitoring service active + UI/API reachable
mail server       -> containers/services healthy + SMTP checks
Wazuh             -> manager/indexer/dashboard services healthy
Asterisk          -> service active + SIP/AMI/health check
backup server     -> backup service/storage available
```

A package manager exit code is not enough for production validation.

## Recommended staged workflow

A safer evolution of the current process is:

```text
inventory review
  -> connectivity check
  -> canary update
  -> service validation
  -> rolling update of the wider group
  -> reboot only where required
  -> wait for host return
  -> application validation
  -> record failures and exceptions
```

This keeps the existing production use case while reducing the chance that mass automation amplifies one bad package or one incorrect reboot decision.

## Example safer AlmaLinux update play

This is a target pattern, not a claim that the current production play already works this way:

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

Reboot detection and role-specific validation should then be added explicitly rather than hidden inside a generic package step.

## Backup and rollback

Ansible does not make package upgrades transactional.

Before updating important servers, know the recovery mechanism:

- VM/PBS backup;
- application-native backup where required;
- snapshot where appropriate;
- package downgrade path if supported;
- rebuild procedure for disposable or reproducible systems.

A successful playbook cannot replace a recovery plan.

## Operational checklist

Before a mass update:

```text
[ ] inventory target reviewed
[ ] excluded infrastructure confirmed
[ ] current backups/recovery path known
[ ] first host or canary selected
[ ] maintenance window understood
```

After it:

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
