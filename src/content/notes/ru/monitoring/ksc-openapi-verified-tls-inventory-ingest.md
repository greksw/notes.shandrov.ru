---
title: "KSC Open API: проверка TLS-цепочки и безопасная доставка JSON в Inventory API"
description: "Разбор ошибки self-signed certificate in certificate chain, HTTPS через SSH-туннель и ограниченная SSH-учётная запись для загрузки RAM-отчётов в FastAPI/SQLite."
category: "Мониторинг и безопасность"
tags: ["kaspersky", "ksc", "tls", "openssl", "python", "ssh", "fastapi", "sqlite", "security"]
published: 2026-10-22
updated: 2026-10-23
status: current
testedOn: ["Kaspersky Security Center 15.1", "Python 3.12", "OpenSSL", "AlmaLinux 9", "FastAPI", "OpenSSH"]
featured: false
lang: ru
translationKey: "monitoring/ksc-openapi-verified-tls-inventory-ingest"
---

## Задача: зашифровать недостаточно — нужно проверить сервер

Рабочий пилот инвентаризации оборудования через KSC Open API первоначально использовал `verify=False` при подключении через локальный SSH-туннель. Для постоянного решения такой режим неприемлем: клиент не проверяет, что отвечает именно доверенный сервер.

Нужно было включить полноценную проверку TLS **без ручной замены сертификатов KSC**, которая могла бы затронуть доверие между Administration Server и Network Agent. Отдельно требовалось доставить JSON в Inventory API без копирования API-токена на управляющую машину и без автоматизированного доступа по SSH как `root`.

## HTTPS через SSH-туннель и SAN сертификата

Open API в пилоте был доступен через локальный TCP-туннель. Сертификат предъявлялся для условного имени `ksc.example.test`, а не для `127.0.0.1`. При подключении по IP проверка имени не пройдёт.

Для проверки без изменения DNS можно использовать `curl --resolve`:

~~~bash
curl --noproxy '*' \
  --cacert ./trusted-ksc-ca.pem \
  --resolve 'ksc.example.test:13299:127.0.0.1' \
  -o /dev/null -sS \
  -w 'HTTP=%{http_code} TLS=%{ssl_verify_result}\n' \
  'https://ksc.example.test:13299/'
~~~

Критерий TLS — `ssl_verify_result=0`. Код `401` при обращении без учётных данных не означает проблему с сертификатом.

Если SDK должен использовать DNS-имя из сертификата при локальном туннеле, на **управляющем компьютере** можно временно настроить соответствующее разрешение имени в `127.0.0.1`. Это не требует менять корпоративный DNS, но влияет на **все** локальные обращения к данному имени; при этом туннель должен быть активен.

## Почему curl проходил, а Python requests — нет

При диагностике KSC присылал **два сертификата**. Первый серверный имел тот же Subject, что и издатель, но его `Authority Key Identifier` совпадал с `Subject Key Identifier` *второго*, а не первого сертификата. Поэтому сам первый сертификат не являлся корректным доверенным корнем для Python.

Проверка только с первым сертификатом давала:

~~~text
unable to get local issuer certificate
CERTIFICATE_VERIFY_FAILED: self-signed certificate in certificate chain
~~~

Важно проверять всю цепочку:

~~~bash
openssl s_client -connect 127.0.0.1:13299 \
  -servername ksc.example.test -showcerts </dev/null
~~~

При диагностике отпечаток первого сертификата сравнили с сертификатом на самом KSC по независимому административному каналу. Только после этого разрешили доверие к издателю. Не следует делать «trust on first use» на основании одного непроверенного HTTPS-соединения.

В пилоте оказалось достаточно сохранить второй сертификат как `trusted-ksc-ca.pem` и выполнить:

~~~bash
openssl verify \
  -CAfile trusted-ksc-ca.pem \
  -verify_hostname ksc.example.test \
  ksc-leaf.pem
~~~

Результат `OK` подтвердился также через `requests` с `verify="trusted-ksc-ca.pem"`. Никакой `verify=False` или отключения проверки имени не потребовалось.

## Подключение KlAkOAPI с проверкой цепочки

Пример конфигурации (условные пути/имена; библиотека SDK приобретается и используется в соответствии с условиями Kaspersky):

~~~python
from KlAkOAPI.AdmServer import KlAkAdmServer

url = "https://ksc.example.test:13299"
ca_file = "/opt/inventory/certs/trusted-ksc-ca.pem"

server = KlAkAdmServer.Create(
    url,
    user_account,
    password,
    internal_user=False,
    verify=ca_file,
)

# После получения короткоживущего токена gateway:
agent = KlAkAdmServer.CreateGateway(url, gateway_token, ca_file)
~~~

