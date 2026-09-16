---
title: "Wazuh SCA: validating scans and rolling out custom hardening policies"
description: "A production-oriented workflow for verifying Wazuh Security Configuration Assessment, adding custom policies safely and validating results without broadening endpoint attack surface unnecessarily."
category: "Monitoring & Security"
tags: ["wazuh", "sca", "hardening", "security", "cis", "compliance"]
published: 2026-09-16
updated: 2026-09-16
status: current
testedOn: ["Wazuh 4.14.x", "AlmaLinux 9", "Linux agents"]
featured: true
---

## Context

Security Configuration Assessment is useful only when three things are true at the same time:

1. the agent is actually running the expected policy;
2. the result reaches the Wazuh server and is visible centrally;
3. a failed check represents a real hardening gap rather than a broken policy or path.

The operational mistake is to treat the dashboard as the source of truth and stop there. A production rollout should validate the entire path from the policy file on the endpoint to the local SCA scan, agent log, central visibility and remediation workflow.

This runbook focuses on that validation chain and on safe rollout of custom policies.

## What Wazuh SCA evaluates

Wazuh SCA policies are YAML files containing checks. Depending on the rule type, a check can inspect files, directories, registry values, processes and other local configuration state.

Wazuh agents normally ship with an operating-system-specific policy in the default SCA ruleset directory. On Linux agents that directory is:

```text
/var/ossec/ruleset/sca
```

Custom policy files should not be edited directly in that default ruleset path. Package upgrades can replace files there, so production custom policies should live in a separate persistent location and be referenced explicitly.

## Establish a baseline before changing anything

On the agent, record the installed version and current service state:

```bash
/var/ossec/bin/wazuh-control info
systemctl status wazuh-agent --no-pager
```

Inspect the SCA block from the active configuration:

```bash
grep -n -A20 -B2 '<sca>' /var/ossec/etc/ossec.conf
```

List currently available policies:

```bash
find /var/ossec/ruleset/sca -maxdepth 1 -type f \
  \( -name '*.yml' -o -name '*.yaml' \) -printf '%f\n' | sort
```

Do not assume that every policy present on the manager is also installed on every endpoint. The agent normally receives the policy relevant to its operating system.

## Verify that SCA is enabled

The module can be controlled through the `<sca>` section in `ossec.conf`.

A minimal explicit configuration looks like this:

```xml
<sca>
  <enabled>yes</enabled>
  <scan_on_start>yes</scan_on_start>
  <interval>12h</interval>
  <skip_nfs>yes</skip_nfs>
</sca>
```

The exact interval is an operational choice. Avoid very short intervals on large fleets unless there is a clear reason; SCA is configuration assessment, not a per-second monitoring mechanism.

On Linux, `skip_nfs` also excludes CIFS/NFS mounted filesystems from scanning when enabled. That is often desirable on servers with network storage because SCA checks should not accidentally traverse remote trees.

## Trigger a controlled validation scan

Restarting the agent is a simple way to trigger a scan when `scan_on_start` is enabled:

```bash
sudo systemctl restart wazuh-agent
```

Then inspect the local agent log:

```bash
grep -Ei 'sca: INFO:|sca: WARNING:|sca: ERROR:' \
  /var/ossec/logs/ossec.log | tail -50
```

A successful run should include a completion message similar to:

```text
sca: INFO: Security Configuration Assessment scan finished.
```

The important point is that the endpoint has direct evidence that the SCA engine ran. A dashboard result alone does not prove that the latest local scan completed after your configuration change.

## Correlate local and central state

After the local scan completes, verify the corresponding endpoint in the Wazuh dashboard under Configuration Assessment.

Check that:

- the expected policy name is present;
- the scan timestamp is current;
- pass/fail counts changed when an intentional test condition changed;
- the endpoint is not showing an old cached result while the agent is currently failing to scan.

For a large fleet, validate one canary agent first instead of pushing a new policy to an entire server group.

## Do not modify vendor policies in place

