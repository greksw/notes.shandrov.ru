---
title: "Wazuh SCA: проверка сканирований и безопасное внедрение собственных политик"
description: "Практический workflow для проверки Wazuh Security Configuration Assessment, безопасного добавления собственных политик и подтверждения результатов без лишнего расширения attack surface."
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

1. агент действительно запускает ожидаемую policy;
2. результат доходит до Wazuh server и виден централизованно;
3. failed check означает реальный hardening gap, а не ошибку самой policy.

Типичная эксплуатационная ошибка — посмотреть только dashboard и считать результат доказанным. В production нужно проверять всю цепочку: policy file на endpoint → локальный SCA scan → agent log → central visibility → remediation.

Этот runbook посвящён именно такой проверке.

## Что проверяет Wazuh SCA

SCA policies — YAML-файлы с checks. В зависимости от rule type они могут анализировать:

- файлы и их содержимое;
- каталоги;
- registry values;
- процессы;
- локальное состояние конфигурации.

На Linux стандартные policies обычно находятся здесь:

```text
/var/ossec/ruleset/sca
```

Собственные policy не стоит редактировать прямо в этом каталоге: package upgrade может заменить vendor files.

## Зафиксируйте исходное состояние

На agent:

```bash
/var/ossec/bin/wazuh-control info
systemctl status wazuh-agent --no-pager
```

Проверьте блок SCA:

```bash
grep -n -A20 -B2 '<sca>' /var/ossec/etc/ossec.conf
```

Посмотрите доступные policy:

```bash
find /var/ossec/ruleset/sca -maxdepth 1 -type f \
  \( -name '*.yml' -o -name '*.yaml' \) -printf '%f\n' | sort
```

Не предполагайте, что все policies, присутствующие на manager, автоматически есть на каждом endpoint.

## Убедитесь, что SCA включён

Пример явной конфигурации:

```xml
<sca>
  <enabled>yes</enabled>
  <scan_on_start>yes</scan_on_start>
  <interval>12h</interval>
  <skip_nfs>yes</skip_nfs>
</sca>
```

Интервал выбирается по операционным требованиям. SCA — это assessment configuration state, а не high-frequency monitoring.

На Linux `skip_nfs` полезен на серверах с сетевыми файловыми системами, чтобы сканирование не обходило удалённые деревья без необходимости.

## Запустите контролируемую проверку

Если `scan_on_start` включён:

```bash
sudo systemctl restart wazuh-agent
```

Проверьте локальный log:

```bash
grep -Ei 'sca: INFO:|sca: WARNING:|sca: ERROR:' \
  /var/ossec/logs/ossec.log | tail -50
```

Успешное завершение должно сопровождаться сообщением вида:

```text
sca: INFO: Security Configuration Assessment scan finished.
```

Локальный log важен: dashboard может показывать предыдущий результат и не доказывает, что новый scan действительно завершился после изменения конфигурации.

## Сопоставьте локальный и центральный результат

После завершения scan проверьте тот же endpoint в Wazuh dashboard.

Убедитесь, что:

- отображается ожидаемая policy;
- timestamp актуален;
- pass/fail counts меняются после контролируемого изменения условия;
- dashboard не показывает старый cached result при локальной ошибке SCA.

Для большого fleet сначала используйте один canary agent.

## Не редактируйте vendor policy на месте

Создайте отдельный каталог для собственных политик:

```bash
sudo install -d -m 0750 -o root -g wazuh /var/ossec/etc/custom-sca
```

Например:

```text
/var/ossec/etc/custom-sca/organization_linux_baseline.yml
```

И подключите policy явно:

```xml
<sca>
  <policies>
    <policy>/var/ossec/etc/custom-sca/organization_linux_baseline.yml</policy>
  </policies>
</sca>
```

Можно использовать и relative path; он разрешается относительно каталога установки Wazuh.

## Минимальная структура собственной policy

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

Держите собственные checks небольшими и проверяемыми. Не превращайте целый hardening guide в одну монолитную policy до проверки синтаксиса на реальных системах.

## Проверяйте через canary

Перед широким rollout:

1. разместите policy на одном representative/non-critical endpoint;
2. включите её явно;
3. перезапустите agent или дождитесь schedule;
4. подтвердите локальное завершение SCA;
5. убедитесь, что policy появилась centrally;
6. вручную проверьте каждый важный failed check.

Для SSH-примера:

```bash
sshd -T | grep -i '^permitrootlogin '
```

Runtime configuration полезнее простого grep одного файла, потому что includes и distribution defaults могут менять фактическое поведение daemon.

## Failed check — это finding, а не готовая команда исправления

Каждый failed control нужно классифицировать.

Он может быть:

- реальной misconfiguration;
- accepted exception;
- not applicable для конкретной роли host;
- false positive из-за policy syntax;
- проверкой статического файла, которая не отражает effective runtime state.

Механическое применение security baseline может сломать production service.

## Используйте agent groups

Для нескольких систем одной роли централизованная group configuration обычно лучше ручного редактирования `ossec.conf` на каждом server.

