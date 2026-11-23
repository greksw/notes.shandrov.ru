---
title: "Grafana over HTTPS without SSH tunneling: Nginx, Microsoft AD CS and AlmaLinux 9"
description: "Production case study: DNS/IP SAN CSR, enterprise CA enrollment, PEM/DER handling, Nginx reverse proxy, SELinux, and source-restricted firewalld."
category: "Monitoring & Security"
tags: ["grafana", "nginx", "https", "tls", "ad-cs", "pki", "almalinux", "firewalld", "selinux"]
published: 2026-11-23
updated: 2026-11-23
status: current
testedOn: ["AlmaLinux 9.9", "Grafana 13.3.1", "Nginx", "Microsoft AD CS", "OpenSSL", "firewalld", "SELinux Enforcing"]
featured: false
lang: en
translationKey: "monitoring/grafana-nginx-adcs-https"
---

## Starting point

Grafana was only available through an SSH local forward:

~~~bash
ssh -N -L 13000:127.0.0.1:3000 ops@192.0.2.24
~~~

The objective was direct HTTPS access from corporate management networks and VPN, while retaining Grafana on `127.0.0.1:3000` and keeping other existing Nginx services untouched.

The implementation was validated with **AlmaLinux 9.9**, **Grafana 13.3.1**, Nginx, SELinux in `Enforcing` mode, firewalld and a Microsoft AD CS Enterprise Root CA.

**Every domain, CA name, hostname and IP address below is anonymized.** `192.0.2.24` is an RFC 5737 documentation address; `ad.example.com` is a placeholder Active Directory zone. Replace these with your own environment's values.

~~~text
Corporate client / VPN
   -> HTTPS :443
   -> grafana.ad.example.com (192.0.2.24)
   -> Nginx + Enterprise CA certificate
   -> HTTP 127.0.0.1:3000
   -> Grafana

Other Nginx TLS listeners: unchanged
~~~

The private key is generated on the Linux server and is never exported.

## Preflight checks

~~~bash
systemctl is-active nginx grafana-server firewalld
ss -lntp | grep -E ':(3000|443)\b' || true
nginx -t
getenforce
getsebool httpd_can_network_connect
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' \
  http://127.0.0.1:3000/login
~~~

Nginx and Grafana were running, TCP/443 was unused, the `nginx -t` check passed, and the local Grafana login returned HTTP 200. SELinux remained enforcing and `httpd_can_network_connect` was already enabled.

## Internal DNS and choosing AD CS

An internal Active Directory DNS record was created:

~~~text
grafana.ad.example.com. A 192.0.2.24
~~~

Public delegation and responses from traditional DNS versus DNS-over-HTTPS were inconsistent for the AD subzone. Rather than changing public DNS or exposing Grafana, we used an existing **Microsoft AD CS Enterprise Root CA** with the `WebServer` template.

On Windows:

~~~powershell
certutil -ADCA
~~~

Ensure the requesting identity has `Enroll` permission for the selected template.

## Generate the CSR and key on Linux

The CSR includes both a DNS SAN and an optional IP SAN for TLS verification by literal address.

~~~bash
umask 077
install -d -m 700 /etc/nginx/tls/grafana
openssl req -new -newkey rsa:3072 -nodes -sha256 \
  -keyout /etc/nginx/tls/grafana/grafana.key \
  -out /home/ops/grafana.csr \
  -subj "/CN=grafana.ad.example.com" \
  -addext "subjectAltName=DNS:grafana.ad.example.com,IP:192.0.2.24"
chmod 600 /etc/nginx/tls/grafana/grafana.key
chown ops:ops /home/ops/grafana.csr
~~~

**Do not regenerate the key on top of an existing one.**

~~~bash
openssl req -in /home/ops/grafana.csr -noout -text |
  grep -A3 'Subject Alternative Name'
~~~

The tested OpenSSL build did not accept the attempted `openssl req -noout -subject -ext subjectAltName` combination; `-text` worked.

## AD CS enrollment via an Ubuntu relay laptop

Windows had access to the domain CA but no direct SSH access to the Linux monitoring server. An Ubuntu laptop relayed **only the CSR and the public certificates**:

~~~text
Linux --SCP--> Ubuntu laptop --SCP--> Windows/AD CS
Linux <--SCP-- Ubuntu laptop <--SCP-- Windows/AD CS
~~~

The TLS private key stayed on Linux. Once Windows had the CSR:

~~~powershell
certreq -submit -config "dc01.ad.example.com\Example-Enterprise-Root-CA" -attrib "CertificateTemplate:WebServer" .\grafana.csr .\grafana.cer
~~~

The CA issued the certificate. Do not repeat `certreq -retrieve` once the issued `grafana.cer` file exists. For Pending or Denied responses, inspect the existing request and enroll permissions.

Validate the **issued certificate**, not merely the CSR: CA/template policy determines which SAN extensions reach the leaf certificate.

~~~powershell
$cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
  (Resolve-Path .\grafana.cer).Path
)
$cert | Format-List Subject,Issuer,NotBefore,NotAfter
$cert.Extensions |
  Where-Object { $_.Oid.Value -in @("2.5.29.17","2.5.29.37") } |
  ForEach-Object { $_.Format($true) }
~~~

The issued certificate contained DNS SAN, IP SAN and `Server Authentication` EKU (`1.3.6.1.5.5.7.3.1`).

## Export the corporate root and resolve PEM vs DER

The attempted `certutil -ca.cert` syntax yielded an argument error in this session. Exporting the **public** CA certificate through the Windows PowerShell certificate store worked instead:

~~~powershell
$ca = @(
  Get-ChildItem Cert:\LocalMachine\Root |
    Where-Object {
      $_.Subject -like "*CN=Example-Enterprise-Root-CA*" -and
      $_.Subject -eq $_.Issuer
    }
)
if ($ca.Count -ne 1) { throw "CA certificate missing or ambiguous" }
$ca[0] | Format-List Subject,Thumbprint,NotAfter
Export-Certificate -Cert $ca[0] -FilePath .\Example-Enterprise-Root-CA.cer -Type CERT
~~~

Validate the root CA fingerprint via an independent trusted channel before trusting it on additional clients.

The returned `grafana.cer` was **PEM**, whereas the exported root `.cer` was **DER**. The extension does not determine the encoding.

~~~bash
file /home/ops/grafana.cer
file /home/ops/Example-Enterprise-Root-CA.cer

openssl x509 -inform PEM -in /home/ops/grafana.cer \
  -out /etc/nginx/tls/grafana/grafana.crt
openssl x509 -inform DER -in /home/ops/Example-Enterprise-Root-CA.cer \
  -out /etc/nginx/tls/grafana/ca.crt