Для `KlAkAdmServer.CreateGateway` также требуется параметр верификации сертификата. Используемые SDK-методы проверили отдельным тестом `NagRdu.GetCurrentHostState()`: соединение установлено, HTTP `200` и отсутствие `InsecureRequestWarning`.

**Важное эксплуатационное ограничение:** при штатной ротации сертификатов KSC необходимо заново подтвердить цепочку доверия клиента. Изменение сертификатов самого KSC не выполняли. Следите за датами истечения действующего и резервного сертификата.

## Inventory API: принцип локального доверия

Сервер приёма отчётов использовал HTTPS FastAPI за Nginx, доступный только через `127.0.0.1:443`. TLS выдавался корпоративным CA. Запросы защищены заголовком `X-Inventory-Key`; значение токена хранится в root-only конфигурации, доступной только локальному приёмнику.

~~~text
Python / KSC (управляющая машина)
  -> ZIP с JSON
  -> отдельный SSH-ключ
  -> inventory-ingest@inventory.example.test
  -> forced command
  -> root-owned import_ram_stdin.py
  -> HTTPS 127.0.0.1 + SNI + проверка CA
  -> FastAPI
  -> SQLite
~~~

Доступ на принимающий сервер не требует открывать внешний HTTPS-порт. Отчёт поступает по stdin через SSH; код проверяет JSON и отправляет его в локальный API.

## SSH: не root-сессия, а единственная команда

Для автоматизации создан отдельный непривилегированный пользователь `inventory-ingest`. Его публичный SSH-ключ ограничен в `authorized_keys`:

~~~text
restrict,command="/usr/bin/sudo -n /usr/local/sbin/inventory-import-ram-stdin" ssh-ed25519 AAAA... example-inventory-ingest
~~~

Это **пример**, а не готовый ключ. `restrict` блокирует форвардинг/PTY, а `command=` ограничивает действия, но полноценная защита требует также безопасных прав файлов и узкого `sudoers`:

~~~text
inventory-ingest ALL=(root) NOPASSWD: /usr/local/sbin/inventory-import-ram-stdin ""
~~~

В проверенном пилоте импортёр и его Python-модуль были `root:root 700`, конфигурация с API-токеном `root:root 600`, правило sudo `0440`. Пользователь `inventory-ingest` не мог менять импортёр или непосредственно читать конфигурацию.

С управляющей машины отправка выполнялась так:

~~~bash
ssh -T -i ~/.ssh/inventory_ingest_ed25519 \
  -o BatchMode=yes -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=yes \
  inventory-ingest@inventory.example.test \
  < ram-PC-DEMO-01.json
~~~

**Дополнительное усиление перед масштабированием:** закрепить IP-источник подключения в правилах SSH/сети, защитить private key, включить аудит импорта, проверить отсутствие возможности обхода forced command через окружение и ограничить права сервиса/токена приёма.

## Проверенный результат и следующие шаги

Один пилотный хост прошёл полный цикл без предупреждений TLS: загрузка коллектора через KSC, асинхронное выполнение на Network Agent, скачивание ZIP, JSON-проверка, SSH-доставка под `inventory-ingest`, HTTP `201 stored` и запись в SQLite.

Это **успешный пилот**, не завершённое массовое внедрение. Перед расширением необходимы очередь, ограничение параллелизма, журналирование, резервное копирование SQLite, ревизия широких разрешений KSC и контроль ротации сертификатов.

Связанные статьи: [аппаратная RAM-инвентаризация](/ru/notes/monitoring/ksc-openapi-ram-module-inventory/) и [ошибка 1184 и RBAC KSC](/ru/notes/monitoring/ksc-openapi-nagrdu-1184-rbac/).

## Публичная реализация

В [KSC Hardware Inventory v0.2.1](https://github.com/greksw/ksc-hardware-inventory) доступны [проверяемое TLS-подключение к KSC и Gateway](https://github.com/greksw/ksc-hardware-inventory/blob/main/ksc_inventory/ksc_runner.py), [валидация и SSH-импорт отчёта](https://github.com/greksw/ksc-hardware-inventory/blob/main/ksc_inventory/import_result.py), [обзор модели угроз](https://github.com/greksw/ksc-hardware-inventory/blob/main/SECURITY.md) и [протокол проверки реального пилота](https://github.com/greksw/ksc-hardware-inventory/blob/main/VALIDATION.ru.md). API-токены, закрытые ключи, доверенные сертификаты инфраструктуры и реальные результаты инвентаризации в публичный репозиторий не включены.

### Документация

- [Kaspersky Security Center 15.1](https://support.kaspersky.com/help/KSC/15.1/en-US/)
- [OpenSSH authorized_keys](https://man.openbsd.org/sshd.8)
- [Python requests: SSL certificates](https://requests.readthedocs.io/en/latest/user/advanced/#ssl-cert-verification)
