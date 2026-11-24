---
title: "Immich on TrueNAS SCALE stuck at STOPPED: TLS handshake timeout and Docker pull recovery"
description: "A real Immich upgrade incident: failed image pulls, GHCR/CDN TLS diagnostics, temporary MikroTik PBR over Hysteria2 and sequential preloading of six pinned Docker images."
category: "Storage & Backup"
tags: ["immich", "truenas", "truenas-scale", "docker", "ghcr", "tls", "hysteria2", "mikrotik", "routeros", "zfs", "troubleshooting"]
published: 2026-11-24
updated: 2026-11-24
status: current
testedOn: ["TrueNAS SCALE 25.10.x", "Immich 3.4.2", "TrueNAS Apps 1.14.74", "PostgreSQL 18 / VectorChord 1.1.1", "MikroTik RouterOS 7", "Hysteria2"]
featured: false
lang: en
translationKey: "storage-backup/immich-truenas-tls-timeout-docker-pull-recovery"
---

## Incident and outcome

On November 24, 2026, an upgrade of the TrueNAS SCALE Immich application to catalog release **1.14.74** left the application **STOPPED**. TrueNAS showed failed `app.upgrade` and `app.start` tasks; no Immich containers existed.

The lifecycle log exposed **`TLS handshake timeout`**, **`connection reset by peer`** and **`download failed after attempts=6`** while pulling images. After preloading all **six pinned Docker images sequentially**, the regular TrueNAS **Start** succeeded. Immich Server, PostgreSQL/VectorChord, Valkey and Machine Learning all reported `healthy`; the two one-shot initialization jobs exited successfully. The API returned HTTP 200 and confirmed Immich **3.4.2**.

**Evidence boundary:** this establishes incomplete image downloads as the blocking failure. The exact underlying network cause was not proven, and both selective VPN routing and serial pulls were changed. It would be incorrect to claim that either change alone was definitively responsible.

Internal hostnames, addresses and the actual photo-service domain are replaced with examples. Historical public CDN IPs are included only to document what DNS returned during this incident, not as a permanent routing recommendation.

## 01 / Diagnose the state before touching data

On the TrueNAS host:

~~~bash
midclt call app.query |
  jq '.[] | select(.name=="immich") | {name,state,version}'

docker ps -a --filter name=ix-immich   --format 'table {{.Names}}\t{{.Status}}'
~~~

The observed state was:

~~~text
{"name":"immich","state":"STOPPED","version":"1.14.74"}
NAMES     STATUS
~~~

No app containers existed. The failure was in the deployment path **before the PostgreSQL server started**, not a demonstrated database-corruption incident.

The lifecycle log `/var/log/app_lifecycle.log` contained errors such as:

~~~text
TLS handshake timeout
connection reset by peer
download failed after attempts=6
pgvecto Error
redis Error
~~~

These are Compose service names; `redis Error` does not imply the image was pulled from Docker Hub. In the rendered app configuration for this release, **all six images came from GHCR**.

Full TrueNAS lifecycle logs may contain sensitive values; do not paste raw logs into public tickets. A restricted error classifier:

~~~bash
python3 - <<'PY'
from pathlib import Path
import re

log = Path('/var/log/app_lifecycle.log')
checks = {
  'TLS_TIMEOUT': 'TLS handshake timeout',
  'CONNECTION_RESET': 'connection reset by peer',
  'DOWNLOAD_FAILED': 'download failed after attempts=',
}
if not log.exists():
    raise SystemExit('Lifecycle log not found')
for line in log.read_text(errors='replace').splitlines()[-1000:]:
    if 'immich' not in line.lower():
        continue
    hits = [name for name, phrase in checks.items()
            if phrase.lower() in line.lower()]
    if hits:
        stamp = re.search(r'\[\d{4}/\d{2}/\d{2}[^\]]*\]', line)
        print(stamp.group(0) if stamp else 'NO_TIMESTAMP',
              ','.join(hits))
PY
~~~

## 02 / Compare direct HTTPS and VPN paths

An outbound TLS test was run against four endpoints:

~~~bash
for HOST in   ghcr.io   pkg-containers.githubusercontent.com   registry-1.docker.io   auth.docker.io
do
  echo "===== $HOST ====="
  curl -4 -sS --connect-timeout 10 --max-time 20     -o /dev/null     -w 'HTTP=%{http_code} TCP=%{time_connect}s TLS=%{time_appconnect}s TOTAL=%{time_total}s\n'     "https://$HOST/v2/"
  echo "EXIT=$?"
done
~~~

Observed results:

| Endpoint | Direct WAN | Hysteria2 |
|---|---|---|
| `ghcr.io` | TLS 0.09 s, HTTP 401 | TLS 7.36 s, HTTP 401 |
| `pkg-containers.githubusercontent.com` | TLS connection timeout | TLS ~7.00 s, HTTP 400 |
| `registry-1.docker.io` | TLS 0.27 s, HTTP 401 | TLS 7.15 s, HTTP 401 |
| `auth.docker.io` | TLS 0.09 s, HTTP 404 | TLS 7.05 s, HTTP 404 |

An HTTP 401 on a registry endpoint without authentication is expected. The CDN/auth test paths may return 400 or 404; these codes do **not** imply a TLS failure. The relevant distinction was that the GitHub CDN timed out on the direct path but completed TLS over Hysteria2. Most other checked endpoints were much faster directly.

These measurements do not diagnose why VPN TLS consistently took around seven seconds. MTU, packet loss and Hysteria2 path behavior require separate testing.

## 03 / Temporary destination-specific MikroTik route

A pre-existing VPN gateway and RouterOS v7 FIB table were used to route only NAS-to-CDN TCP/443 traffic through Hysteria2. The registry and authentication endpoints stayed on the direct WAN. This was an **emergency workaround**, not a general-purpose production policy.

Example values:

~~~text
NAS:        192.168.10.10
Interface:  vlan10
VPN table:  to-VPN
~~~

Confirm the `to-VPN` table and its default route already work. The following commands do not install a VPN.

At the incident time, DNS returned these addresses for `pkg-containers.githubusercontent.com`:

~~~routeros
/ip firewall address-list add list=IMMICH-CDN-TEMP address=185.199.108.154 timeout=4h comment="Immich recovery"
/ip firewall address-list add list=IMMICH-CDN-TEMP address=185.199.109.154 timeout=4h comment="Immich recovery"
/ip firewall address-list add list=IMMICH-CDN-TEMP address=185.199.110.154 timeout=4h comment="Immich recovery"
/ip firewall address-list add list=IMMICH-CDN-TEMP address=185.199.111.154 timeout=4h comment="Immich recovery"

/ip firewall mangle add chain=prerouting in-interface=vlan10 src-address=192.168.10.10 protocol=tcp dst-port=443 dst-address-list=IMMICH-CDN-TEMP action=mark-routing new-routing-mark=to-VPN passthrough=no place-before=0 comment="IMMICH CDN TEMP via VPN"
~~~

**Never copy these CDN addresses as permanent policy.** DNS and shared CDN endpoints change. A four-hour address-list expiration may change routing while downloads are in progress. Check current DNS results, current RouterOS rules, and route behavior before applying any such workaround.

The actual router also had overlapping DNS FWD rules for `githubusercontent.com`, so populating a new destination list automatically was not demonstrated to be reliable.

Check the mangle rule counters:

~~~routeros
/ip firewall mangle print detail where comment="IMMICH CDN TEMP via VPN"
/ip firewall mangle print stats where comment="IMMICH CDN TEMP via VPN"
~~~

The rule matched traffic and three consecutive TLS probes to the CDN completed with HTTP 400 in roughly seven seconds. **This demonstrated basic HTTPS reachability, not that complete OCI blobs could be downloaded.**

Registry requests, bearer-token authentication and redirected blob requests are separate TCP/TLS connections. Using different countries for distinct connections is generally possible; changing a route or public IP **during** a connection, or provider IP-bound policies, can still cause failure.

## 04 / Inspect the exact installed image references

TrueNAS rendered the Compose file at the app revision path:

~~~bash
COMPOSE=$(
  find /mnt/.ix-apps/app_configs/immich/versions     -type f -path '*/templates/rendered/docker-compose.yaml'     2>/dev/null | sort -V | tail -1
)

test -n "$COMPOSE" || {
  echo "Rendered compose file not found"
  exit 1
}

docker compose -f "$COMPOSE" config --images | sort -u
~~~

For catalog release **1.14.74**, the list contained the following pinned images (all `ghcr.io`):

| Role | Image version |
|---|---|
| Immich Server | `immich-app/immich-server:v3.4.2` |
| Machine Learning | `immich-app/immich-machine-learning:v3.4.2` |
| PostgreSQL / VectorChord | `immich-app/postgres:18-vectorchord1.1.1` |
| Valkey | `valkey-io/valkey:9.2.0` |
| TrueNAS Container Utils | `truenas/containers/container-utils:1.1.2` |
| PostgreSQL Upgrade | `truenas/containers/postgres-upgrade:1.3.0` |

The actual Compose lines also included immutable `@sha256:…` digests. Preserve the **entire** image reference, not only the version tag, when pulling images. Do not substitute `latest`.

## 05 / Pull missing images one at a time

The affected service images, Valkey and PostgreSQL/VectorChord, pulled successfully one after the other. A second pass verified the other four: two were already present and two downloaded successfully. All six pinned image references were available locally before the next start.

A generic serial preload for the installed chart revision:

~~~bash
bash <<'BASH'
set -Eeuo pipefail

