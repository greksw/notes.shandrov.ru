---
title: "MikroTik RouterOS 7: multi-WAN policy routing with per-VLAN failover"
description: "A production-oriented pattern for steering different VLANs through preferred uplinks while preserving controlled failover and verifiable egress behavior."
category: "Networking"
tags: ["mikrotik", "routeros", "multi-wan", "policy-routing", "failover", "vlan"]
published: 2026-09-15
updated: 2026-09-15
status: current
testedOn: ["RouterOS 7.x", "MikroTik RB5009 / CCR class", "multi-VLAN edge routing"]
featured: true
---

## Context

A multi-WAN edge router becomes difficult to operate when failover policy is implicit. If every client simply follows the main default route, there is no clear answer to questions such as:

- which uplink should a specific VLAN prefer;
- which backup should be used if that uplink fails;
- whether some administrative networks should fall back differently from ordinary users;
- how to prove which provider a host is actually using.

The pattern here treats WAN choice as an explicit routing policy. Different source networks are mapped to dedicated routing tables, each table has its own ordered set of default routes, and validation is done from test hosts rather than inferred only from route flags.

The example values are sanitized. Replace interface names, gateways and subnets with values from the actual environment.

## Reference policy

Assume three Internet uplinks:

| Uplink | Example role |
| --- | --- |
| `WAN_A` | primary provider |
| `WAN_B` | general backup |
| `WAN_C` | secondary fallback for selected VLANs |

And several internal networks:

| VLAN / subnet | Preferred path |
| --- | --- |
| user VLANs | `WAN_A` → `WAN_B` |
| admin VLAN | `WAN_A` → `WAN_C` |
| service VLAN | `WAN_A` → `WAN_C` |
| test host | follows its VLAN policy and is used for validation |

The useful design property is that the policy is visible in configuration. A future administrator should not need to reverse-engineer NAT counters or connection tracking to discover the intended failover order.

## RouterOS 7 routing model

RouterOS 7 requires custom routing tables to be created explicitly before they are referenced.

```routeros
/routing/table
add name=rt_wan_ab fib
add name=rt_wan_ac fib
```

For simple source-based steering, `/routing/rule` is usually clearer than firewall mangle. MikroTik documents both approaches; mangle provides more expressive matching, but it has higher priority in the routing decision path and should not be mixed with routing rules casually.

Use one method for one policy unless there is a specific reason to combine them.

## Add policy-table defaults

The custom table that represents `WAN_A → WAN_B` contains two default routes with different distances:

```routeros
/ip/route
add dst-address=0.0.0.0/0 gateway=198.51.100.1@main \
    routing-table=rt_wan_ab distance=1 check-gateway=ping
add dst-address=0.0.0.0/0 gateway=203.0.113.1@main \
    routing-table=rt_wan_ab distance=2 check-gateway=ping
```

A second table can use `WAN_C` as its fallback:

```routeros
/ip/route
add dst-address=0.0.0.0/0 gateway=198.51.100.1@main \
    routing-table=rt_wan_ac distance=1 check-gateway=ping
add dst-address=0.0.0.0/0 gateway=192.0.2.1@main \
    routing-table=rt_wan_ac distance=2 check-gateway=ping
```

The `@main` suffix matters when the gateway itself is resolved through the main table. RouterOS 7 requires the next hop to be resolvable before the route in the custom table can become active.

## Keep the main table sane

Policy routing does not replace a correct main table. The router itself still needs a predictable default path, and custom tables depend on main-table next-hop resolution.

Example:

```routeros
/ip/route
add dst-address=0.0.0.0/0 gateway=198.51.100.1 distance=1 check-gateway=ping
add dst-address=0.0.0.0/0 gateway=203.0.113.1 distance=2 check-gateway=ping
```

The main table is also where connected routes normally live. Do not break gateway resolution in `main` while trying to make policy tables self-contained.

## Protect internal routing before applying WAN policy

A source-based rule that points to a table containing a default route can unintentionally capture traffic to internal destinations.

