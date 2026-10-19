---
title: "HTTPS для NetBox через Microsoft AD CS: CSR, SAN, Nginx и доверие Linux"
description: "Практическая настройка HTTPS на NetBox под AlmaLinux: приватный ключ и CSR через OpenSSL, выпуск сертификата в Microsoft AD CS по шаблону WebServer, TLS в Nginx и устранение предупреждений Chrome в Ubuntu."
category: "Информационная безопасность"
tags: ["netbox", "https", "tls", "pki", "adcs", "active-directory", "openssl", "nginx", "certreq", "ubuntu", "nss"]
published: 2026-10-19
updated: 2026-10-19
status: current
testedOn: ["AlmaLinux 9.8", "NetBox 4.7.3", "Nginx", "Microsoft Active Directory Certificate Services", "Ubuntu Linux", "Google Chrome"]
featured: false
lang: ru
translationKey: "security/netbox-microsoft-adcs-https"
---

## Контекст

После [установки NetBox на AlmaLinux](/ru/notes/linux/netbox-almalinux9-deployment/) приложение работало через Nginx и Gunicorn, но доступ по HTTP не защищал сеанс. Поскольку NetBox — внутренний сервис, для него не требуется публичный УЦ или самоподписанный сертификат: можно использовать собственную **Microsoft Active Directory Certificate Services (AD CS)**.

В рабочей инфраструктуре сертификат был выпущен корпоративным Enterprise Root CA по шаблону `WebServer` и применён в Nginx на Linux. Проверки подтвердили HTTPS, цепочку доверия и корректное сопоставление DNS-имени. На рабочем месте Ubuntu/Chrome первоначально оставалось предупреждение, которое исчезло после корректной установки корневого сертификата УЦ в доверенные хранилища.

Реальные домены, имена серверов, адреса и название УЦ заменены на демонстрационные. Команды оформлены как воспроизводимый пример процедуры, а не буквальная копия рабочего терминального журнала.

## 01 / Архитектура доверия

```text
Microsoft AD CS (Enterprise Root CA)
          │ подписывает CSR
          ▼
NetBox / AlmaLinux / Nginx
  netbox.lab.shandrov.ru:443
          │ отдаёт серверный сертификат
          ▼
Ubuntu / Chrome
  └── доверяет корневому сертификату корпоративного УЦ
```

Не путайте два разных условия:

1. **Шифрование TLS**: Nginx имеет сертификат и приватный ключ, принимает HTTPS-подключение.
2. **Доверие клиента**: браузер знает корневой УЦ, срок сертификата корректен, а DNS-имя совпадает с **SAN**.

Подписанный корпоративным УЦ сертификат **не будет автоматически доверенным** на обычной Linux-машине, которая ещё не получила корневой сертификат CA.

В примерах используются вымышленные `netbox.lab.shandrov.ru`, `ca01.ad.lab.shandrov.ru`, `Lab-Enterprise-Root-CA` и `192.0.2.10`. Замените их на свои значения.

## 02 / DNS и параметры сертификата

До выпуска сертификата создаём корректную A-запись DNS для NetBox и проверяем её с клиента:

```bash
getent ahostsv4 netbox.lab.shandrov.ru
```

Планируем сертификат со следующими параметрами:

| Поле | Значение |
| --- | --- |
| Subject CN | `netbox.lab.shandrov.ru` |
| Subject Alternative Name | `DNS:netbox.lab.shandrov.ru` |
| Key type | RSA 3072 |
| Hash | SHA-256 |
| Extended Key Usage | TLS Web Server Authentication (`serverAuth`) |
| Template | `WebServer` |
| Issuer | Внутренний Microsoft AD CS |

Современные браузеры проверяют имя прежде всего по расширению **SAN**, одного поля CN недостаточно. Шаблон AD CS должен разрешать заявителю поставлять DNS-имя в запросе (`Supply in the request`) и содержать назначение Server Authentication. Доступ к выпуску сертификата нужно предоставить только авторизованным администраторам/сервисам.

## 03 / Создание приватного ключа и CSR на AlmaLinux

