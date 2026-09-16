---
title: "Wazuh SCA: проверка сканирований и rollout custom hardening policies"
description: "Production-oriented workflow для проверки Wazuh Security Configuration Assessment, безопасного добавления custom policies и валидации результатов без лишнего расширения attack surface endpoint."
category: "Мониторинг и безопасность"
tags: ["wazuh", "sca", "hardening", "security", "cis", "compliance"]
published: 2026-09-16
updated: 2026-09-16
status: current
testedOn: ["Wazuh 4.14.x", "AlmaLinux 9", "Linux agents"]
featured: true
lang: ru
translationKey: "monitoring/wazuh-sca-validation-and-custom-policies"
---

## Контекст

Security Configuration Assessment полезен только тогда, когда одновременно выполняются три условия:

1. agent действительно запускает ожидаемую policy;
2. результат доходит до Wazuh server и виден централизованно;
3. failed check означает реальную hardening gap, а не broken policy или path.

Типичная operational ошибка — считать dashboard источником истины и на этом остановиться. В production rollout нужно проверять всю цепочку: policy file на endpoint → локальный SCA scan → agent log → central visibility → remediation workflow.

Этот runbook посвящён именно этой цепочке и безопасному rollout custom policies.

## Что проверяет Wazuh SCA

Wazuh SCA policies — это YAML-файлы с checks. В зависимости от rule type проверяться могут files, directories, registry values, processes и другое локальное configuration state.

Wazuh agents обычно поставляются с policy под конкретную ОС в default SCA ruleset directory. На Linux agents это:

```text
/var/ossec/ruleset/sca
```

Custom policy files не следует редактировать прямо в этом каталоге. Package upgrades могут заменить файлы там, поэтому production custom policies лучше хранить отдельно и подключать явно.

## Сначала зафиксируйте baseline

На agent сохраните версию и service state:

```bash
/var/ossec/bin/wazuh-control info
systemctl status wazuh-agent --no-pager
```

Проверьте SCA block активной конфигурации:

```bash
grep -n -A20 -B2 '<sca>' /var/ossec/etc/ossec.conf
```

Посмотрите доступные policies:

```bash
find /var/ossec/ruleset/sca -maxdepth 1 -type f \
  \( -name '*.yml' -o -name '*.yaml' \) -printf '%f\n' | sort
```

Не считайте, что каждая policy на manager автоматически есть на каждом endpoint. Agent обычно получает policy, релевантную его ОС.

## Убедитесь, что SCA включён

Модуль управляется через `<sca>` в `ossec.conf`.

Минимальный явный пример:

```xml
<sca>
  <enabled>yes</enabled>
  <scan_on_start>yes</scan_on_start>
  <interval>12h</interval>
  <skip_nfs>yes</skip_nfs>
</sca>
```

Точный interval — operational choice. Не ставьте слишком короткие интервалы на большой fleet без явной причины: SCA — это configuration assessment, а не per-second monitoring.

На Linux `skip_nfs` при включении исключает CIFS/NFS mounted filesystems из сканирования. На серверах с network storage это часто полезно, чтобы SCA случайно не обходил remote trees.

## Запустите controlled validation scan

Если `scan_on_start` включён, простой способ запустить scan — restart agent:

```bash
sudo systemctl restart wazuh-agent
```

После этого проверьте локальный log:

```bash
grep -Ei 'sca: INFO:|sca: WARNING:|sca: ERROR:' \
  /var/ossec/logs/ossec.log | tail -50
```

Успешный запуск должен содержать completion message вида:

```text
sca: INFO: Security Configuration Assessment scan finished.
```

Ключевой момент: endpoint сам подтверждает, что SCA engine отработал. Dashboard result сам по себе не доказывает, что последний local scan действительно завершился после изменения конфигурации.

## Сопоставьте local и central state

После завершения local scan проверьте тот же endpoint в Wazuh dashboard в разделе Configuration Assessment.

Убедитесь, что:

- присутствует ожидаемая policy;
- scan timestamp актуален;
- pass/fail counts меняются после намеренного изменения test condition;
- dashboard не показывает старый cached result, пока agent фактически не может завершить scan.

Для большого fleet сначала используйте один canary agent, а не раскатывайте новую policy сразу на целую server group.

## Не редактируйте vendor policies in place

