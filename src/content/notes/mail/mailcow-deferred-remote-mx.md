---
title: "Diagnosing deferred Mailcow delivery: local firewall or remote MX refusal?"
description: "A short evidence-driven workflow for distinguishing local SMTP connectivity problems from selective refusal by a remote mail server."
category: "Mail & Services"
tags: ["mailcow", "postfix", "smtp", "networking", "troubleshooting"]
published: 2026-09-15
updated: 2026-09-15
status: current
testedOn: ["Mailcow", "Postfix", "Linux"]
featured: true
---

## Context

A growing deferred queue often triggers an immediate assumption that outbound TCP/25 is blocked locally. That hypothesis is easy to test and should be tested before changing firewall or NAT rules.

A useful diagnosis compares successful delivery paths with the failing destination and then adds packet-level evidence.

## Start with the queue

Identify whether deferrals affect all destinations or only particular recipient domains/MX hosts. Record the actual Postfix reason rather than treating every deferred message as the same failure.

Selective failures are already evidence against a blanket local TCP/25 block.

## Compare known-good destinations

From the mail host, test TCP/25 connectivity to multiple unrelated large mail providers and to the problematic MX. If well-known external MX hosts are reachable while one destination consistently times out or resets the connection, the problem has moved from "outbound SMTP is broken" to "this path or peer is refusing communication".

Do not change the firewall simply because one remote MX cannot be reached.

## Capture the packets

A short packet capture on the external interface can establish who terminates the session.

Look for:

- SYN leaving the local server;
- SYN/ACK or lack of response;
- a TCP reset and its source;
- retransmissions or an intermediate ICMP response.

A reset sourced by the remote endpoint is fundamentally different from a locally generated reject or a silent upstream block.

## Correlate with reputation and remote policy

When only specific MX hosts reject or reset sessions while general SMTP connectivity works, investigate peer-side policy, reputation or blocklisting. The local MTA may be functioning correctly even though delivery to that destination remains deferred.

## Validation

A defensible conclusion should include all of the following evidence:

- Postfix queue/defer reason;
- successful TCP/25 tests to unrelated MX hosts;
- repeated failure to the affected MX;
- packet capture showing where the connection is rejected or lost;
- no corresponding local firewall reject.

This avoids making production firewall changes to solve a problem that exists at the remote peer.
