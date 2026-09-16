---
title: "Asterisk 22 source deployment on AlmaLinux 9 with verified downloads and controlled activation"
description: "A reproducible Asterisk 22 source-build workflow for AlmaLinux 9 with pinned release checksums, bundled pjproject, dedicated service account and opt-in systemd activation."
category: "Voice & Telephony"
tags: ["asterisk", "voip", "almalinux", "pjsip", "systemd", "security"]
published: 2026-09-16
updated: 2026-09-16
status: lab
testedOn: []
featured: true
translationKey: "telephony/asterisk22-source-deployment-almalinux9"
---

## Context

Asterisk is easy to compile and surprisingly easy to deploy unsafely.

The risky shortcuts are familiar:

- downloading an archive without verifying it;
- running upstream helper scripts before source integrity is known;
- installing sample configuration over an existing PBX;
- starting the service immediately after `make install`;
- mixing software installation with SIP trunk, dial-plan and firewall configuration;
- treating a successful build as proof that the PBX is ready for production.

This runbook documents a narrower deployment model: install a pinned Asterisk 22 release from source on AlmaLinux 9, verify the archive before using it, create a dedicated runtime account, install a systemd unit, and leave service activation under explicit operator control.

The companion implementation is maintained in the public repository:

<https://github.com/greksw/asterisk-deployment>

The repository currently pins Asterisk `22.11.0` LTS. The production migration from Asterisk 13 to 22 is a separate task and is intentionally not represented here as already completed.

## Scope

This deployment covers the software layer:

```text
AlmaLinux 9
  -> build dependencies
  -> verified Asterisk source archive
  -> bundled pjproject
  -> make / make install
  -> dedicated asterisk account
  -> systemd unit
  -> optional service activation
```

It does **not** automatically configure:

- SIP/PJSIP trunks;
- extensions;
- dial plan;
- RTP/firewall/NAT policy;
- TLS/SRTP;
- AMI/ARI access;
- CDR storage;
- Fail2Ban;
- monitoring;
- backup policy;
- production migration from an older Asterisk release.

Keeping these layers separate makes rollback and troubleshooting much easier.

## Why Asterisk 22

Asterisk 22 is an LTS release. As of September 2026, the Asterisk project lists the 22.x series as fully supported, with full-support maintenance through October 2028 and security-fix maintenance through October 2029.

Asterisk 13 reached end of life in October 2021. That makes a direct 13-to-22 migration a real platform migration rather than a routine minor-version upgrade.

This distinction matters because configuration syntax and module availability changed substantially across the intervening releases.

## Pin both version and checksum

The deployment helper keeps the release version and expected SHA-256 together:

```bash
DEFAULT_ASTERISK_VERSION='22.11.0'
DEFAULT_ASTERISK_SHA256='3bd5ee040509a3d3cd9b1ba9520c18e6ec0a7e7981ca68c457dcd36ba3c54d94'
```

If the operator overrides the version, a matching checksum must also be supplied.

That prevents a command such as:

```bash
./auto_install_asterisk.sh --version 22.x.y
```

from silently downloading and building a different archive under an old trusted digest.

The release and digest should be reviewed and changed together.

## Preview the deployment before changing the host

The helper supports a non-destructive plan mode:

```bash
./auto_install_asterisk.sh --print-plan
```

Example output describes:

```text
version
sha256
source URL
source workspace
parallel build jobs
whether samples will be installed
whether upstream prerequisite helper will run
whether the systemd service will be enabled
whether Asterisk will be started
```

This is useful in change review and when comparing intended behavior between hosts.

## Validate the operating system

The script deliberately refuses unsupported distributions and currently targets AlmaLinux 9:

```bash
source /etc/os-release

[[ ${ID:-} == 'almalinux' ]]
[[ ${VERSION_ID%%.*} == '9' ]]
```

This is preferable to pretending a source-build script is distribution-independent when package names, CA trust paths, SELinux policy and systemd integration may differ.

## Install deterministic build dependencies

The helper installs an explicit base dependency set with DNF rather than invoking the upstream prerequisite helper by default.

The current base includes packages such as:

```text
ca-certificates
curl
tar
gzip
bzip2
patch
make
gcc
gcc-c++
pkgconf-pkg-config
libedit-devel
jansson-devel
libuuid-devel
sqlite-devel
libxml2-devel
openssl-devel
ncurses-devel
```