Файлы внутри default SCA ruleset не стоит считать persistent customization layer.

Для дополнительных hardening checks создайте отдельный каталог, например:

```bash
sudo install -d -m 0750 -o root -g wazuh /var/ossec/etc/custom-sca
```

Храните custom policy там:

```text
/var/ossec/etc/custom-sca/organization_linux_baseline.yml
```

И подключайте её явно:

```xml
<sca>
  <policies>
    <policy>/var/ossec/etc/custom-sca/organization_linux_baseline.yml</policy>
  </policies>
</sca>
```

Можно использовать и relative path; relative SCA paths разрешаются относительно Wazuh installation directory.

## Минимальная структура custom policy

Custom policy требует секции `policy` и `checks`.

Пример небольшой SSH hardening policy:

```yaml
policy:
  id: "org_linux_baseline"
  file: "organization_linux_baseline.yml"
  name: "Organization Linux baseline"
  description: "Selected local hardening controls for Linux servers"

checks:
  - id: 10001
    title: "SSH root login is disabled"
    description: "Root should not be allowed to authenticate directly over SSH."
    condition: all
    rules:
      - 'f:/etc/ssh/sshd_config -> !r:^\s*PermitRootLogin\s+yes\b'
```

Держите custom checks небольшими и проверяемыми. Не превращайте целый hardening guide в одну монолитную policy до того, как rule syntax проверена на реальных системах.

## Валидируйте через canary

Перед широким rollout:

1. разместите policy на одном representative/non-critical endpoint;
2. включите её явно;
3. перезапустите agent или дождитесь schedule;
4. подтвердите local completion message;
5. убедитесь, что policy появилась centrally;
6. вручную проверьте каждый важный failed check на endpoint.

Для SSH-примера:

```bash
sshd -T | grep -i '^permitrootlogin '
```

Runtime daemon configuration полезнее простого grep одного файла, потому что includes и distribution defaults могут менять effective behavior.

## Failed SCA check — finding, а не готовая remediation команда

Каждый failed control нужно классифицировать.

Он может быть:

- реальной misconfiguration;
- accepted exception;
- not applicable для host role;
- false positive из-за policy syntax;
- check статической конфигурации, отличающейся от effective runtime behavior.

Это критично, потому что механическое применение security baseline способно сломать production service.

## Rollout через agent groups

Для множества систем одной роли centralized group configuration обычно чище, чем ручное редактирование `ossec.conf` на каждом server.

Group может содержать `agent.conf` и shared files. Custom policy можно подключить так:

```xml
<agent_config>
  <sca>
    <policies>
      <policy>etc/shared/organization_linux_baseline.yml</policy>
    </policies>
  </sca>
</agent_config>
```

Policy file размещается в shared directory группы на Wazuh server, а agent получает shared files в своём `etc/shared`.

Используйте role-based groups вместо одной global policy, если server functions заметно различаются. Mail server, hypervisor, database host и general-purpose Linux VM не должны автоматически наследовать одинаковые hardening expectations.

## Осторожно с remote commands

Централизованно distributed SCA policies могут содержать checks, которые выполняют commands, но это требует дополнительного разрешения на agent.

Remote SCA command execution по умолчанию выключен. Для включения нужен:

```text
sca.remote_commands=1
```

в local internal options agent.

Не включайте это только ради удобства централизованной distribution. File/directory/configuration checks не требуют этой capability, если policy можно выразить без command execution.

Remote commands расширяют последствия compromise Wazuh server. Рассматривайте это как отдельное security decision, а не обычную настройку SCA.

## Предпочитайте локальные checks, если их достаточно

Для многих hardening controls хватает встроенных rule types:

- наличие/отсутствие файлов;
- file content;
- directory checks;
- process checks;
- package/configuration state, поддерживаемый SCA syntax.

Command execution используйте только когда требуемое effective state нельзя надёжно проверить обычными средствами.

Так policies проще review'ить и меньше endpoint execution risk.

## Планируйте scan schedule осознанно

SCA поддерживает `scan_on_start`, `interval`, day-of-week, day-of-month и explicit time scheduling.

Пример ежедневного schedule:

```xml
<sca>
  <enabled>yes</enabled>
  <scan_on_start>yes</scan_on_start>
  <interval>1d</interval>
  <time>04:00</time>
</sca>
```

