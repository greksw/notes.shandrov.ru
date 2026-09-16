---
title: "Proxmox VE: rolling-обновление ядра с однократным fallback"
description: "Production-runbook для поузлового изменения kernel в многоузловом Proxmox-кластере с сохранением quorum, эвакуацией workloads и быстрым rollback."
category: "Proxmox и виртуализация"
tags: ["proxmox", "kernel", "cluster", "maintenance", "quorum", "rollback"]
published: 2026-09-16
updated: 2026-09-16
status: current
testedOn: ["Proxmox VE 9.2.x", "9-node cluster", "UEFI/GRUB"]
featured: true
lang: ru
translationKey: "proxmox/proxmox-rolling-kernel-maintenance"
---

## Контекст

Kernel maintenance в Proxmox VE — это не столько задача `apt`, сколько контролируемое изменение booted kernel при сохранении quorum, доступности workloads, storage и понятного пути rollback.

Практический production-подход консервативен: меняется один node за раз, целевой kernel проверяется до reboot, workloads эвакуируются, первый node используется как canary, а предыдущий kernel остаётся доступен через GRUB.

Та же схема подходит и для обычного rollout нового kernel, и для проверки другого known-good kernel после regression.

## Инварианты обслуживания

Не переходите к следующему node, пока для предыдущего не выполнены все условия:

- cluster quorate;
- восстановилось ожидаемое количество nodes;
- Corosync и Proxmox management services healthy;
- реально загружен требуемый kernel;
- guest/storage state нормален;
- не появились новые критические systemd failures;
- rollback kernel всё ещё установлен.

Несколько nodes не перезагружаются параллельно только потому, что математически quorum это позволяет.

## Целевой kernel

```bash
TARGET_KERNEL="6.17.13-21-pve"
```

Версия здесь — пример конкретного проверенного target. В реальном maintenance window подставьте выбранную версию.

## Cluster preflight

Начинайте только со здорового кластера:

```bash
pvecm status
```

Минимально подтвердите:

- `Quorate: Yes`;
- ожидаемое число nodes;
- корректные votes/quorum;
- отсутствие неожиданно offline nodes.

Если используется HA:

```bash
ha-manager status
```

Если Ceph:

```bash
ceph -s
```

Для внешнего storage:

```bash
pvesm status
```

Остановите maintenance, если Ceph уже имеет неожиданные degraded/inactive PG, нужный storage недоступен или HA занят восстановлением несвязанных ресурсов.

## Выберите canary node

Не начинайте с наиболее критичного host. Выберите node, workloads которого можно чисто мигрировать и отказ которого не создаст второй incident.

Зафиксируйте локальный guest set:

```bash
qm list
pct list
```

Для HA resources проверьте фактическое состояние до перемещений. Для обычных VM/CT используйте стандартную migration procedure.

После эвакуации убедитесь, что на node не остались production workloads, которые не должны прерываться, и что нет активных backup, replication или migration tasks.

## Node preflight

На выбранном node зафиксируйте состояние:

```bash
hostname -s
date
uptime
pveversion
uname -r
```

Проверьте наличие target kernel и boot artifacts:

```bash
test -s "/boot/vmlinuz-${TARGET_KERNEL}"
test -s "/boot/initrd.img-${TARGET_KERNEL}"
```

Проверьте boot layout:

```bash
findmnt /boot/efi || true
proxmox-boot-tool status || true
```

Node, загружающийся через GRUB, не обязательно использует `proxmox-boot-tool` для синхронизации ESP. Отсутствие `/etc/kernel/proxmox-boot-uuids` само по себе не является ошибкой обслуживания; сначала нужно понимать boot path.

Проверьте core services:

```bash
systemctl is-active pve-cluster
systemctl is-active corosync
systemctl is-active pvedaemon
systemctl is-active pveproxy
systemctl is-active pvestatd
systemctl --failed --no-pager
```

Последняя команда фиксирует существующие failures, чтобы не принять старую проблему за regression после reboot.

## Сохраните rollback path

Не удаляйте предыдущий рабочий kernel до завершения rollout.

Для первого теста удобно использовать one-boot pin:

```bash
proxmox-boot-tool kernel pin "${TARGET_KERNEL}" --next-boot
```

`--next-boot` выбирает kernel только для следующей загрузки и не меняет долгосрочный default навсегда.

На системах, где ESP управляются `proxmox-boot-tool`, после изменения pin:

```bash
proxmox-boot-tool refresh
```

