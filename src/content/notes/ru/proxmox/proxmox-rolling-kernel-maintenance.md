---
title: "Proxmox VE: поузловое обновление ядра с однократным откатом"
description: "Практический runbook для обновления ядра в многоузловом Proxmox-кластере с сохранением кворума, эвакуацией нагрузок и быстрым откатом."
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

Обновление ядра в Proxmox VE — это не просто задача `apt`. Основной риск связан с перезагрузкой узлов при сохранении кворума, доступности VM/CT, storage и понятного пути отката.

Практичный подход консервативен:

- менять по одному узлу;
- проверять целевое ядро до reboot;
- заранее эвакуировать рабочие нагрузки;
- первый узел использовать как canary;
- не удалять предыдущее рабочее ядро до завершения rollout.

Та же схема подходит и для обычного обновления, и для проверки другого known-good kernel после regression.

## Инварианты обслуживания

Не переходите к следующему узлу, пока для предыдущего не подтверждено:

- cluster остаётся quorate;
- восстановилось ожидаемое количество узлов;
- Corosync и службы Proxmox работают;
- загружено требуемое ядро;
- storage доступен;
- VM/CT работают нормально;
- не появились новые критические systemd failures;
- предыдущее рабочее ядро всё ещё доступно для отката.

Не перезагружайте несколько узлов одновременно только потому, что математически кворум это позволяет.

## Целевое ядро

```bash
TARGET_KERNEL="6.17.13-21-pve"
```

Версия здесь — пример. В реальном окне обслуживания подставьте заранее выбранное ядро.

## Проверка кластера до работ

```bash
pvecm status
```

Минимально убедитесь, что:

- `Quorate: Yes`;
- количество узлов ожидаемое;
- votes/quorum корректны;
- нет неожиданно offline nodes.

Если используется HA:

```bash
ha-manager status
```

Если используется Ceph:

```bash
ceph -s
```

Для внешнего storage:

```bash
pvesm status
```

Остановите обслуживание, если Ceph уже находится в неожиданном degraded/inactive состоянии, нужное хранилище недоступно или HA занят восстановлением посторонних ресурсов.

## Выберите canary-узел

Не начинайте с самого критичного host.

Выберите узел, с которого нагрузки можно штатно мигрировать и отказ которого не создаст второй инцидент.

Зафиксируйте локальные VM и CT:

```bash
qm list
pct list
```

После эвакуации убедитесь, что на узле не осталось производственных нагрузок, которые нельзя прерывать, и нет активных backup, replication или migration tasks.

## Проверка узла

```bash
hostname -s
date
uptime
pveversion
uname -r
```

Проверьте наличие ядра и initrd:

```bash
test -s "/boot/vmlinuz-${TARGET_KERNEL}"
test -s "/boot/initrd.img-${TARGET_KERNEL}"
```

Проверьте boot layout:

```bash
findmnt /boot/efi || true
proxmox-boot-tool status || true
```

Узел, загружающийся через GRUB, не обязательно использует `proxmox-boot-tool` для управления ESP. Сначала определите реальный boot path, а уже потом выполняйте bootloader-related действия.

Проверьте основные службы:

```bash
systemctl is-active pve-cluster
systemctl is-active corosync
systemctl is-active pvedaemon
systemctl is-active pveproxy
systemctl is-active pvestatd
systemctl --failed --no-pager
```

Последняя команда нужна, чтобы отличать старые failures от новых проблем после перезагрузки.

## Сохраните путь отката

Не удаляйте предыдущее рабочее ядро до завершения rollout.

Для первого теста удобно использовать pin только на одну загрузку:

```bash
proxmox-boot-tool kernel pin "${TARGET_KERNEL}" --next-boot
```

`--next-boot` выбирает ядро только для следующей загрузки и не меняет постоянный default.

На системах, где ESP действительно управляются `proxmox-boot-tool`, после изменения pin может потребоваться:

```bash
proxmox-boot-tool refresh
```

Не запускайте bootloader maintenance механически на узлах с разной схемой загрузки.

## Последняя проверка перед reboot

Повторите динамические проверки непосредственно перед перезагрузкой:

