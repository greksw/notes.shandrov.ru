---
title: "Correlating Windows DNS and MikroTik IPFIX: domains and traffic volume in Grafana"
description: "A practical monitoring architecture where Windows AD DNS provides domain context, MikroTik IPFIX provides traffic volume, Loki stores events, and Grafana brings the data together."
category: "Monitoring & Security"
tags: ["windows-dns", "active-directory", "mikrotik", "ipfix", "goflow2", "loki", "prometheus", "grafana", "observability"]
published: 2026-10-09
updated: 2026-10-09
status: current
testedOn: ["Windows Server DNS", "MikroTik RouterOS 7", "GoFlow2", "Loki", "Prometheus", "Grafana"]
featured: true
translationKey: "monitoring/windows-dns-mikrotik-ipfix-traffic-correlation"
---

## Context

Traditional network monitoring is good at answering questions such as how much traffic crossed an interface, which VLAN or IP address consumed bandwidth, and when a traffic spike occurred.

It is much worse at answering a more operationally useful question:

> Which Internet services and domains are generating that traffic?

DNS monitoring solves the opposite problem. It shows which names workstations query, but not how many megabytes or gigabytes are transferred afterwards.

The architecture therefore uses two telemetry sources:

```text
Windows AD DNS
      │
      │ DNS Analytical events
      ▼
     Loki
      │
      ├───────────────────────┐
      │                       │
      ▼                       ▼
   Grafana               correlation
                              ▲
                              │
                            IPFIX
                              │
                         MikroTik
```

DNS provides semantic context:

```text
client → domain
```

while IPFIX provides network accounting:

```text
client → destination IP → bytes
```

The goal is an approximate model:

```text
client → domain → destination → traffic volume
```

Internal domains, IP addresses, server names and site identifiers in this article are anonymized.

## Why MikroTik alone is not enough

MikroTik sees network connections well.

For example:

```text
10.20.30.45 → 203.0.113.40
```

and IPFIX can export:

```text
src_ip
dst_ip
src_port
dst_port
protocol
bytes
packets
```

But a destination IP is often not meaningful by itself. One CDN or cloud address can serve many applications.

GeoIP, ASN and reverse DNS help, but they do not reveal the original hostname requested by the client.

## Why DNS alone is not enough

Windows AD DNS can see:

```text
10.20.30.45 → www.example.net
```

That is more understandable, but DNS does not know how much data the client later transferred.

One lookup may lead to a few kilobytes, another to several gigabytes.

So:

```text
DNS ≠ traffic accounting
IPFIX ≠ application identity
```

Together they are much more useful.

## Architecture

The pilot stack uses:

```text
Windows AD DNS
MikroTik RouterOS
GoFlow2
Fluent Bit / Alloy
Loki
Prometheus
Grafana
```

Logical flow:

```text
                        ┌─────────────────┐
                        │ Windows AD DNS  │
                        └────────┬────────┘
                                 │
                        DNS Analytical ETW
                                 │
                                 ▼
                         Fluent Bit / Alloy
                                 │
                                 ▼
┌──────────┐    IPFIX     ┌───────────┐
│ MikroTik │─────────────►│ GoFlow2   │
└──────────┘              └─────┬─────┘
                                │
                         classification
                                │
                ┌───────────────┴──────────────┐
                ▼                              ▼
              Loki                         Prometheus
                │                              │
                └──────────────┬───────────────┘
                               ▼
                            Grafana
```

Loki is used for high-cardinality events such as client IPs, domains, destination IPs and flow records.

Prometheus remains focused on normal infrastructure metrics.

## Windows DNS as telemetry

The domain controllers expose:

```text
Microsoft-Windows-DNSServer/Analytical
```

Normalized DNS events contain fields such as:

```text
timestamp
dns_server
client_ip
qname
qtype
rcode
```

Example:

```json
{
  "client_ip": "10.20.30.45",
  "domain": "www.example.net",
  "qtype": "A",
  "rcode": "NOERROR"
}
```

Fields such as `client_ip` and `domain` should generally stay inside JSON rather than becoming Loki labels because of cardinality.

## What DNS already provides

A DNS dashboard can show:

```text
Total DNS queries
Unique clients
Unique domains
NXDOMAIN
Queries/sec
Top clients
Top domains
Top NXDOMAIN domains
```

This is useful for finding misconfigured applications, noisy clients, unusual DNS activity and repeated NXDOMAIN traffic.

But it still measures queries, not transferred bytes.

## MikroTik IPFIX

Traffic Flow/IPFIX provides the network side:

```text
MikroTik
   │
   │ IPFIX
   ▼
GoFlow2
   │
   ▼
classifier
   │
   ▼
Loki
```

Example normalized flow:

```json
{
  "src_ip": "10.20.30.45",
  "dst_ip": "203.0.113.40",
  "src_port": 52144,
  "dst_port": 443,
  "protocol": "tcp",
  "bytes": 1832451
}
```

This supports calculations such as:

```text
bytes per client
bytes per destination
flows per client
top destinations
estimated bandwidth
```

## Why flows need classification

A MikroTik router may observe more than ordinary Internet traffic:

```text
Internet
Inter-Site
VPN
internal networks
public NAT
infrastructure traffic
```

Flows should therefore be classified before visualization:

```text
Internet candidate
Inter-Site
VPN
Public NAT / unknown client
Internal
```