Пример `agent.conf`:

```xml
<agent_config>
  <sca>
    <policies>
      <policy>etc/shared/organization_linux_baseline.yml</policy>
    </policies>
  </sca>
</agent_config>
```

Policy file размещается в shared directory группы на Wazuh server и доставляется агенту в `etc/shared`.

Используйте role-based groups. Mail server, hypervisor, database host и обычный Linux server не обязаны иметь один и тот же hardening baseline.

## Осторожно с remote commands

SCA policy может выполнять commands, но это требует дополнительного разрешения на agent.

По умолчанию remote SCA command execution выключен. Для включения используется:

```text
sca.remote_commands=1
```

Не включайте эту возможность только ради удобства distribution. Если проверку можно выразить через files/directories/processes, remote commands не нужны.

Это отдельное security decision, потому что компрометация Wazuh server при включённых remote commands расширяет потенциальное воздействие на endpoints.

## Предпочитайте локальные checks

Для большинства hardening controls достаточно встроенных типов:

- наличие или отсутствие файла;
- содержимое файла;
- directory checks;
- process checks;
- поддерживаемое SCA состояние пакетов и конфигурации.

Command execution стоит использовать только когда нужное effective state нельзя надёжно проверить иначе.

## Планируйте расписание осознанно

Пример ежедневного запуска:

```xml
<sca>
  <enabled>yes</enabled>
  <scan_on_start>yes</scan_on_start>
  <interval>1d</interval>
  <time>04:00</time>
</sca>
```

Не запускайте сотни или тысячи agents в одну минуту без необходимости. При заметной нагрузке на manager/indexer распределяйте scans по группам и ролям.

## Проверяйте SCA после обновления Wazuh

Upgrade может изменить:

- bundled policies;
- отдельные checks;
- поведение agent при обработке configuration и files.

После обновления снова проверьте representative endpoint:

```bash
/var/ossec/bin/wazuh-control info
```

Убедитесь, что scan завершается, а собственная policy остаётся в persistent location вне vendor ruleset.

## Troubleshooting: новых результатов нет

Начинайте с endpoint:

```bash
systemctl is-active wazuh-agent

grep -Ei 'sca: INFO:|sca: WARNING:|sca: ERROR:' \
  /var/ossec/logs/ossec.log | tail -100
```

Проверьте наличие custom files:

```bash
ls -l /var/ossec/etc/custom-sca/
ls -l /var/ossec/etc/shared/
```

И active configuration:

```bash
grep -n -A30 -B2 '<sca>' /var/ossec/etc/ossec.conf
```

Если используется centralized configuration, убедитесь, что agent действительно находится в нужной group и её config валиден.

Не перезапускайте agent бесконечно без чтения log: повторные restart только усложнят timeline.

## Troubleshooting: policy есть, но checks неверны

Возьмите один failed check и воспроизведите условие вручную на endpoint.

Для file-based rules проверьте точный файл и permissions. Для process rules — live process table. Для effective daemon configuration используйте штатную validation command самого сервиса, если она есть.

Scanner заслуживает доверия только настолько, насколько корректна семантика его rules.

## Безопасное исправление

Для подтверждённого finding:

1. определите роль host;
2. подтвердите finding вручную;
3. сохраните текущую конфигурацию;
4. меняйте один control за раз;
5. проверьте сервис после изменения;
6. повторите SCA;
7. убедитесь, что check перешёл из failed в passed;
8. документируйте accepted exceptions.

После изменения SSH setting:

```bash
sudo sshd -t
sudo systemctl reload sshd
sshd -T | grep -i '^permitrootlogin '
```

Сначала убедитесь, что сервис работает, и только потом оценивайте зелёный check.

## Условия остановки

Останавливайте rollout policy, если:

- agent перестал завершать SCA scans;
- custom policy даёт массовые failures, которые нельзя воспроизвести вручную;
- role-specific systems получают неподходящий global baseline;
- rollout требует включить remote commands без обоснованной необходимости;
- update удаляет custom policy;
- remediation ломает production service;
- central results явно устарели по сравнению с локальным log.

## Рабочая модель

Практичный production-подход:

- vendor policies для базовой видимости;
- небольшие собственные policies для внутренних требований;
- role-based agent groups;
- canary rollout;
- ручная проверка важных failed checks;
- документированные exceptions;
- remote commands только при реальной необходимости.

Так Wazuh SCA остаётся инженерным инструментом, а не просто dashboard с процентами compliance.

## References

- Wazuh Security Configuration Assessment: <https://documentation.wazuh.com/current/user-manual/capabilities/sec-config-assessment/index.html>
- How to configure SCA: <https://documentation.wazuh.com/current/user-manual/capabilities/sec-config-assessment/how-to-configure.html>
- SCA configuration reference: <https://documentation.wazuh.com/current/user-manual/reference/ossec-conf/sca.html>
- Creating custom SCA policies: <https://documentation.wazuh.com/current/user-manual/capabilities/sec-config-assessment/creating-custom-policies.html>