chown root:root /etc/nginx/tls/grafana/*
chmod 600 /etc/nginx/tls/grafana/grafana.key
chmod 644 /etc/nginx/tls/grafana/grafana.crt /etc/nginx/tls/grafana/ca.crt
restorecon -Rv /etc/nginx/tls/grafana
~~~

### Validate the chain, SAN and key match

~~~bash
D=/etc/nginx/tls/grafana
openssl verify -purpose sslserver -CAfile "$D/ca.crt" "$D/grafana.crt"
openssl x509 -in "$D/grafana.crt" -noout -checkhost grafana.ad.example.com
openssl x509 -in "$D/grafana.crt" -noout -checkip 192.0.2.24
openssl pkey -in "$D/grafana.key" -pubout -outform DER | sha256sum
openssl x509 -in "$D/grafana.crt" -pubkey -noout |
  openssl pkey -pubin -outform DER | sha256sum
~~~

The chain returned `OK`, both SANs matched and both SHA-256 public-key digests were identical. Note that `openssl verify` here does **not** check CRL/OCSP revocation.

## Nginx HTTPS reverse proxy

Create a separate `/etc/nginx/conf.d/grafana.conf` file. The `map` must be within the Nginx `http` context, which normally includes `conf.d/*.conf`:

~~~nginx
map $http_upgrade $grafana_live_connection {
    default upgrade;
    ''      close;
}

server {
    listen 192.0.2.24:443 ssl;
    server_name grafana.ad.example.com 192.0.2.24;
    ssl_certificate     /etc/nginx/tls/grafana/grafana.crt;
    ssl_certificate_key /etc/nginx/tls/grafana/grafana.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_tickets off;

    access_log /var/log/nginx/grafana-access.log;
    error_log /var/log/nginx/grafana-error.log warn;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 90s;
    }

    location /api/live/ {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $grafana_live_connection;
        proxy_read_timeout 3600s;
    }
}
~~~

The `/api/live/` location supports WebSocket upgrades. Use plain HTTP for `proxy_pass` because Nginx terminates TLS.

~~~bash
nginx -t && systemctl reload nginx
ss -lntp | grep -E ':(443|3000)\b'
~~~

## Set the canonical Grafana URL

Instead of editing packaged `grafana.ini`, create `/etc/systemd/system/grafana-server.service.d/10-public-url.conf`:

~~~ini
[Service]
Environment="GF_SERVER_PROTOCOL=http"
Environment="GF_SERVER_HTTP_ADDR=127.0.0.1"
Environment="GF_SERVER_DOMAIN=grafana.ad.example.com"
Environment="GF_SERVER_ROOT_URL=https://grafana.ad.example.com/"
Environment="GF_SERVER_ENFORCE_DOMAIN=false"
~~~

~~~bash
systemctl daemon-reload
systemctl restart grafana-server
systemctl is-active grafana-server
~~~

`enforce_domain=false` permits direct-IP testing when an IP SAN exists, while generated Grafana URLs still use `root_url`. Prefer the DNS name for everyday browser use, especially for Grafana Live Origin checks.

## Restrict source access with firewalld

Avoid globally opening the `https` service. Use rich rules for only the required subnets/hosts. The addresses below are **illustrative**, not the actual network layout:

~~~bash
for src in "10.20.30.0/24" "10.20.40.0/24" "10.20.50.2/32"; do
  rule="rule family=\"ipv4\" source address=\"$src\" port port=\"443\" protocol=\"tcp\" accept"
  firewall-cmd --zone=public --query-rich-rule="$rule" >/dev/null ||
    firewall-cmd --zone=public --add-rich-rule="$rule"
  firewall-cmd --permanent --zone=public --query-rich-rule="$rule" >/dev/null ||
    firewall-cmd --permanent --zone=public --add-rich-rule="$rule"
done
firewall-cmd --zone=public --list-rich-rules
firewall-cmd --permanent --zone=public --list-rich-rules
~~~

Both runtime and permanent rules were updated without a disruptive `firewall-cmd --reload`.

For remote networks, also verify the return route, transit firewall policy and possible NAT:

~~~bash
ip -4 route get 10.20.30.10
ip -4 route show default
~~~

An allow rule on the host alone does not confirm end-to-end connectivity to a remote VLAN.

## End-to-end validation

~~~bash
curl --noproxy '*' \
  --cacert /etc/nginx/tls/grafana/ca.crt \
  --resolve grafana.ad.example.com:443:192.0.2.24 \
  https://grafana.ad.example.com/api/health

curl --noproxy '*' -sS -o /dev/null -w 'HTTP %{http_code}\n' \
  --cacert /etc/nginx/tls/grafana/ca.crt \
  https://192.0.2.24/login
~~~

From an Ubuntu client trusting the corporate root:

~~~bash
getent ahostsv4 grafana.ad.example.com
nc -vz -w 5 192.0.2.24 443
curl -I https://grafana.ad.example.com/login
~~~

**Verified result:** `/api/health` returned `database: ok` and Grafana `13.3.1`; HTTPS `/login` returned HTTP 200 using either DNS or IP. Ubuntu completed trusted TLS verification without `-k`, and unrelated Nginx listeners continued operating.

## Troubleshooting and rollback

| Symptom | Root cause | Corrective action |
| --- | --- | --- |
| OpenSSL cannot read the leaf `.cer` as DER | Leaf is PEM | Inspect `file` and use `-inform PEM` |
| `certutil -ca.cert` reports too many arguments | Incorrect invocation | Use Windows `Export-Certificate` |
| `ssh.service` inactive while systemd listens on 22 | Socket activation | Inspect `ssh.socket` |
| CSR has SAN but leaf lacks it | CA/template policy | Validate issued leaf and adjust PKI policy |
| HTTPS works locally but not from a remote VLAN | Routes, firewall or NAT | Inspect effective source and return path |

For rollback, back up and remove **only** the new Grafana Nginx server block, test/reload Nginx, optionally remove the Grafana systemd drop-in and restart Grafana, and remove only matching TCP/443 rich rules in runtime and permanent. Do not reset the entire firewalld zone or modify unrelated Nginx listeners.

The leaf certificate in this case was issued for **two years**; **automatic renewal was not configured**. Monitor expiration and plan re-issuance, for example using Blackbox Exporter and Prometheus.

## References

- [Grafana reverse proxy tutorial](https://grafana.com/tutorials/run-grafana-behind-a-proxy/)
- [Grafana Live documentation](https://grafana.com/docs/grafana/latest/setup-grafana/set-up-grafana-live/)
- [Microsoft certreq documentation](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/certreq_1)
- [firewalld rich rules](https://firewalld.org/documentation/man-pages/firewalld.richlanguage.html)
