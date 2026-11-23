---
title: "Grafana по HTTPS без SSH-туннеля: Nginx, Microsoft AD CS и AlmaLinux 9"
description: "Production-кейс: CSR с DNS/IP SAN, корпоративный сертификат AD CS, конвертация PEM/DER, Nginx reverse proxy, SELinux и ограничение доступа через firewalld."
category: "Мониторинг и безопасность"
tags: ["grafana", "nginx", "https", "tls", "ad-cs", "pki", "almalinux", "firewalld", "selinux"]
published: 2026-11-23
updated: 2026-11-23
status: current
testedOn: ["AlmaLinux 9.9", "Grafana 13.3.1", "Nginx", "Microsoft AD CS", "OpenSSL", "firewalld", "SELinux Enforcing"]
featured: false
lang: ru
translationKey: "monitoring/grafana-nginx-adcs-https"
---

## Контекст

Grafana была доступна через SSH-туннель:

~~~bash
ssh -N -L 13000:127.0.0.1:3000 ops@192.0.2.24
~~~

Требовалось предоставить постоянный HTTPS-доступ из корпоративных сетей и VPN, сохранив Grafana на `127.0.0.1:3000`, а другие Nginx TLS-сервисы — без изменений.

**Все имена, домены, CA и адреса в статье обезличены.** `192.0.2.24` — демонстрационный адрес из диапазона RFC 5737, а `ad.example.com` — условная зона Active Directory. Реальные имена узлов и адресацию статья не раскрывает.

~~~text
Корпоративный клиент / VPN
    -> HTTPS :443
    -> grafana.ad.example.com (192.0.2.24)
    -> Nginx + сертификат Enterprise CA
    -> HTTP 127.0.0.1:3000
    -> Grafana

Другие TLS listener'ы Nginx: без изменений
~~~

## Исходная диагностика

Сервер работал на AlmaLinux 9.9, Grafana 13.3.1, SELinux `Enforcing`. Nginx уже обслуживал другие endpoints. Перед настройкой проверили:

~~~bash
systemctl is-active nginx grafana-server firewalld
ss -lntp | grep -E ':(3000|443)\b' || true
nginx -t
getenforce
getsebool httpd_can_network_connect
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' \
  http://127.0.0.1:3000/login
~~~

`nginx -t` прошёл, локальный `/login` вернул HTTP 200, порт 443 был свободен, а `httpd_can_network_connect` уже установлен в `on`. SELinux не отключали.

## Внутренний DNS и выбор CA

Во внутренней DNS-зоне AD создали A-запись:

~~~text
grafana.ad.example.com. A 192.0.2.24
~~~

Вариант с Let's Encrypt через публичный DNS-01 отложили: делегирование подзоны AD и ответы обычных DNS-запросов/DoH в этом окружении расходились. Поскольку уже работал **Microsoft AD CS Enterprise Root CA** с шаблоном `WebServer`, использовали его без публикации Grafana в интернет.

На Windows проверили наличие CA:

~~~powershell
certutil -ADCA
~~~

Для выдачи нужны права `Enroll` на шаблон `WebServer`.

## CSR и ключ на Linux

Создаём приватный ключ непосредственно на сервере Grafana и CSR с двумя SAN: DNS и IP. IP SAN нужен только при желании проверять HTTPS по буквальному IP-адресу.

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

**Повторно не генерируйте ключ поверх уже существующего.**

Проверка CSR:

~~~bash
openssl req -in /home/ops/grafana.csr -noout -text |
  grep -A3 'Subject Alternative Name'
~~~

Использовали `-text`: в имеющейся версии OpenSSL комбинация `openssl req -noout -subject -ext subjectAltName` завершалась ошибкой аргументов.

## Выдача через AD CS без передачи приватного ключа

Windows с доступом к CA не имел SSH-доступа непосредственно к Linux-серверу. Поэтому **CSR и публичные сертификаты** передавали через Ubuntu-ноутбук:

~~~text
Linux --SCP--> Ubuntu-ноутбук --SCP--> Windows/AD CS
Linux <--SCP-- Ubuntu-ноутбук <--SCP-- Windows/AD CS
~~~

Закрытый `grafana.key` оставался только на Linux. На Windows, после получения CSR:

~~~powershell
certreq -submit -config "dc01.ad.example.com\Example-Enterprise-Root-CA" -attrib "CertificateTemplate:WebServer" .\grafana.csr .\grafana.cer
~~~

Запрос получил Request ID и сертификат был выдан. Повторный `certreq -retrieve` не нужен при наличии готового `grafana.cer`.

**Проверяем SAN и EKU в готовом сертификате**, а не только в CSR: политика CA может не скопировать расширения из запроса.

~~~powershell
$cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
  (Resolve-Path .\grafana.cer).Path
)
$cert | Format-List Subject,Issuer,NotBefore,NotAfter
$cert.Extensions |
  Where-Object { $_.Oid.Value -in @("2.5.29.17","2.5.29.37") } |
  ForEach-Object { $_.Format($true) }
~~~

В выданном сертификате подтверждены DNS SAN, IP SAN и EKU `Server Authentication` (`1.3.6.1.5.5.7.3.1`).

## Экспорт корневого CA и форматы PEM/DER

Попытка `certutil -ca.cert` в данном сеансе закончилась ошибкой синтаксиса. Публичный CA экспортировали через PowerShell из хранилища Windows, предварительно проверив его отпечаток:

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