Закрытый ключ создаём **на Linux-сервере NetBox** и не передаём на контроллер домена или рабочую станцию Windows. Временный файл конфигурации OpenSSL удобно хранить рядом с закрытым ключом, с ограниченными правами:

```bash
sudo install -d -m 700 /etc/pki/tls/private/netbox
sudo sh -c 'umask 077; cat > /etc/pki/tls/private/netbox/req.cnf' <<'EOF'
[req]
default_md = sha256
prompt = no
distinguished_name = dn
req_extensions = req_ext

[dn]
CN = netbox.lab.shandrov.ru

[req_ext]
subjectAltName = DNS:netbox.lab.shandrov.ru
extendedKeyUsage = serverAuth
keyUsage = critical,digitalSignature,keyEncipherment
EOF

sudo openssl req -new -newkey rsa:3072 -noenc \
  -keyout /etc/pki/tls/private/netbox.lab.shandrov.ru.key \
  -out /tmp/netbox.lab.shandrov.ru.csr \
  -config /etc/pki/tls/private/netbox/req.cnf

sudo chmod 600 /etc/pki/tls/private/netbox.lab.shandrov.ru.key
```

Ключ хранится на сервере, а **CSR можно передавать** на Windows для подписи. Проверяем содержание запроса:

```bash
openssl req -in /tmp/netbox.lab.shandrov.ru.csr \
  -noout -subject -text | grep -A 8 -E 'Subject:|Subject Alternative Name'
```

> Опция `-noenc` доступна в современных OpenSSL 3.x (AlmaLinux 9); если используете старый OpenSSL, проверьте поддерживаемый синтаксис. Не применяйте к приватному ключу `chmod 644` и не включайте его содержимое в репозиторий.

## 04 / Подпись запроса в Microsoft AD CS

Копируем **только CSR** на доверенную Windows-машину с доступом к Enterprise CA. Далее выполняем в PowerShell или `cmd.exe` (путь к CSR — пример):

```powershell
certreq -submit `
  -config 'ca01.ad.lab.shandrov.ru\Lab-Enterprise-Root-CA' `
  -attrib 'CertificateTemplate:WebServer' `
  'C:\Temp\netbox.lab.shandrov.ru.csr' `
  'C:\Temp\netbox.lab.shandrov.ru.cer'
```

Если AD CS требует подтверждения заявки, администратор CA одобряет её по принятому процессу и затем скачивает выданный сертификат по идентификатору запроса. Для шаблона `WebServer` должны быть разрешены права **Enroll**, а DNS/SAN — соответствовать политике выпуска. Не ослабляйте права шаблона ради одной выдачи.

Копируем полученный **сертификат без приватного ключа** обратно на Linux. Если `.cer` в DER-формате, конвертируем в PEM:

```bash
openssl x509 -inform DER \
  -in netbox.lab.shandrov.ru.cer \
  -out netbox.lab.shandrov.ru.crt
```

Если `.cer` уже содержит `-----BEGIN CERTIFICATE-----`, конвертация не нужна: просто сохраните PEM в файл `.crt`.

## 05 / Проверка сертификата до включения TLS

```bash
openssl x509 -in netbox.lab.shandrov.ru.crt \
  -noout -subject -issuer -dates

openssl x509 -in netbox.lab.shandrov.ru.crt \
  -noout -ext subjectAltName,extendedKeyUsage
```

Проверяем, что открытый ключ сертификата соответствует **локальному** приватному ключу, сравнивая хеши public key:

```bash
openssl x509 -in netbox.lab.shandrov.ru.crt -pubkey -noout \
  | openssl pkey -pubin -outform DER | sha256sum

sudo openssl pkey \
  -in /etc/pki/tls/private/netbox.lab.shandrov.ru.key \
  -pubout -outform DER | sha256sum
```

Две контрольные суммы должны совпасть. Для прямой подписи корневым CA также проверяем цепочку:

```bash
openssl verify -CAfile Lab-Enterprise-Root-CA.crt \
  netbox.lab.shandrov.ru.crt
```

Если в организации есть подчинённый CA, для проверки и конфигурации Nginx потребуется соответствующая **цепочка промежуточных сертификатов**, а не один корневой сертификат.

