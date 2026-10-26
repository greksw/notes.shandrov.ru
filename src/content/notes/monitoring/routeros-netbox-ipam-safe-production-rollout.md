---
title: "Safe production rollout of an IPAM auditor: pinned release, systemd rollback and next-day verification"
description: "A practical RouterOS–NetBox IPAM auditor migration without interrupting monitoring: pinned GitHub commit, 121 offline tests, shadow metrics, systemd drop-in and scheduled-run validation."
category: "Monitoring & Security"
tags: ["netbox", "mikrotik", "routeros", "ipam", "prometheus", "systemd", "github", "rollback", "drift-detection", "operations"]
published: 2026-10-26
updated: 2026-10-26
status: current
testedOn: ["MikroTik RouterOS 7", "NetBox 4.7.3", "Python 3.11", "AlmaLinux 9", "Node Exporter", "Prometheus", "systemd"]
featured: false
lang: en
translationKey: "monitoring/routeros-netbox-ipam-safe-production-rollout"
---

## The problem: replacing a working auditor without losing monitoring

The earlier guides covered [read-only RouterOS–NetBox reconciliation](/notes/monitoring/routeros-netbox-ipam-drift-ssh-readonly/) and [systemd, Prometheus and Alertmanager integration](/notes/monitoring/routeros-netbox-ipam-prometheus-alerting/). The first working deployment still used private local wrappers. When [PR #16 in NetBox Inventory Toolkit](https://github.com/greksw/netbox-inventory-toolkit/pull/16) was merged, a generic codebase became available: an SSH collector, NetBox HTTPS GET adapter, CLI, textfile exporter, unit tests and systemd templates.

The goal was **not** a fresh installation, but a controlled transition to the public implementation without changing the running timer, the Prometheus alert rules, or the RouterOS and NetBox configurations.

Company-specific hostnames, actual asset counts, server paths, IP addresses and VPN details are deliberately omitted. Commands are patterns requiring local review, **not** a fully automated production upgrade.

## 01 / The compatibility contract

| Exit code | Meaning | Status metric | Response |
| --- | --- | --- | --- |
| \`0\` | \`CLEAN\`: complete evidence, no drift | \`0\` | Continue monitoring |
| \`1\` | \`DRIFT\`: validated discrepancy | \`1\` | Investigate changes |
| \`2\` | \`ERROR\`: missing/incomplete evidence | \`2\` | Restore audit collection |

The generic CLI expects a root-owned, mode \`0600\` JSON configuration with a RouterOS target, exact NetBox selectors, paths to a private SSH identity, trusted CA and separate NetBox API token file, approved baseline counts and individually reviewed dynamic exceptions. The secret token is **not embedded** in the config or Git repository.

RouterOS access uses two allowlisted, read-only SSH queries. NetBox is queried through TLS-verified HTTPS GET using a view-only API token. The collector cannot modify either endpoint.

## 02 / Stage a pinned GitHub revision

Git is optional on the monitoring host. Instead of overwriting a working directory or downloading the changing main branch, fetch an archive identified by a reviewed, full commit SHA.

\`\`\`bash
REV="REVIEWED_FULL_COMMIT_SHA"
STAGE="/opt/netbox-inventory-toolkit-$(printf '%s' "$REV" | cut -c1-7)"
TMP="$(mktemp -d)"
# Verify the commit against the reviewed PR and successful CI.
curl -fLsS \
  "https://codeload.github.com/greksw/netbox-inventory-toolkit/tar.gz/$REV" \
  -o "$TMP/source.tar.gz"
tar -tzf "$TMP/source.tar.gz" >/dev/null
install -d -m 0755 "$STAGE"
tar -xzf "$TMP/source.tar.gz" -C "$STAGE" \
  --strip-components=1 --no-same-owner
cd "$STAGE"
python3.11 -m compileall -q routeros tests
python3.11 -m unittest discover -s tests -q
\`\`\`

The real staging operation passed **121 offline tests**. The test suite includes mocked Zabbix operations that can print \`CREATE ...\`; these do not create objects on production Zabbix. The tests did not modify production RouterOS or NetBox.

Commit pinning supports reproducibility but does not replace source review and supply-chain verification.

## 03 / Compare a standalone audit and shadow metrics

Before touching systemd, run the generic collector against the local private configuration.

\`\`\`bash
cd /opt/netbox-inventory-toolkit-REVIEWED_SHA
python3.11 -m routeros.run_local_audit \
  --config /etc/netbox-inventory/routeros-ipam.json
echo "Audit RC: $?"
\`\`\`

The configuration is derived from a [public documentation-only example](https://github.com/greksw/netbox-inventory-toolkit/blob/main/examples/routeros-ipam.json.example). The local file must be root-owned with restrictive permissions. Only run it after reviewing the baseline counts and each approved dynamic IP exception.

Once the collector returns \`CLEAN\`, run the new metrics exporter in a **separate temporary directory**, leaving the actual Node Exporter collector untouched.

\`\`\`bash
TMP_METRICS="$(mktemp -d /root/ipam-shadow.XXXXXX)"
cd /opt/netbox-inventory-toolkit-REVIEWED_SHA
python3.11 -m routeros.textfile_export --output-dir "$TMP_METRICS"
grep -E '^netbox_routeros_ipam_audit_(status|differences) ' \
  "$TMP_METRICS/netbox-routeros-ipam.prom"
# Remove the temporary directory after reviewing the output.
\`\`\`

Compare the zero status and differences **as well as** VLAN counts, static and dynamic IPv4 counts, and timestamp. Some generic count metrics have different suffixes than the original private exporter (such as \`_static_ipv4\` instead of \`_static_ips\`), so compare the meaning and values rather than every name.

The existing alert rules still use the unchanged core series:

\`\`\`text
netbox_routeros_ipam_audit_status
netbox_routeros_ipam_audit_differences
netbox_routeros_ipam_audit_timestamp_seconds
\`\`\`

The exporter atomically replaces one metrics file. Nonsecret numeric metrics are readable by the unprivileged Node Exporter with mode \`0644\`; private configuration, tokens and SSH keys remain mode \`0600\`. SELinux contexts must also allow access.

## 04 / A single systemd drop-in with rollback

Keep the original service file unchanged, and back up the original unit, effective \`systemctl cat\` output and current metrics file. A separate drop-in changes only the executable path:

\`\`\`ini
# /etc/systemd/system/netbox-routeros-ipam.service.d/90-universal-exporter.conf
[Service]
WorkingDirectory=/opt/netbox-inventory-toolkit-REVIEWED_SHA
ExecStart=
ExecStart=/usr/bin/python3.11 -m routeros.textfile_export --output-dir /var/lib/node_exporter/textfile_collector
SuccessExitStatus=1
\`\`\`

The empty \`ExecStart=\` resets the previous command. \`SuccessExitStatus=1\` treats a completed audit reporting \`DRIFT\` as a normal systemd invocation, while Prometheus still publishes status \`1\`; a collector \`ERROR\` (exit code \`2\`) is still a systemd failure.

After \`systemd-analyze verify\` and \`daemon-reload\`, execute one controlled smoke test. Inspect \`Result\`, \`ExecMainStatus\`, \`WorkingDirectory\`, file permissions, \`node_textfile_scrape_error\` and the actual Node Exporter metrics.

For rollback, remove **only the newly created drop-in**, run \`systemctl daemon-reload\`, and start the previous service using the approved local rollback procedure. Never remove unrelated drop-ins.

## 05 / The following day's scheduled run completes acceptance

A successful manual \`systemctl start\` validates only one invocation. The key acceptance gate is the **first unattended scheduled timer execution**.

On **22 October 2026**, the first post-migration scheduled run completed with exit code \`0\`; the journal recorded \`ROUTEROS IPAM METRICS: CLEAN\` and \`Differences: 0\`. The metrics file modification timestamp matched the scheduled execution. Prometheus observed a fresh audit timestamp and Node Exporter reported no textfile errors.

Reusable, read-only checks:

\`\`\`bash
systemctl list-timers --all netbox-routeros-ipam.timer
systemctl show netbox-routeros-ipam.service \
  -p Result -p ExecMainStatus -p WorkingDirectory
journalctl -u netbox-routeros-ipam.service --since today --no-pager
stat -c '%y %a %U:%G' \
  /var/lib/node_exporter/textfile_collector/netbox-routeros-ipam.prom
\`\`\`

Prometheus queries confirmed \`up == 1\`, \`node_textfile_scrape_error == 0\`, \`netbox_routeros_ipam_audit_status == 0\`, zero differences and a same-day timestamp. All four rules—\`Drift\`, \`AuditError\`, \`AuditStale\` and \`AuditMissing\`—were \`inactive\` with \`health=ok\`.

Immediately after a Prometheus configuration reload, alert states can temporarily appear as \`unknown\` until the first evaluation. Allow for the rule evaluation interval and then inspect \`/api/v1/rules?type=alert\` again.

## 06 / Boundaries of the verification

- An \`amtool config routes test\` checked Alertmanager receiver routing. This is **not proof** of end-to-end delivery of an actual IPAM alert. Previous email/webhook notification counters are likewise not specific to this audit.
- An individually reviewed dynamic IKEv2/IPsec Mode Config IPv4 assignment is excluded from static drift comparisons. The audit checks the exact assignment's presence, but **does not** prove its IPsec peer, policy and NAT provenance during every run.
- The system is a read-only drift detector, not an automated remediation tool or a bidirectional NetBox synchronizer.

## Outcome

The rollout used **offline tests → pinned release → parallel audit → shadow metrics → systemd drop-in → Prometheus validation → independent next-day scheduled execution**.

Publishing generic, reproducible code did not require replacing the live implementation without a safety net: the old audit remained available until the new one reproduced its results.

Related guides: [read-only IPAM audit](/notes/monitoring/routeros-netbox-ipam-drift-ssh-readonly/), [Prometheus monitoring](/notes/monitoring/routeros-netbox-ipam-prometheus-alerting/) and [live-monitoring documentation](https://github.com/greksw/netbox-inventory-toolkit/blob/main/docs/routeros-ipam-live-monitoring.md).
