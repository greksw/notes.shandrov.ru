---
title: "Immich on TrueNAS SCALE: Android photo backup, HTTPS and ZFS"
description: "Production-style homelab deployment of Immich with TrueNAS SCALE 25.10, ZFS RAIDZ2, MikroTik split DNS, Nginx TLS and PostgreSQL backups."
category: "Storage & Backup"
tags: ["immich", "truenas", "zfs", "android", "mikrotik", "nginx", "letsencrypt", "postgresql", "backup", "self-hosted"]
published: 2026-10-18
updated: 2026-10-18
status: current
testedOn: ["TrueNAS SCALE 25.10.7", "Immich 3.3.3", "TrueNAS Apps 1.14.52", "PostgreSQL 18", "MikroTik RouterOS 7", "Nginx 1.20.1", "Android 16"]
featured: false
lang: en
translationKey: "storage-backup/immich-truenas-scale-android-zfs-https"
---

## Context and outcome

The goal was a self-hosted Google Photos alternative: automatic photo/video upload from Android over both home Wi-Fi and cellular data, original assets stored on a NAS, and one HTTPS URL in both networks.

We deployed **Immich** from the TrueNAS SCALE Apps catalog, with a four-disk **ZFS RAIDZ2**, Nginx HTTPS and **MikroTik split-horizon DNS**. Initial synchronization of roughly **3,700 files** completed; the media dataset held about **41 GiB**. Server, PostgreSQL, Redis and ML containers were healthy. One PostgreSQL dump was created and gzip-checked, baseline ZFS snapshots were created, and a daily snapshot task was configured.

**Scope:** offline USB backups were planned but **not yet deployed**. The first scheduled overnight dump/snapshot execution had **not yet been verified**. RAIDZ2 and local snapshots do not protect against total NAS loss.

All internal names, IP addresses and the real DNS zone are sanitized. `example.com` and `203.0.113.10` are documentation-only values.

## 01 / Architecture

```text
Android phone -> https://photos.example.com
                  |
          +-------+--------+
          |                |
       LTE/5G           Home Wi-Fi
          |                |
   203.0.113.10      Split DNS returns
   MikroTik DNAT     192.168.10.20
          |                |
          +-------> Nginx HTTPS :443
                           |
                     LAN HTTP upstream
                     192.168.10.10:30041
                           |
                    TrueNAS / Immich
                           |
                   ZFS media + PostgreSQL
```

Only the reverse proxy is public. Do not expose TrueNAS management or the Immich upstream port directly.

## 02 / Hardware and ZFS datasets

The NAS used one NVMe as the TrueNAS boot pool and four 8 TB HDDs in RAIDZ2. About 30 GiB of RAM were available. Since there was no separate SSD data pool, both the database and media reside on HDD; this increases random I/O and can keep disks awake during indexing.

The installation used 4 vCPU limit, 8192 MiB memory limit, UID/GID 568 and CPU machine learning. No repartitioning of the boot NVMe.

```bash
zfs create -p -o compression=lz4 -o atime=off data/immich/data
zfs create -o compression=lz4 -o atime=off -o recordsize=16K data/immich/pgData
chown 568:568 /mnt/data/immich/data
chmod 750 /mnt/data/immich/data
zfs list -r data/immich
```

Media inherited a 128K record size; PostgreSQL used 16K. These are case-specific choices, not a universal tuning recipe for RAIDZ2.

## 03 / TrueNAS App installation

Use **Apps → Discover Apps → Immich → Install** and configure:

| Field | Value |
|---|---|
| Database | PostgreSQL 18, HDD storage |
| Authentication | Separate strong DB and Redis passwords |
| User/group | 568 / 568 |
| WebUI | Port 30041 |
| Data Storage | Host Path `/mnt/data/immich/data` |
| PostgreSQL Storage | Host Path `/mnt/data/immich/pgData` |
| PostgreSQL Automatic Permissions | Enabled |
| ML Cache | Temporary |
| CPU and memory | 4 CPU, 8192 MiB |

PostgreSQL automatic permissions assigned UID/GID `999:999` in this installation. Container chart requirements may change across versions.

One installation failure was immediately actionable:

```text
RenderError: Redis password cannot contain [#]
```

Generate a new acceptable Redis password, for example `openssl rand -hex 32`. Never publish passwords or tokens.

Verify the application:

```bash
midclt call app.query | jq -r '.[] | select(.name=="immich") | [.name,.state,.version] | @tsv'
docker ps --filter name=ix-immich --format 'table {{.Names}}\t{{.Status}}'
curl -fsS http://127.0.0.1:30041/api/server/ping
```

The observed result was `RUNNING`, four healthy containers and `{"res":"pong"}`.

## 04 / TLS termination with Nginx and DNS-01

An existing MikroTik TCP/443 DNAT sent public traffic to a dedicated Nginx host. There was no need to expose 30041. Certificates were already managed via `acme.sh` using Selectel DNS-01 and a systemd renewal timer, so the existing port-80 routing remained untouched.

After setting up the DNS provider API securely:

```bash
/root/.acme.sh/acme.sh --issue --dns dns_selectel \
  -d photos.example.com --keylength ec-256 --server letsencrypt
install -d -m 700 /etc/nginx/tls/photos.example.com
/root/.acme.sh/acme.sh --install-cert -d photos.example.com --ecc \
  --fullchain-file /etc/nginx/tls/photos.example.com/fullchain.pem \
  --key-file /etc/nginx/tls/photos.example.com/privkey.pem \
  --reloadcmd "nginx -t && systemctl reload nginx"
```

Replace the example hostname with your actual domain and select the correct DNS plugin.

Example separate virtual host for **Nginx 1.20.1**:

```nginx
server {
    listen 192.168.10.20:443 ssl http2;
    server_name photos.example.com;
    ssl_certificate /etc/nginx/tls/photos.example.com/fullchain.pem;
    ssl_certificate_key /etc/nginx/tls/photos.example.com/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    client_max_body_size 50000M;
    client_body_buffer_size 1024k;
    proxy_request_buffering off;
    proxy_connect_timeout 30s;
    proxy_read_timeout 600s;
    proxy_send_timeout 600s;
    send_timeout 600s;
    location / {
        proxy_pass http://192.168.10.10:30041;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_redirect off;
    }
}
```

For this Nginx version, use `listen ... http2;`, not the newer `http2 on;` directive. Always run `nginx -t` before a reload.

## 05 / Split DNS instead of hairpin NAT

The phone initially failed to reach the public hostname from Wi-Fi because the existing destination NAT rule matched only the WAN interface. We configured a static local DNS record on MikroTik:

```routeros
/ip dns set allow-remote-requests=yes
/ip dns static add name=photos.example.com type=A \
  address=192.168.10.20 ttl=1h comment="Immich Split DNS"
:put [:resolve "photos.example.com" server=192.168.10.1]
```

The public record remained `203.0.113.10`; the local record returned `192.168.10.20`. DHCP clients must actually use MikroTik for DNS, and Android Private DNS/VPN can bypass this override.

The Android app ultimately used **only `https://photos.example.com`**, both inside and outside the LAN. Avoid local plain HTTP for authentication and photo uploads.

## 06 / Validation and Android upload

On the reverse proxy:

```bash
curl -sS -o /dev/null \
  --resolve photos.example.com:443:192.168.10.20 \
  -w "HTTP %{http_code}\n" https://photos.example.com/
curl -fsS --resolve photos.example.com:443:192.168.10.20 \
  https://photos.example.com/api/server/ping
curl -sSI --resolve photos.example.com:443:192.168.10.20 \
  https://photos.example.com/.well-known/immich
```

Web UI and discovery returned HTTP 200; the API returned `{"res":"pong"}`. SNI validation ensured other Nginx virtual hosts retained their own TLS certificates.

The mobile uploads produced `POST /api/assets → 201`, album writes `200` and sync acknowledgments `204`. On Android, enable photo/video permissions, background activity and network upload according to your preferred data policy. Background execution depends on Android battery management.

## 07 / PostgreSQL backups and ZFS snapshots

Immich database dumps were enabled at `0 2 * * *`, retaining 14 copies. The first **Create Database Backup** job was run manually in the Administration job queue. Logs showed:

```text
Database Backup Starting. Database Version: 18
pg_dump exited (0)
Database Backup Success
```

A `.sql.gz` file appeared in `/mnt/data/immich/data/backups` (about 41 MiB), and `gzip -t` succeeded. This is an archive check, **not** a database restore test. The file does not contain the original media.

We then created recursive baseline snapshots:

```bash
SNAP="baseline-$(date +%Y%m%d-%H%M)"
zfs snapshot -r "data/immich@$SNAP"
zfs list -t snapshot -r data/immich
```

TrueNAS **Data Protection → Periodic Snapshot Tasks** now has a task for the parent dataset `data/immich`, recursive, with naming template `immich-auto-%Y-%m-%d_%H-%M`, daily **03:30 Europe/Moscow**, and **30 DAY** retention. This covers media, stored dumps and the PostgreSQL dataset. The nightly scheduled cycle had not yet been verified at publication time.

A live database snapshot by itself does not replace a logically consistent dump. A timer gap from 02:00 to 03:30 also does not guarantee the dump completed; monitor backup freshness.

## 08 / ML warnings and operational limits

During initial indexing, `AssetDetectFaces` failed intermittently with `fetch failed` / `write EPIPE`. Container inspection found `RestartCount=0` and `OOMKilled=false`; ML logs recorded idle worker shutdown and restart. This was not sufficient to establish the root cause or guarantee it could not recur.

Future work: verify the automatic backup cycle, replicate media and dumps to an independent USB disk or remote system, test restoration, and add HTTP/storage/backup monitoring. Snapshots on the primary pool and a four-disk RAIDZ2 are not an independent backup.

## References

- [Immich — TrueNAS installation](https://docs.immich.app/install/truenas/)
- [Immich — reverse proxy](https://docs.immich.app/administration/reverse-proxy/)
- [Immich — backup and restore](https://docs.immich.app/administration/backup-and-restore/)
- [TrueNAS documentation](https://www.truenas.com/docs/scale/)
- [acme.sh](https://github.com/acmesh-official/acme.sh)