```bash
pvecm status
ha-manager status
pvesm status
```

При Ceph:

```bash
ceph -s
```

Также подтвердите, что узел эвакуирован и нет активных административных задач.

Если состояние кластера уже отличается от исходного healthy state, reboot откладывается.

## Перезагрузка одного узла

```bash
reboot
```

По возможности наблюдайте через независимую консоль: IPMI, iKVM или физический доступ. Ошибка ядра или bootloader может произойти до появления сети.

Пока canary-узел не прошёл полную проверку, следующий узел не трогайте.

## Проверка после загрузки

Сначала убедитесь, что реально загружено требуемое ядро:

```bash
uname -r
[ "$(uname -r)" = "${TARGET_KERNEL}" ]
```

Затем проверьте службы:

```bash
systemctl is-active pve-cluster
systemctl is-active corosync
systemctl is-active pvedaemon
systemctl is-active pveproxy
systemctl is-active pvestatd
systemctl --failed --no-pager
```

И кворум:

```bash
pvecm status
```

Повторите HA/storage/Ceph checks теми же командами, что и до reboot.

Только после инфраструктурной проверки возвращайте нагрузки.

## Проверяйте реальные workload

Появление узла в GUI ещё не доказывает, что обслуживание прошло успешно.

Проверьте представительные нагрузки:

- обычную VM с network/storage I/O;
- Windows или latency-sensitive workload, если ранее были regression;
- workload на важном Ceph/NFS path;
- HA-managed resource, если HA используется.

```bash
qm status <vmid>
pct status <ctid>
```

По возможности добавьте проверку самого приложения. `running` не означает, что сервис внутри VM действительно исправен.

## Продолжайте по одному узлу

Для каждого следующего узла повторяйте один и тот же цикл:

1. проверить cluster health;
2. эвакуировать workload;
3. проверить target kernel и rollback kernel;
4. задать one-boot pin;
5. перезагрузить только один node;
6. проверить kernel, services, quorum, storage и workload;
7. переходить дальше только после полного восстановления.

## Откат: ядро загрузилось, но работает нестабильно

Снова эвакуируйте workload и выберите предыдущее рабочее ядро:

```bash
PREVIOUS_KERNEL="<known-good-kernel>"
proxmox-boot-tool kernel pin "${PREVIOUS_KERNEL}" --next-boot
```

Если узел использует managed ESP, выполните необходимый `refresh`, затем reboot и полный post-boot validation.

Проблемное ядро не раскатывайте дальше до завершения анализа canary.

## Откат: ядро не загрузилось

Если узел не дошёл до userspace или сети, SSH уже не поможет.

Через консоль выберите предыдущее ядро в:

**GRUB → Advanced options for Proxmox VE**

После восстановления соберите данные предыдущей загрузки:

```bash
journalctl -b -1 -k
journalctl -b -1 -p warning..alert
```

Ищите ошибки driver, storage, filesystem, network и hardware initialization.

## Условия остановки

Останавливайте rollout, если:

- quorum потерян или нестабилен;
- Corosync membership непоследователен;
- обязательный storage недоступен;
- Ceph перешёл в неожиданное degraded/inactive состояние;
- HA начал восстанавливать посторонние ресурсы;
- узел загрузился не на том ядре;
- основные службы Proxmox не поднялись;
- представительные workload показывают новые ошибки;
- путь отката или консоль больше недоступны.

## Почему полезен one-boot pin

Permanent pin иногда нужен, но для первого cluster-wide теста он менее безопасен.

One-boot pin позволяет провести контролируемый эксперимент:

- целевое ядро указано явно;
- постоянный default не меняется;
- предыдущее ядро остаётся доступно через GRUB;
- canary можно оценить до перехода к следующему узлу.

## Эксплуатационные заметки

Используйте одинаковые проверки до и после reboot. Сравнение одних и тех же сигналов упрощает поиск regression.

Фиксируйте фактически загруженное ядро на каждом узле. Установленный package не означает, что rollout завершён.

Для большого кластера полезен простой checklist со статусами `pending`, `evacuated`, `rebooted`, `validated`, `complete`. Здесь дисциплина процесса важнее сложной автоматизации.