The exact list should remain tied to the target distribution and Asterisk build requirements.

## Download only over HTTPS

The source archive is fetched from the official Asterisk download site:

```bash
curl \
  --fail \
  --location \
  --proto '=https' \
  --tlsv1.2 \
  --retry 3 \
  --output "${TARBALL}.tmp" \
  "$SOURCE_URL"
```

Important details:

- plain HTTP is rejected;
- failed HTTP responses abort the command;
- redirects are allowed;
- the partial download uses a temporary filename;
- the archive is not trusted merely because TLS succeeded.

## Verify SHA-256 before extraction

The archive is checked before any source-tree helper or build command executes:

```bash
printf '%s  %s\n' \
  "$ASTERISK_SHA256" \
  "${TARBALL}.tmp" |
sha256sum --check --status
```

Only after verification is the temporary file renamed to the final tarball path.

This changes the trust order from:

```text
download -> execute helper -> build
```

to:

```text
download -> verify -> extract -> execute/build
```

## Keep the source workspace for provenance

The default build workspace is:

```text
/usr/local/src/asterisk-deployment
```

The deployment retains the downloaded archive and extracted source tree after a successful installation.

This is useful for:

- troubleshooting;
- confirming exactly what was built;
- inspecting generated build state;
- comparing a future upgrade with the previous source tree.

A rerun refuses to reuse an already extracted build directory. This prevents accidental incremental builds from an unknown prior state.

## Use bundled pjproject

The build is configured with:

```bash
./configure --with-pjproject-bundled
```

For an Asterisk 22 deployment this keeps the PJSIP dependency aligned with the version shipped and expected by Asterisk rather than relying on an arbitrary system pjproject build.

Then compile and install:

```bash
make -j"$BUILD_JOBS"
make install
make install-logrotate
ldconfig
```

The number of parallel jobs is explicit and can be limited with `--jobs`.

## Do not install sample configuration over a real PBX

`make samples` is intentionally opt-in.

When `--install-samples` is requested, the helper first checks whether `/etc/asterisk` already contains configuration files. If it does, the operation stops instead of overwriting the existing PBX configuration.

Use sample configuration only on a fresh lab host.

That boundary is especially important during a migration: the old production configuration should be treated as source material to review and transform, not as something to replace with upstream defaults.

## Dedicated runtime account

Asterisk runs under a dedicated system account rather than as root.

The helper creates the account when needed and prepares the main directories with restrictive permissions:

```text
/etc/asterisk
/run/asterisk
/var/lib/asterisk
/var/log/asterisk
/var/spool/asterisk
```

Typical ownership model:

```text
asterisk:asterisk -> runtime/data/log/spool
root:asterisk     -> configuration directory
```

Configuration files can remain root-owned while still readable by the Asterisk service group.

## Install a controlled systemd unit

The generated unit uses the actual installed Asterisk binary path detected after `make install`.

Important unit properties include:

```ini
[Service]
Type=simple
User=asterisk
Group=asterisk
RuntimeDirectory=asterisk
RuntimeDirectoryMode=0750
ExecStart=/path/to/asterisk -f -C /etc/asterisk/asterisk.conf
ExecReload=/path/to/asterisk -rx 'core reload'
ExecStop=/path/to/asterisk -rx 'core stop now'
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536
PrivateTmp=true
```

Before activation, validate it:

```bash
systemd-analyze verify /etc/systemd/system/asterisk.service
```

A valid unit is necessary but does not prove that the PBX configuration is valid.

## Installation and activation are separate actions

The default deployment installs Asterisk but does not automatically enable or start it:

```bash
sudo ./auto_install_asterisk.sh --jobs 4
```

This creates a useful review point:

```text
software installed
  -> inspect binary/version
  -> review /etc/asterisk
  -> validate networking/security
  -> only then enable/start
```

Enable the service explicitly:

```bash
sudo ./auto_install_asterisk.sh \
  --enable-service
```

For a fresh lab system with sample configuration:

```bash
sudo ./auto_install_asterisk.sh \
  --install-samples \
  --start
```

`--start` implies service enablement.

## Validate the installed binary

After installation:

```bash
command -v asterisk
asterisk -V
```

After service activation:

```bash
systemctl status asterisk --no-pager
asterisk -rx 'core show version'
```