`Export-Certificate` экспортирует здесь только **публичный** сертификат CA. Его fingerprint следует сверять по независимому каналу перед установкой доверия.

Переданные через ноутбук файлы имели разные форматы: `grafana.cer` — **PEM**, корневой `.cer` — **DER**. Суффикс файла формат не определяет.

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

### Проверка цепочки, SAN и приватного ключа

~~~bash
D=/etc/nginx/tls/grafana
openssl verify -purpose sslserver -CAfile "$D/ca.crt" "$D/grafana.crt"
openssl x509 -in "$D/grafana.crt" -noout -checkhost grafana.ad.example.com
openssl x509 -in "$D/grafana.crt" -noout -checkip 192.0.2.24
openssl pkey -in "$D/grafana.key" -pubout -outform DER | sha256sum
openssl x509 -in "$D/grafana.crt" -pubkey -noout |
  openssl pkey -pubin -outform DER | sha256sum
~~~

Цепочка: `OK`; DNS/IP SAN совпали; оба SHA-256-хеша публичного ключа были одинаковыми. `openssl verify` здесь не выполняет проверку отзыва CRL/OCSP.

## Nginx: HTTPS и WebSocket

Создали отдельный `/etc/nginx/conf.d/grafana.conf`. Директива `map` размещается в Nginx `http` context (стандартный `conf.d/*.conf`):

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

`/api/live/` требует поддержки WebSocket. TLS завершается в Nginx, поэтому внутренний `proxy_pass` использует HTTP.

~~~bash
nginx -t && systemctl reload nginx
ss -lntp | grep -E ':(443|3000)\b'
~~~

## Правильный root_url в Grafana

Вместо редактирования `grafana.ini` используется systemd drop-in `/etc/systemd/system/grafana-server.service.d/10-public-url.conf`:

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

`enforce_domain=false` оставляет возможность обращения по IP при наличии IP SAN; ссылки Grafana при этом продолжают использовать `root_url`. Для штатной работы, включая Origin-проверки Grafana Live, предпочтителен DNS-адрес.

## Firewall только для разрешённых источников

Глобально открывать `https` на весь интерфейс не стали. Использовали `firewalld rich rules` по конкретным сетям/хостам. **Следующие адреса демонстрационные**, они не совпадают с реальной инфраструктурой:

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

Правила добавлены в runtime и permanent без `firewall-cmd --reload`, который мог бы сбросить прочие временные правила.

Для удалённых подсетей нужно проверить маршруты и возможный NAT:

~~~bash
ip -4 route get 10.20.30.10
ip -4 route show default
~~~

Разрешение на самом сервере не гарантирует прохождение трафика через промежуточные маршрутизаторы.

## Проверка результата

~~~bash
curl --noproxy '*' \
  --cacert /etc/nginx/tls/grafana/ca.crt \
  --resolve grafana.ad.example.com:443:192.0.2.24 \
  https://grafana.ad.example.com/api/health

curl --noproxy '*' -sS -o /dev/null -w 'HTTP %{http_code}\n' \
  --cacert /etc/nginx/tls/grafana/ca.crt \
  https://192.0.2.24/login
~~~

С доверяющего CA клиента Ubuntu:

~~~bash
getent ahostsv4 grafana.ad.example.com
nc -vz -w 5 192.0.2.24 443
curl -I https://grafana.ad.example.com/login
~~~

**Подтверждённый результат:** API вернул `database: ok` и Grafana `13.3.1`; HTTPS `/login` по домену и IP отвечал `HTTP 200`. Ubuntu подключилась с проверкой CA и без `-k`. Соседние Nginx listener'ы сохранились.

## Нюансы диагностики и откат

| Симптом | Причина | Что делать |
| --- | --- | --- |
| OpenSSL не читает `.cer` как DER | Файл в PEM | Проверить `file` и `-inform PEM` |
| Ошибка `certutil -ca.cert` | Неподходящий синтаксис | `Export-Certificate` из Windows |
| `ssh.service` inactive, но порт 22 слушает systemd | Socket activation | Проверить `ssh.socket` |
| SAN есть в CSR, но нет в конечном сертификате | Политика шаблона/CA | Проверить leaf; согласовать изменение PKI |
| HTTPS работает локально, но не из другого VLAN | Маршрут/firewall/NAT | Проверить фактический source IP и обратный маршрут |

Откат: сохранить/убрать **только** новый Nginx virtual host, проверить `nginx -t` и reload; при необходимости удалить только добавленный systemd drop-in Grafana; убрать соответствующие TCP/443 rich rules из runtime/permanent. Не очищать зону firewalld и не менять другие Nginx listener'ы.

Сертификат в кейсе выдан на два года, но **автоматическое продление пока не настроено**. Рекомендуется отдельный контроль даты истечения через Blackbox Exporter/Prometheus.

## Ссылки

- [Grafana: Run behind a reverse proxy](https://grafana.com/tutorials/run-grafana-behind-a-proxy/)
- [Grafana: Live and WebSockets](https://grafana.com/docs/grafana/latest/setup-grafana/set-up-grafana-live/)
- [Microsoft Learn: certreq](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/certreq_1)
- [firewalld: rich rules](https://firewalld.org/documentation/man-pages/firewalld.richlanguage.html)