Не запускайте сотни или тысячи agents в одну и ту же минуту без необходимости. При заметной нагрузке на manager/indexer разносите scans по roles/groups.

## Проверяйте после Wazuh upgrades

Upgrade может изменить:

- bundled policy set;
- individual checks;
- agent behavior при обработке configuration/files.

После upgrade снова валидируйте representative endpoint, а не считайте старое распределение pass/fail напрямую сопоставимым.

Проверьте version:

```bash
/var/ossec/bin/wazuh-control info
```

Затем убедитесь, что scan завершается, а custom policy остаётся в persistent location вне vendor ruleset.

## Troubleshooting: нет новых SCA results

Начинайте с endpoint, а не dashboard.

```bash
systemctl is-active wazuh-agent

grep -Ei 'sca: INFO:|sca: WARNING:|sca: ERROR:' \
  /var/ossec/logs/ossec.log | tail -100
```

Проверьте существование custom file:

```bash
ls -l /var/ossec/etc/custom-sca/
ls -l /var/ossec/etc/shared/
```

Проверьте active configuration:

```bash
grep -n -A30 -B2 '<sca>' /var/ossec/etc/ossec.conf
```

Если задействована centralized configuration, убедитесь, что agent находится в правильной group и group config валиден.

Не перезапускайте agent бесконечно без чтения log. Повторные restart могут утопить исходную configuration error в шумном timeline.

## Troubleshooting: policy есть, но checks выглядят неверно

Чаще это указывает на policy, а не на transport path.

Возьмите один failed check и вручную воспроизведите condition на endpoint. Для file-based rules проверьте точный file и permissions. Для process rules — live process table. Для effective daemon configuration используйте собственную validation command сервиса, если она есть.

Security scanner заслуживает доверия только настолько, насколько корректна семантика его rules.

## Troubleshooting: custom policy исчезает после update

Если policy лежала в `/var/ossec/ruleset/sca`, перенесите её в persistent custom location и подключайте явно.

Custom files, которые должны переживать package lifecycle, не должны зависеть от vendor-owned ruleset directory.

## Безопасный remediation workflow

Для реального failed control:

1. определите host role;
2. вручную подтвердите finding;
3. сохраните текущую конфигурацию;
4. меняйте один control за раз;
5. проверьте service/application после изменения;
6. повторите SCA;
7. убедитесь, что check перешёл из failed в passed;
8. документируйте accepted exceptions.

Это создаёт feedback loop между detection и hardening, не превращая SCA в неконтролируемую configuration-management систему.

## Пример validation после remediation

После изменения SSH setting:

```bash
sudo sshd -t
sudo systemctl reload sshd
sshd -T | grep -i '^permitrootlogin '
```

После этого снова дождитесь SCA и подтвердите central result.

Service validation важнее зелёного check. Control, который проходит ценой потери production access, не является успешным hardening change.

## Stop conditions

Останавливайте rollout policy, если:

- agent перестал завершать SCA scans;
- custom policy даёт массовые failures, которые нельзя воспроизвести вручную;
- role-specific systems получают неподходящий global baseline;
- distribution требует remote commands без review необходимости;
- agent update перезаписывает/удаляет custom policies;
- remediation вызывает service regression;
- central results отстают от endpoint log.

Hardening program должен fail safely, если evidence неоднозначен.

## Operational pattern

Практичная production-модель:

- vendor SCA policies для baseline visibility;
- небольшие custom policies для organization-specific controls;
- role-based agent groups;
- canary rollout перед fleet-wide changes;
- manual verification важных failed checks;
- explicit exception handling;
- отсутствие remote command execution без реальной необходимости.

Так Wazuh SCA остаётся инженерным control, а не ещё одним dashboard с непроверенными compliance percentages.

## References

- Wazuh Security Configuration Assessment: <https://documentation.wazuh.com/current/user-manual/capabilities/sec-config-assessment/index.html>
- How to configure SCA: <https://documentation.wazuh.com/current/user-manual/capabilities/sec-config-assessment/how-to-configure.html>
- SCA configuration reference: <https://documentation.wazuh.com/current/user-manual/reference/ossec-conf/sca.html>
- Creating custom SCA policies: <https://documentation.wazuh.com/current/user-manual/capabilities/sec-config-assessment/creating-custom-policies.html>