Не запускайте bootloader maintenance механически на mixed boot layouts. Сначала исследуйте каждый node.

## Последний gate перед reboot

Непосредственно перед перезагрузкой повторите динамические проверки:

```bash
pvecm status
ha-manager status
pvesm status
```

При Ceph:

```bash
ceph -s
```

Также подтвердите, что node эвакуирован и нет активной administrative task.

Если cluster уже не в том же healthy state, что в начале окна, reboot откладывается.

## Reboot одного node

```bash
reboot
```

По возможности наблюдайте через независимый console path: IPMI, iKVM или физическую консоль. Kernel/bootloader failure может произойти до появления сети.

Пока canary загружается, следующий node не трогайте.

## Проверка после загрузки

Сначала проверьте реально запущенный kernel:

```bash
uname -r
[ "$(uname -r)" = "${TARGET_KERNEL}" ]
```

Затем services:

```bash
systemctl is-active pve-cluster
systemctl is-active corosync
systemctl is-active pvedaemon
systemctl is-active pveproxy
systemctl is-active pvestatd
systemctl --failed --no-pager
```

И cluster membership/quorum:

```bash
pvecm status
```

Повторите HA/storage/Ceph checks теми же командами, что и до reboot.

Только после infrastructure validation можно возвращать workloads.

## Проверяйте реальные workloads

Node, который снова виден в GUI, ещё не доказывает успешность maintenance.

Проверьте представительные workloads:

- хотя бы одну VM с обычным network/storage I/O;
- latency-sensitive или Windows workload, если ранее были kernel regressions;
- storage-backed workload при важном Ceph/NFS path;
- HA-managed resource, если HA включён.

```bash
qm status <vmid>
pct status <ctid>
```

При возможности используйте application-level checks. `running` не доказывает, что сервис внутри VM реально исправен.

## Продолжайте node-by-node

После периода наблюдения за canary повторяйте одинаковую последовательность:

1. cluster health;
2. evacuation;
3. target boot artifacts и rollback kernel;
4. one-boot pin;
5. reboot только одного node;
6. kernel/services/quorum/storage/workload validation;
7. переход дальше только после полного восстановления.

Процедура должна быть скучной и повторяемой. Это преимущество, а не недостаток.

## Rollback: kernel загрузился, но нестабилен

Снова эвакуируйте workloads и выберите previous known-good kernel:

```bash
PREVIOUS_KERNEL="<known-good-kernel>"
proxmox-boot-tool kernel pin "${PREVIOUS_KERNEL}" --next-boot
```

Выполните `refresh`, только если node использует managed ESP, затем reboot и полный post-boot validation.

Проблемный kernel не раскатывается дальше, пока canary исследуется.

## Rollback: kernel не загрузился

Если node не дошёл до userspace/network, SSH уже не recovery path.

Через консоль выберите предыдущий kernel в **GRUB → Advanced options for Proxmox VE**. Именно поэтому предыдущий kernel нельзя преждевременно удалять.

После восстановления соберите evidence предыдущей загрузки:

```bash
journalctl -b -1 -k
journalctl -b -1 -p warning..alert
```

Ищите driver, storage, filesystem, network или hardware initialization failures.

## Stop conditions

Останавливайте rollout при любом из условий:

- quorum потерян или нестабилен;
- Corosync membership непоследователен;
- required storage недоступен;
- Ceph получил неожиданный degraded/inactive state;
- HA начал восстанавливать несвязанные ресурсы;
- node загрузился не на том kernel;
- core Proxmox services failed;
- представительные workloads показывают новые ошибки;
- rollback kernel или console path больше недоступны.

Runbook должен определять не только как продолжать, но и когда остановиться.

## Почему useful one-boot pin

Permanent pin иногда нужен, но плох как default для первого cluster-wide test.

One-boot pin даёт контролируемый эксперимент:

- target kernel указан явно;
- normal default не меняется навсегда;
- previous kernel остаётся в GRUB;
- canary оценивается до изменения следующего node.

## Эксплуатационные заметки

Используйте одинаковые preflight/post-boot команды. Сравнение одних и тех же сигналов до и после reboot упрощает поиск regression.

Фиксируйте фактически running kernel на каждом node. Установленный package не означает, что rollout завершён.

Для большого cluster полезен простой checklist со статусами `pending`, `evacuated`, `rebooted`, `validated`, `complete`. Здесь дисциплина процесса важнее сложной автоматизации.