Handle internal networks first. Use the actual routed prefixes from the environment rather than copying these examples blindly:

```routeros
/routing/rule
add dst-address=10.0.0.0/8 action=lookup table=main
add dst-address=172.16.0.0/12 action=lookup table=main
add dst-address=192.168.0.0/16 action=lookup table=main
```

In an environment that uses only selected private ranges internally, narrower prefixes are preferable because they make intent more explicit.

The point is ordering: internal traffic should be resolved before generic Internet steering rules.

## Map VLANs to policy tables

For user networks that should prefer `WAN_A` and fail over to `WAN_B`:

```routeros
/routing/rule
add src-address=10.20.10.0/24 action=lookup table=rt_wan_ab
add src-address=10.20.11.0/24 action=lookup table=rt_wan_ab
```

For administrative or service networks that should prefer `WAN_A` but use `WAN_C` as fallback:

```routeros
/routing/rule
add src-address=10.20.90.0/24 action=lookup table=rt_wan_ac
add src-address=10.20.91.0/24 action=lookup table=rt_wan_ac
```

Using `action=lookup` allows RouterOS to continue with later policy processing if the selected table cannot resolve the destination. Using `lookup-only-in-table` creates a stricter boundary and can intentionally make traffic fail closed. Choose the behavior deliberately.

For active-backup Internet access, `lookup` is normally the more practical choice.

## NAT must match the available uplinks

Routing and NAT are separate concerns. A route can be correct while Internet access still fails because source NAT does not cover the selected egress interface.

A simple interface-list pattern is easier to maintain than one masquerade rule per provider:

```routeros
/interface/list
add name=WAN
/interface/list/member
add list=WAN interface=ether1
add list=WAN interface=ether2
add list=WAN interface=ether3

/ip/firewall/nat
add chain=srcnat out-interface-list=WAN action=masquerade
```

If the environment uses static public addresses or provider-specific source NAT, keep those explicit instead of replacing them with generic masquerade rules.

## Gateway checks are not full Internet health checks

`check-gateway=ping` verifies reachability of the configured next hop. This is useful but limited.

A provider can have a reachable gateway while upstream Internet connectivity is broken. For environments where that failure mode matters, use a stronger health-check design such as recursive routes to stable external probes, Netwatch-driven route control, or another monitored mechanism.

Do not add recursive routing complexity unless it is understood and tested. A simple gateway check that operators understand is better than an opaque failover graph that nobody can troubleshoot during an outage.

## Validate the routing tables directly

Do not rely only on the green/blue route flags in WinBox.

Inspect each table:

```routeros
/ip/route/print detail where routing-table=rt_wan_ab
/ip/route/print detail where routing-table=rt_wan_ac
```

Check that only the intended primary route is active under normal conditions and that the backup is available with the expected distance.

Inspect rules in processing order:

```routeros
/routing/rule/print detail
```

Rule ordering is part of the policy. Internal-destination rules should appear before generic source-network rules.

## Validate from a real test host

The most important check is the actual egress path from a host inside the affected VLAN.

Use one documented test host per policy group if possible. From that host:

```bash
curl -4 https://ifconfig.me
```

or another trusted IP-echo service.

Record the expected public source address for each provider. Then perform the test in three states:

1. all uplinks healthy;
2. primary uplink unavailable;
3. primary restored.

The host should move to the expected backup and then return to the preferred uplink after recovery.

This catches problems that route inspection alone can miss, including NAT mismatch, stale connections and policy rules that match more traffic than intended.

## Existing connections during failover

Failover does not guarantee seamless survival of existing sessions.

When a connection moves from one provider to another, the public source address usually changes. TCP sessions, VPNs and stateful SaaS connections may reset even if new flows are routed correctly through the backup provider.

This is normal for simple multi-WAN NAT failover. Do not describe it as HA in the application sense.

Validation should distinguish:

- new connections work through the backup;
- old connections may need to reconnect;
- routing returns to the preferred uplink after recovery.

