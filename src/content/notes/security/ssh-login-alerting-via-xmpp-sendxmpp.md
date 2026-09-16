---
title: "SSH login alerts via XMPP with sendxmpp and verified TLS"
description: "A production-oriented pattern for sending SSH login notifications to a self-hosted XMPP server without Telegram, embedded credentials or disabled TLS verification."
category: "Monitoring & Security"
tags: ["ssh", "xmpp", "jabber", "sendxmpp", "security", "linux"]
published: 2026-09-16
updated: 2026-09-16
status: current
testedOn: ["sendxmpp", "OpenSSH", "Linux"]
featured: true
translationKey: "security/ssh-login-alerting-via-xmpp-sendxmpp"
---

## Context

SSH login notifications are a useful secondary visibility signal, but the notification mechanism should not become a new secret-management problem or a reason for remote login to stall when an external service is unavailable.

A simple and practical design is to use an XMPP account dedicated to notifications and send messages with `sendxmpp` over TLS. The account credentials live in a root-only configuration file, while the destination JID remains a separate operational setting.

This removes the need for Telegram Bot API calls and keeps the alert path inside a self-hosted XMPP service when that is already part of the infrastructure.

## Design

```text
SSH login event
  -> notification script
  -> sendxmpp
  -> XMPP server
  -> administrator JID
```

Keep credentials, destination JID, TLS trust path and message generation separate.

## Root-only sendxmpp account file

Create a dedicated configuration file, for example:

```text
/root/.sendxmpprc-ssh-alert
```

Example:

```text
username: ssh-alert
jserver: jabber.example.net
port: 5222
password: replace-with-real-password
```

Protect it:

```bash
chown root:root /root/.sendxmpprc-ssh-alert
chmod 600 /root/.sendxmpprc-ssh-alert
```

Do not put the real password in the script, repository, shell history or documentation.

## Verify delivery manually first

```bash
printf 'test ssh alert\n' | \
sendxmpp \
  -f /root/.sendxmpprc-ssh-alert \
  -r ssh-alert \
  --tls \
  --tls-ca-path /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem \
  admin@example.net \
  -v
```

The CA bundle path depends on the distribution. Do not solve certificate problems with `--no-tls-verify` when a trusted CA path can be configured.

## Notification script

A minimal notifier can keep non-secret operational settings at the top:

```bash
#!/usr/bin/env bash
set -u

XMPP_CONFIG="/root/.sendxmpprc-ssh-alert"
XMPP_TO="admin@example.net"
XMPP_FROM_RESOURCE="ssh-alert"
XMPP_TLS_CA_PATH="/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem"

HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
IP_ADDRESS_SERVER="$(hostname -I 2>/dev/null | awk '{print $1}')"
CURRENT_USER="${PAM_USER:-${USER:-unknown}}"
IP_ADDRESS_CLIENT="${PAM_RHOST:-}"

if [[ -z "$IP_ADDRESS_CLIENT" && -n "${SSH_CLIENT:-}" ]]; then
  IP_ADDRESS_CLIENT="${SSH_CLIENT%% *}"
fi

[[ -n "$IP_ADDRESS_CLIENT" ]] || IP_ADDRESS_CLIENT="unknown"
[[ -n "$IP_ADDRESS_SERVER" ]] || IP_ADDRESS_SERVER="unknown"

MESSAGE="SSH login detected on server: ${HOSTNAME} (IP: ${IP_ADDRESS_SERVER}). User: ${CURRENT_USER} from IP: ${IP_ADDRESS_CLIENT}"

if command -v sendxmpp >/dev/null 2>&1; then
  printf '%s\n' "$MESSAGE" | \
    sendxmpp \
      -f "$XMPP_CONFIG" \
      -r "$XMPP_FROM_RESOURCE" \
      --tls \
      --tls-ca-path "$XMPP_TLS_CA_PATH" \
      "$XMPP_TO"
fi
```

Changing the recipient requires only changing:

```bash
XMPP_TO="admin@example.net"
```

## Prefer PAM session data

If invoked from PAM, `PAM_USER` and `PAM_RHOST` describe the authenticated session more directly than `whoami` or shell-profile assumptions.

Only an SSH `open_session` should normally generate an alert:

```bash
[[ ${PAM_TYPE:-} == "open_session" ]] || exit 0
[[ ${PAM_SERVICE:-} == "sshd" ]] || exit 0
```

## Do not let XMPP availability block SSH login

A synchronous network call in the authentication path is undesirable. DNS, TLS or XMPP failure must not delay an administrator during an incident.

On systemd hosts, queue delivery asynchronously:

```bash
systemd-run --quiet --collect --no-block -- \
  /usr/local/sbin/ssh-login-alert --worker \
  --user "$PAM_USER" \
  --remote "${PAM_RHOST:-unknown}"
```

The PAM hook should return success after queueing the worker. Delivery failure should be logged separately.

## PAM integration

Back up the SSH PAM policy before changing it and keep an existing privileged session open while testing.

```bash
cp -a /etc/pam.d/sshd /etc/pam.d/sshd.before-ssh-login-alert
```

A typical optional session hook:

```text
session optional pam_exec.so quiet /usr/local/sbin/ssh-login-alert
```

`optional` matters: XMPP alerting is observability, not an authentication dependency.

## Installation

```bash
install -o root -g root -m 0755 \
  notify_jabber.sh \
  /usr/local/sbin/ssh-login-alert
```

Install the sendxmpp credential file separately with mode `0600`.

A legacy filename such as `notify_telegram.sh` may be kept temporarily as a compatibility wrapper, but the long-term name should reflect the actual transport.

## Log failures instead of hiding them

Avoid permanent `>/dev/null 2>&1` suppression around the transport command.

A better production pattern is to keep successful delivery quiet but journal failures:

```bash
if ! printf '%s\n' "$MESSAGE" | sendxmpp ...; then
  logger -t ssh-login-alert -- \
    "XMPP delivery failed for user=${CURRENT_USER} remote=${IP_ADDRESS_CLIENT}"
fi
```

Never log the XMPP password.

## Security boundaries

The notification does not replace SSH key policy, MFA, source restrictions, Fail2Ban, centralized audit logs or SIEM monitoring. It is a fast operator signal, not the authoritative audit trail.

## Validation checklist

```text
sendxmpp is installed
credential file is root-owned and mode 0600
TLS certificate validation succeeds
manual test message reaches the intended JID
SSH login still succeeds if XMPP is unavailable
one SSH open_session produces one alert
source user and remote IP are correct
notification failure is visible in the journal
```

## Stop conditions

Stop the rollout if credentials appear in the script or repository, TLS verification must be disabled, the notifier can block authentication, one login produces repeated notifications, or PAM is being tested from the only privileged session.

## References

- `sendxmpp(1)` manual: <https://manpages.debian.org/buster/sendxmpp/sendxmpp.1p.en.html>
- `pam_exec(8)`: <https://man7.org/linux/man-pages/man8/pam_exec.8.html>
- `systemd-run(1)`: <https://www.freedesktop.org/software/systemd/man/latest/systemd-run.html>