Wazuh documents that files under the default SCA ruleset directory are not guaranteed to survive installation or upgrade changes.

If the organization needs additional hardening checks, create a dedicated path, for example:

```bash
sudo install -d -m 0750 -o root -g wazuh /var/ossec/etc/custom-sca
```

Store the custom policy there:

```text
/var/ossec/etc/custom-sca/organization_linux_baseline.yml
```

Then reference it explicitly in the SCA configuration:

```xml
<sca>
  <policies>
    <policy>/var/ossec/etc/custom-sca/organization_linux_baseline.yml</policy>
  </policies>
</sca>
```

A relative path can also be used; relative SCA paths are resolved from the Wazuh installation directory.

## Minimal custom policy structure

A custom policy needs a `policy` section and a `checks` section.

A small example that checks SSH hardening could look like this:

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

Keep custom checks narrow and testable. Do not convert an entire hardening guide into one monolithic policy before validating the rule syntax against real systems.

## Validate policy syntax and behavior with a canary

Before a broad rollout:

1. place the policy on one non-critical or representative endpoint;
2. enable it explicitly;
3. restart the agent or wait for the configured schedule;
4. confirm that the local log shows a completed SCA scan;
5. verify the policy appears centrally;
6. inspect each failed check manually on the endpoint.

For the SSH example:

```bash
sshd -T | grep -i '^permitrootlogin '
```

The runtime daemon configuration is more useful than simply grepping one configuration file when includes or distribution defaults can alter effective behavior.

## A failed SCA check is a finding, not automatically a remediation command

Treat failed checks as evidence that requires classification.

For every failed control, determine whether it is:

- a real misconfiguration;
- an accepted exception;
- not applicable to that host role;
- a false positive caused by policy syntax;
- a check against static configuration that differs from effective runtime behavior.

This distinction matters because security baselines can break production services when applied mechanically.

## Roll out policies through agent groups

For multiple systems with the same role, centralized group configuration is usually cleaner than editing `ossec.conf` separately on every server.

On the Wazuh server, a group can carry an `agent.conf` and shared files. A custom policy distributed to a group is referenced from the shared configuration, for example:

```xml
<agent_config>
  <sca>
    <policies>
      <policy>etc/shared/organization_linux_baseline.yml</policy>
    </policies>
  </sca>
</agent_config>
```

The policy file itself is placed in the group's shared directory on the Wazuh server. The agent receives shared files below its `etc/shared` directory.

Use role-based groups rather than a single global policy when server functions differ significantly. A mail server, hypervisor, database host and general-purpose Linux VM should not automatically inherit identical hardening expectations.

## Be careful with remote commands in SCA policies

Wazuh can distribute SCA policies centrally, but checks that execute commands require additional permission on the agent.

Remote SCA command execution is disabled by default. Enabling it requires:

```text
sca.remote_commands=1
```

in the agent's local internal options.

Do not enable this merely because centralized policy distribution is convenient. File, directory and configuration checks do not require opening that capability if the custom policy can be written without command execution.

Enabling remote commands expands what a compromised Wazuh server could execute on endpoints. Treat it as a separate security decision, not as a routine SCA setting.

## Prefer local-file checks when they are sufficient

For common hardening controls, built-in SCA rule types are usually enough:

- presence or absence of files;
- file content;
- directory checks;
- process checks;
- package/configuration state supported by the SCA syntax.

Only use command execution when the required effective state cannot be expressed reliably through ordinary checks.

This keeps custom policies easier to review and reduces endpoint execution risk.

## Schedule scans intentionally

The SCA module supports `scan_on_start`, `interval`, day-of-week, day-of-month and explicit time scheduling.

Example daily schedule:

```xml
<sca>
  <enabled>yes</enabled>
  <scan_on_start>yes</scan_on_start>
  <interval>1d</interval>
  <time>04:00</time>
</sca>
```

Avoid scheduling every server at the same minute if the environment contains hundreds or thousands of agents. Stagger scans by role or group if manager/indexer load becomes noticeable.

## Validate after Wazuh upgrades