## 06 / Размещение файлов и Nginx

```bash
sudo install -o root -g root -m 0644 \
  netbox.lab.shandrov.ru.crt \
  /etc/pki/tls/certs/netbox.lab.shandrov.ru.crt

sudo chown root:root /etc/pki/tls/private/netbox.lab.shandrov.ru.key
sudo chmod 600 /etc/pki/tls/private/netbox.lab.shandrov.ru.key
sudo restorecon -v \
  /etc/pki/tls/certs/netbox.lab.shandrov.ru.crt \
  /etc/pki/tls/private/netbox.lab.shandrov.ru.key
```

Обновляем `/etc/nginx/conf.d/netbox.conf`:

```nginx
server {
    listen 80;
    server_name netbox.lab.shandrov.ru;
    return 301 https://netbox.lab.shandrov.ru$request_uri;
}

server {
    listen 443 ssl;
    server_name netbox.lab.shandrov.ru;

    ssl_certificate     /etc/pki/tls/certs/netbox.lab.shandrov.ru.crt;
    ssl_certificate_key /etc/pki/tls/private/netbox.lab.shandrov.ru.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 20m;

    location /static/ {
        alias /opt/netbox/netbox/static/;
    }

    location / {
        proxy_pass http://127.0.0.1:8001;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
```

В рабочем случае TLS-порт был дополнительно привязан к конкретному адресу интерфейса (`listen <адрес>:443 ssl`), чтобы избежать ненужного прослушивания на остальных IP. В коде выше показан переносимый вариант; при нескольких адресах сервера задайте нужный IP явно.

Проверяем Nginx и права доступа:

```bash
sudo nginx -t
sudo systemctl reload nginx
sudo ss -lntp | grep ':443'
sudo journalctl -u nginx -n 60 --no-pager
```

Для firewalld сохраняем доступ к 443 только из административной или доверенной сети (адрес здесь пример):

```bash
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="10.20.30.0/24" service name="https" accept'
sudo firewall-cmd --reload
```

Проверьте также, что в `ALLOWED_HOSTS` NetBox есть используемый FQDN. Если NetBox не распознаёт HTTPS за Nginx, проверьте согласованность `X-Forwarded-Proto` и параметров доверенного reverse proxy, не отключая проверки безопасности.

## 07 / Проверка HTTPS без отключения проверки сертификата

Первичная проверка на клиенте, которому ещё не доверен внутренний CA:

```bash
curl --cacert ./Lab-Enterprise-Root-CA.crt \
  -I https://netbox.lab.shandrov.ru/

openssl s_client \
  -connect netbox.lab.shandrov.ru:443 \
  -servername netbox.lab.shandrov.ru \
  -CAfile ./Lab-Enterprise-Root-CA.crt \
  -verify_return_error < /dev/null
```

Контролируем `HTTP 200` или ожидаемый редирект, согласованный `subjectAltName` и `Verify return code: 0 (ok)`. **Не используйте `curl -k` как доказательство корректной TLS-настройки**: этот ключ отключает проверку доверия и имени.

## 08 / Почему Ubuntu/Chrome продолжал показывать предупреждение

На Linux машинах, не включённых в домен, внутренний Enterprise CA обычно отсутствует в системном trust store. Серверная настройка TLS может быть полностью корректной, но браузер будет считать удостоверяющий центр неизвестным.

Сначала получаем корневой сертификат УЦ **по доверенному каналу**. Сверяем его SHA-256-отпечаток с опубликованным администратором PKI:

```bash
openssl x509 -in Lab-Enterprise-Root-CA.crt \
  -noout -subject -issuer -fingerprint -sha256
```

Импорт в системное хранилище доверенных CA Ubuntu:

```bash
sudo install -o root -g root -m 0644 \
  Lab-Enterprise-Root-CA.crt \
  /usr/local/share/ca-certificates/lab-enterprise-root-ca.crt
sudo update-ca-certificates

curl -I https://netbox.lab.shandrov.ru/
```

На некоторых установках Chrome используется пользовательская NSS-база. В нашем случае потребовалось добавить корневой CA и в NSS с атрибутом доверия `C,,`:

```bash
sudo apt install -y libnss3-tools
mkdir -p "$HOME/.pki/nssdb"

if [ ! -f "$HOME/.pki/nssdb/cert9.db" ]; then
  certutil -N -d "sql:$HOME/.pki/nssdb" --empty-password
fi

certutil -A \
  -d "sql:$HOME/.pki/nssdb" \
  -n "Lab-Enterprise-Root-CA" \
  -t "C,," \
  -i ./Lab-Enterprise-Root-CA.crt

certutil -L -d "sql:$HOME/.pki/nssdb"
```

Импорт выполняется от имени **обычного пользователя браузера**, а не через `sudo certutil`. Если сертификат с таким именем уже существует, сначала изучите текущую запись. В разных версиях Linux и Chrome может использоваться системный или другой пользовательский trust store — проверьте конкретную сборку браузера.

**Фактический результат:** после импорта корпоративного корневого CA предупреждение Chrome исчезло; проверка `openssl s_client` и `curl` подтверждала доверенную цепочку TLS.

## 09 / Диагностика типовых ошибок

| Симптом | Причина | Проверка / действие |
| --- | --- | --- |
| Chrome: сертификат не доверен | Корневой AD CS отсутствует у клиента | Проверить SHA-256, системное хранилище и NSS |
| `ERR_CERT_COMMON_NAME_INVALID` | FQDN отсутствует в SAN | Проверить `openssl x509 -ext subjectAltName` и DNS |
| `curl: (60) SSL certificate problem` | Недоверенная или неполная цепочка | `curl --cacert`, `openssl s_client`, промежуточные CA |
| Nginx не запускается | Не читается ключ, неправильный PEM или SELinux | `nginx -t`, `journalctl`, `ausearch -m AVC` |
| `502 Bad Gateway` | Gunicorn выключен или Nginx направляет не на тот порт | `systemctl status netbox`, `ss -lntp` |
| Вход по HTTPS, затем странные редиректы | Не согласованы proxy headers и настройки NetBox | `X-Forwarded-Proto`, `ALLOWED_HOSTS`, конфигурация proxy |

## 10 / Проверка после обновления NetBox до 4.7.3

19 октября 2026 года, после [обновления приложения](/ru/notes/linux/netbox-upgrade-4-7-1-to-4-7-3/), повторно проверили TLS на сервере с установленным корпоративным корневым CA: `curl` вернул **HTTP 302, SSL verify result 0**. `openssl x509` подтвердил DNS SAN, прямую подпись Enterprise Root CA и действие сертификата с **19.10.2026 до 18.10.2028**. Перевыпуск сертификата для патч-обновления NetBox не потребовался.

## 11 / Эксплуатация и продление

Сертификат имеет ограниченный срок действия. После его продления необходимо проверить SAN, пару «ключ — сертификат», цепочку и выполнить `nginx -t && systemctl reload nginx`. Для автоматизации подойдут мониторинг срока сертификата и регламент перевыпуска. **Экспортировать приватный ключ на Windows для выпуска сертификата не требуется.**

Корневой сертификат УЦ — открытая часть PKI, но его распространение требует **проверки подлинности**. Сертификат сервера, приватный ключ и доступ к шаблону AD CS имеют разные уровни чувствительности: приватный ключ никогда не размещайте на GitHub или в общедоступных статьях.

## Результат

NetBox обслуживается через **HTTPS**, серверный сертификат подписан корпоративным Microsoft AD CS, а Linux-клиент доверяет этому УЦ. Отсутствие предупреждения в браузере стало результатом двух проверенных частей: правильного сертификата с SAN на Nginx и корректно настроенного доверия клиента.

## Источники

- [NetBox — HTTP Server Setup](https://netbox.readthedocs.io/en/stable/installation/5-http-server/)
- [OpenSSL — TLS Certificate Requests](https://docs.openssl.org/3.0/man1/openssl-req/)
- [Microsoft Learn — certreq](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/certreq_1)
- [NSS certutil — справка](https://manpages.ubuntu.com/manpages/noble/man1/certutil.1.html)