## Fail one uplink at a time

During commissioning, disable or disconnect one WAN path at a time and observe route state:

```routeros
/ip/route/print where dst-address=0.0.0.0/0
```

Then test from a host in every policy class.

For example, when `WAN_A` fails:

- user VLANs should exit through `WAN_B`;
- admin/service VLANs should exit through `WAN_C`;
- internal inter-VLAN and site-to-site routes should continue to use internal routing, not a WAN default.

If any internal destination starts leaving through a provider, stop and fix rule ordering before continuing.

## Restore and test failback

When the primary provider returns, verify that new connections move back to the preferred path.

Do not assume that a route becoming active means every application instantly returns to that WAN. Existing connection-tracking entries may continue until timeout or session restart.

Use new test connections for failback validation.

## Troubleshooting sequence

When a VLAN uses the wrong provider, work from routing decision to packet translation rather than changing several subsystems at once.

Check:

```routeros
/routing/rule/print detail
/ip/route/print detail
/routing/nexthop/print detail
/ip/firewall/nat/print stats
/ip/firewall/connection/print where src-address~"10.20."
```

The useful questions are:

- did the source match the intended routing rule;
- is the selected table able to resolve a default route;
- is the intended next hop reachable;
- did NAT match the actual egress interface;
- is an old connection still pinned to a previous path.

Avoid clearing the entire connection table as a first troubleshooting step on a production router.

## Routing rules versus mangle

Routing rules are a good fit when policy is mostly based on source subnet, destination or ingress interface.

Mangle becomes useful when policy depends on more complex conditions such as connection classification, protocol/port combinations or per-connection load distribution.

If mangle sets a routing mark that resolves successfully, RouterOS processes that before ordinary user routing rules. This is why a partially migrated configuration can be confusing: an old mangle rule may silently override a new `/routing/rule` policy.

Before introducing a new model, inspect both:

```routeros
/ip/firewall/mangle/print detail
/routing/rule/print detail
```

Remove or clearly document legacy marks rather than leaving two policy systems active by accident.

## Change management

A multi-WAN router is easy to make "mostly working" while one VLAN silently follows the wrong provider.

Make changes in small groups:

1. create routing tables;
2. add and inspect routes;
3. add internal-destination rules;
4. add one source policy;
5. validate from one test host;
6. repeat for the next VLAN group;
7. test failover and failback explicitly.

Keep Safe Mode available for remote changes, especially when editing routing rules or default routes.

## Stop conditions

Stop the rollout if any of the following occurs:

- management access starts following an unintended WAN path;
- internal/site-to-site traffic is captured by an Internet policy table;
- a backup route is not reachable before the primary is disabled;
- NAT does not cover the selected egress path;
- DNS works only on one provider because upstream dependencies were overlooked;
- failback changes the route table but not real host egress;
- mangle and routing rules are both influencing the same traffic without a documented reason.

A failover design is only complete when the failure state has been tested deliberately.

## Operational notes

Keep provider names in comments rather than embedding business names into every rule. The logical names `WAN_A`, `WAN_B` and `WAN_C` make it easier to replace a carrier without rewriting the policy model.

Document one or more test IPs and expected public source addresses. That turns incident response from "which ISP are we on?" into a deterministic check.

For larger environments, group VLANs by routing intent instead of creating one table per VLAN. Several networks can share the same policy table when their preferred and fallback order is identical.

## References

- MikroTik RouterOS Policy Routing: <https://help.mikrotik.com/docs/spaces/ROS/pages/59965508/Policy%2BRouting>
- MikroTik RouterOS IP Routing: <https://help.mikrotik.com/docs/spaces/ROS/pages/328084/IP%2BRouting>
- MikroTik RouterOS v6 to v7 routing differences: <https://help.mikrotik.com/docs/spaces/ROS/pages/30474256/Moving%2Bfrom%2BROSv6%2Bto%2Bv7%2Bwith%2Bexamples>