If NAT has already removed the original client identity, reporting `unknown client` is safer than assigning traffic to the wrong host.

## DNS and IPFIX correlation

Suppose DNS recorded:

```text
10.20.30.45
www.example.net
10:05:12
```

and IPFIX recorded:

```text
10.20.30.45
→ 203.0.113.40
10:05:13
2.1 MB
```

This creates an opportunity to correlate domain context with a network flow.

However, simply declaring:

```text
www.example.net = 2.1 MB
```

would be too naive.

A practical correlation cache needs at least:

```text
client_ip
domain
resolved_ip
valid_until
site
```

## Why correlation is approximate

Modern web applications rely on:

- CDNs;
- APIs;
- object storage;
- analytics;
- authentication endpoints;
- static and video domains;
- shared IP addresses;
- HTTP/2 and HTTP/3.

A user may open:

```text
portal.example.net
```

while most of the bytes arrive from:

```text
cdn.example.net
video.example-cdn.net
static.example.net
```

So the correct wording is:

> estimated traffic associated with a domain or service

rather than "exact website traffic."

## DNS caching

A workstation may resolve a name once and continue using the address for a long period.

IPFIX continues to see flows while DNS produces no new lookup.

The correlation layer therefore needs TTL-aware state such as:

```text
client_ip
domain
resolved_ip
valid_until
```

## DoH and DoT

If a browser uses DNS over HTTPS, corporate Windows DNS may never see the hostname.

From the network side this looks like HTTPS traffic to a public resolver.

A corporate environment can either control DoH with policy or explicitly treat such traffic as a blind spot.

## Router DNS proxy

If clients use MikroTik as a DNS proxy:

```text
client → MikroTik DNS → AD DNS
```

Windows DNS may see the router as the source instead of the workstation.

That breaks client attribution, so the DNS path for each VLAN has to be understood.

## Multiple sites

A remote site may use central AD DNS:

```text
remote client ──DNS──► central DC
```

while using its own Internet gateway:

```text
remote client ──Internet──► remote MikroTik
```

Central DNS sees the query, but the central gateway never sees the corresponding Internet flow.

The correlation model therefore needs:

```text
site
gateway
exporter
```

## Data model

A more realistic model is:

```text
site
  │
client
  │
DNS query
  │
domain
  │
destination mapping
  │
IPFIX exporter
  │
flow
  │
bytes
```

`site` becomes as important as `client_ip`.

## Grafana layout

A useful dashboard can be split into three sections.

### DNS visibility

```text
DNS requests
Unique clients
Unique domains
NXDOMAIN
Top domains
Top clients
```

### Network traffic

```text
Total Internet traffic
Top clients by bytes
Top destination IP
Top ASN
Traffic by site
Traffic by VLAN
```

### Correlation

```text
Estimated traffic by domain
Estimated traffic by client + domain
Top services by traffic
DNS requests without observed flows
Flows without DNS attribution
```

The last two panels also measure the quality of the correlation itself.

## Keep unknown visible

Useful categories include:

```text
Attributed
Unattributed
Unknown NAT
DoH suspected
DNS cache / no recent lookup
Remote-site flow unavailable
```

Example:

```text
Total Internet traffic:      120 GB
Attributed:                   83 GB
Unattributed:                 24 GB
Unknown NAT:                   8 GB
Remote-site flow unavailable:  5 GB
```

This is more honest than forcing 100% of traffic into domain buckets.

## Loki versus Prometheus

Using every hostname as a Prometheus label is a bad idea:

```text
dns_queries_total{
  client="10.20.30.45",
  domain="random-host.example.net"
}
```

The cardinality becomes very high.

A cleaner split is:

```text
Prometheus → infrastructure metrics
Loki       → DNS/IPFIX events
Grafana    → queries, correlation and visualization
```

## What this system is not

This is not:

```text
browser history
DPI
proxy log
EDR telemetry
packet capture
```

It does not know the full URL:

```text
https://example.net/private/page?id=123
```

At best, it knows the domain:

```text
example.net
```

That distinction matters both technically and from a privacy perspective.

## Operational value

The architecture can answer questions such as:

- why external traffic increased;
- which client is generating load;
- which services are used most often;
- which domains are associated with the most traffic;
- which site is generating traffic;
- whether NXDOMAIN volume is abnormal;
- what percentage of traffic can be attributed at all.

## Next step

The DNS and IPFIX pipelines can work independently. The next layer is a correlation service/cache:

```text
DNS event
    │
    ├─ client_ip
    ├─ domain
    ├─ resolved_ip
    └─ timestamp
          │
          ▼
     correlation cache
          │
IPFIX ────┤
          │
          ▼
client + domain + bytes + confidence
```

A production implementation must account for TTL, multiple A/AAAA records, CDNs, NAT, IPv6, DNS cache, DoH, site awareness, retention and cardinality.

## Takeaway

DNS and IPFIX each provide only half of the picture.

DNS answers:

```text
where the client intended to go
```

IPFIX answers:

```text
where traffic actually went and how many bytes were transferred
```

Combining Windows AD DNS, MikroTik IPFIX, Loki, Prometheus and Grafana creates an observability layer that shows not only link utilization but also its context.

The key is not to present correlation as absolute truth. In a modern HTTPS/CDN/DoH environment, a `traffic attribution confidence` metric is more useful than pretending that 100% of traffic can be mapped exactly to domain names.