For a real PBX also validate:

```text
PJSIP transports
endpoint registrations
provider trunks
RTP path
inbound calls
outbound calls
DTMF
caller ID
queue/IVR behavior
voicemail if used
CDR/CEL if used
monitoring and log rotation
```

## Upstream prerequisite helper is opt-in

Asterisk ships `contrib/scripts/install_prereq`.

It is useful, but it can modify the package set beyond the deterministic dependency list maintained by the deployment script.

Therefore it is not run by default.

If needed:

```bash
sudo ./auto_install_asterisk.sh --upstream-prereqs
```

The helper is executed only after the source archive has passed checksum verification.

## Security boundaries before production use

Installing Asterisk is not the same as securely publishing SIP services.

Before production activation review at least:

- PJSIP authentication;
- endpoint and provider ACLs;
- SIP exposure to the Internet;
- RTP port range and firewall rules;
- NAT handling;
- TLS/SRTP requirements;
- AMI/ARI bindings and credentials;
- dial-plan authorization;
- toll-fraud controls;
- Fail2Ban or equivalent controls where appropriate;
- logging and retention;
- monitoring;
- configuration backup and restore;
- SELinux behavior;
- upgrade and rollback process.

Do not open SIP/RTP broadly simply because the daemon is now running.

## Migration boundary: Asterisk 13 to 22

The production migration from Asterisk 13 to 22 should be treated as a separate runbook.

One of the biggest compatibility checks is the SIP channel driver. `chan_sip` was deprecated in Asterisk 17 and removed in Asterisk 21. If the Asterisk 13 system still uses `sip.conf` / `chan_sip`, Asterisk 22 requires migration to `res_pjsip` / `chan_pjsip` rather than a direct configuration copy.

Asterisk provides `contrib/scripts/sip_to_pjsip/sip_to_pjsip.py` as a conversion aid, but the official documentation explicitly describes it as a starting point rather than a converter that handles every configuration.

Other removed modules also need to be inventoried before migration. For example, `app_macro` and `res_monitor` were removed in Asterisk 21.

Therefore the migration should begin with configuration and module inventory, not with copying `/etc/asterisk` to the new server.

## Migration evidence to collect before writing the production runbook

From the current Asterisk 13 server, capture at least:

```bash
asterisk -rx 'core show version'
asterisk -rx 'module show'
asterisk -rx 'sip show settings' 2>/dev/null || true
asterisk -rx 'pjsip show settings' 2>/dev/null || true
asterisk -rx 'dialplan show'
```

And identify the active configuration files:

```bash
find /etc/asterisk -maxdepth 1 -type f -name '*.conf' -printf '%f\n' | sort
```

Do not publish the resulting production configuration without sanitizing:

- SIP passwords;
- provider credentials;
- public IP addresses where sensitive;
- phone numbers;
- AMI/ARI credentials;
- internal naming that should remain private.

Once the migration is actually performed, the stronger article will be the real **Asterisk 13 -> 22 migration runbook** with compatibility findings, test plan, cutover and rollback.

## Rollback model

A fresh Asterisk 22 deployment should not destroy the working Asterisk 13 instance during preparation.

A safer migration pattern is:

```text
build new PBX in parallel
  -> migrate configuration deliberately
  -> test endpoints/trunks
  -> test call flows
  -> define cutover
  -> retain old PBX for rollback
  -> switch traffic
  -> validate
  -> retire old PBX only after acceptance
```

The exact cutover mechanism depends on SIP providers, DNS, IP addressing, NAT and endpoint provisioning.

## References

- Deployment helper: <https://github.com/greksw/asterisk-deployment>
- Asterisk release lifecycle: <https://docs.asterisk.org/About-the-Project/Asterisk-Versions/>
- Asterisk 22 documentation: <https://docs.asterisk.org/Asterisk_22_Documentation/>
- PJSIP configuration: <https://docs.asterisk.org/Configuration/Channel-Drivers/SIP/Configuring-res_pjsip/>
- Migrating from chan_sip to res_pjsip: <https://docs.asterisk.org/Configuration/Channel-Drivers/SIP/Configuring-res_pjsip/Migrating-from-chan_sip-to-res_pjsip/>
- Asterisk module deprecations/removals: <https://docs.asterisk.org/Development/Asterisk-Module-Deprecations/>