An upgrade can change three things that matter to SCA:

- the bundled policy set;
- individual policy checks;
- agent behavior around configuration or file handling.

After an upgrade, validate a representative endpoint again rather than assuming an old pass/fail distribution is directly comparable.

Check the installed agent version:

```bash
/var/ossec/bin/wazuh-control info
```

Then confirm that the scan finishes and the expected custom policy remains present outside the vendor ruleset directory.

## Troubleshooting: no new SCA results

Start at the endpoint rather than at the dashboard.

```bash
systemctl is-active wazuh-agent

grep -Ei 'sca: INFO:|sca: WARNING:|sca: ERROR:' \
  /var/ossec/logs/ossec.log | tail -100
```

Then check whether the custom file exists where the configuration expects it:

```bash
ls -l /var/ossec/etc/custom-sca/
ls -l /var/ossec/etc/shared/
```

Inspect the active configuration:

```bash
grep -n -A30 -B2 '<sca>' /var/ossec/etc/ossec.conf
```

If centralized configuration is involved, verify that the agent is actually assigned to the intended group and that the group's configuration is valid.

Do not keep restarting the agent without reading the log. Repeated restarts can hide the original configuration error in a noisy timeline.

## Troubleshooting: policy appears but all checks are wrong

This usually points to the policy rather than to the transport path.

Take one failed check and reproduce the condition manually on the endpoint. For file-based rules, inspect the exact file and permissions. For process rules, compare with the live process table. For effective daemon configuration, use the daemon's own validation command when available.

A security scanner is only as trustworthy as the rule semantics being tested.

## Troubleshooting: custom policy disappears after update

If the policy was stored under `/var/ossec/ruleset/sca`, move it to a persistent custom location and reference it explicitly.

Custom files that need to survive package lifecycle should not depend on the vendor-owned ruleset directory.

## Safe remediation workflow

For a real failed control:

1. identify the affected host role;
2. verify the finding manually;
3. capture the current configuration;
4. change one control at a time;
5. validate the service or application after the change;
6. rerun SCA;
7. confirm the check changes from failed to passed;
8. document accepted exceptions rather than repeatedly rediscovering them.

This creates a feedback loop between detection and hardening without turning SCA into an uncontrolled configuration-management system.

## Example validation after remediation

After changing an SSH setting:

```bash
sudo sshd -t
sudo systemctl reload sshd
sshd -T | grep -i '^permitrootlogin '
```

Then rerun or wait for SCA and confirm the result changes centrally.

The service validation must come before celebrating the green check. A control that passes while breaking production access is not a successful hardening change.

## Stop conditions

Stop a policy rollout if any of the following occurs:

- the agent stops completing SCA scans;
- a custom policy produces widespread failures that cannot be reproduced manually;
- role-specific systems are receiving an inappropriate global baseline;
- policy distribution requires enabling remote commands without a reviewed need;
- an agent update overwrites or removes custom policy files;
- remediation causes a service regression;
- central results are stale compared with the endpoint log.

A hardening program should fail safely when the evidence is ambiguous.

## Operational pattern

A practical production model is:

- vendor SCA policies for baseline visibility;
- small custom policies for organization-specific controls;
- role-based agent groups;
- canary rollout before fleet-wide changes;
- local verification of every important failed check;
- explicit exception handling;
- no remote command execution unless the policy genuinely needs it.

That approach keeps Wazuh SCA useful as an engineering control rather than turning it into another dashboard full of unverified compliance percentages.

## References

- Wazuh Security Configuration Assessment: <https://documentation.wazuh.com/current/user-manual/capabilities/sec-config-assessment/index.html>
- How to configure SCA: <https://documentation.wazuh.com/current/user-manual/capabilities/sec-config-assessment/how-to-configure.html>
- SCA configuration reference: <https://documentation.wazuh.com/current/user-manual/reference/ossec-conf/sca.html>
- Creating custom SCA policies: <https://documentation.wazuh.com/current/user-manual/capabilities/sec-config-assessment/creating-custom-policies.html>