COMPOSE=$(
  find /mnt/.ix-apps/app_configs/immich/versions     -type f -path '*/templates/rendered/docker-compose.yaml'     2>/dev/null | sort -V | tail -1
)
test -n "$COMPOSE"

while IFS= read -r IMAGE; do
  test -n "$IMAGE" || continue
  echo "===== $IMAGE ====="
  if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "ALREADY PRESENT"
  else
    docker pull "$IMAGE"
  fi
  docker image inspect "$IMAGE" --format 'VERIFIED: {{.Id}}'
done < <(docker compose -f "$COMPOSE" config --images | sort -u)

echo "ALL REQUIRED IMAGES VERIFIED"
BASH
~~~

`docker pull` fetches images to local Docker storage. It does **not** launch containers, run DB migrations, modify photo assets or change PostgreSQL files. The procedure stops on the first failing image, making follow-up diagnostics more precise.

Avoid `docker system prune`, deleting the app, or rolling back ZFS as a response to an image-pull TLS timeout.

## 06 / Snapshot and start via TrueNAS

With the application still stopped, a recursive snapshot preserved the parent, media and database ZFS datasets:

~~~bash
SNAP="pre-immich-start-$(date +%Y%m%d-%H%M)"
zfs snapshot -r "data/immich@$SNAP"

zfs list -t snapshot -r data/immich   -o name,creation | grep -F "@$SNAP"
~~~

All **3/3** snapshots were verified. ZFS snapshots on the same NAS are not independent backups; database restoration after migrations requires explicit version-compatibility planning. Do not automatically issue `zfs rollback`.

The app was started using **TrueNAS → Apps → Immich → Start**, not by manually running Compose. The resulting state was:

~~~text
TrueNAS App:                 RUNNING (1.14.74)
Immich Server:               healthy
PostgreSQL / VectorChord:    healthy
Machine Learning:            healthy
Valkey:                      healthy
PostgreSQL upgrade job:      Exited (0)
Permissions job:             Exited (0)
~~~

Exited status 0 for one-shot jobs is expected success.

Verification:

~~~bash
midclt call app.query |
  jq '.[] | select(.name=="immich") | {name,state,version}'

docker ps -a --filter name=ix-immich   --format 'table {{.Names}}\t{{.Status}}'

curl -fsS --max-time 15 http://127.0.0.1:30041/api/server/version
curl -fsS --max-time 15 http://127.0.0.1:30041/api/server/ping
~~~

The version endpoint reported **3.4.2**; ping returned `{"res":"pong"}` with HTTP 200. The immediate server-log inspection did not identify explicit startup errors. **Full media integrity was not established by these API probes**; opening older photos, uploading a new asset and validating backups are separate acceptance checks.

After recovery the temporary CDN routing rule was disabled:

~~~routeros
/ip firewall mangle disable [find where comment="IMMICH CDN TEMP via VPN"]
~~~

Temporary address-list records were set to expire in four hours. Use the comment actually configured on your router.

## 07 / Practical lessons

1. **Read lifecycle errors first.** STOPPED with no app containers points to an earlier deployment phase; distinguish image pulls from DB startup.
2. **Check the full image path.** In this case every required image was on GHCR, regardless of service names like `redis`.
3. **Measure individual HTTPS targets.** A working `curl` does not establish successful blob downloading; HTTP codes alone are not TLS failures.
4. **Pre-pull before a future upgrade when possible.** Obtain exact digests from a trusted future chart manifest, not a guessed `latest` tag. The next rendered Compose revision might not exist until the upgrade begins.
5. **Keep network workarounds reversible.** Avoid permanent IP pinning and overly broad PBR. Overlapping DNS rules and route changes mid-transfer are risks.
6. **Protect and validate data independently.** Maintain PostgreSQL dumps, ZFS snapshots and an off-NAS backup; test actual photo access after the application becomes healthy.

## Conclusion

Incomplete Docker image downloads were the immediate cause preventing Immich from starting. A temporary selective CDN path and sequential downloads of six pinned images cleared the blocking stage. TrueNAS launched the application normally, all four long-running containers became healthy, and the API returned HTTP 200.

The networking root cause still deserves a separate investigation, but the operational lesson is clear: **do not erase an application or roll back ZFS before checking the image-pull stage**.

### Related reading

- [Immich on TrueNAS SCALE: Android photo backup, HTTPS and ZFS](/notes/storage-backup/immich-truenas-scale-android-zfs-https/)
- [Immich — TrueNAS installation](https://docs.immich.app/install/truenas/)
- [Immich — backup and restore](https://docs.immich.app/administration/backup-and-restore/)
- [TrueNAS SCALE documentation](https://www.truenas.com/docs/scale/)
- [Docker image pull](https://docs.docker.com/reference/cli/docker/image/pull/)
