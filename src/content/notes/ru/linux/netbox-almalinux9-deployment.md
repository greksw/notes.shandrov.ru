---
title: "Развёртывание NetBox 4.7 на AlmaLinux 9: PostgreSQL, Redis, Gunicorn и Nginx"
description: "Практическое развёртывание NetBox в виртуальной машине Proxmox на AlmaLinux 9: PostgreSQL 16, Redis, Python 3.12, Gunicorn, Nginx, systemd, SELinux, firewalld и диагностика ошибок."
category: "Linux и инфраструктура"
tags: ["netbox", "almalinux", "postgresql", "redis", "gunicorn", "nginx", "selinux", "proxmox", "ipam", "dcim"]
published: 2026-10-19
updated: 2026-10-19
status: current
testedOn: ["AlmaLinux 9.8", "NetBox 4.7.1 → 4.7.3", "Python 3.12.15", "PostgreSQL 16.15", "Redis 6.2.24", "Proxmox VE"]
featured: false
lang: ru
translationKey: "linux/netbox-almalinux9-deployment"
---

## Контекст и задача

NetBox внедрялся как единый источник данных об ИТ-инфраструктуре (**Source of Truth**): площадках, устройствах, IP-адресах, VLAN, сетевых интерфейсах и виртуальных машинах. В отличие от мониторинга, NetBox описывает **как инфраструктура должна быть устроена**, а не её текущее состояние.

В основе статьи — первоначальная установка NetBox **4.7.1**, выполненная в сентябре 2026 года на отдельной виртуальной машине в Proxmox. Успешно проверены запуск web-интерфейса, фонового обработчика задач, PostgreSQL, Redis и Nginx. Реальные домены, адреса и имена серверов заменены на примеры. Приведённые команды реконструируют воспроизводимую процедуру и не являются дословным журналом терминала.

> **Обновление от 19.10.2026.** 19 октября 2026 года сервер был успешно **обновлён до NetBox 4.7.3**; разбор обновления — в [отдельной статье](/ru/notes/linux/netbox-upgrade-4-7-1-to-4-7-3/). Версии 4.7.0–4.7.1 имеют исправленную в 4.7.2 проблему: значения API-токенов, созданных через фоновые массовые запросы, могли попасть в результаты задач. Для действующих установок следует планировать обновление и замену таких токенов, если они создавались. Ниже намеренно зафиксирована первоначально развёрнутая версия; для новой установки используйте актуальный исправленный релиз и его документацию.

## 01 / Схема развёртывания

| Компонент | Конфигурация |
| --- | --- |
| Виртуализация | Proxmox VE, отдельная VM |
| Ресурсы | около 8 GiB RAM / системный диск 20 GiB (по финальной проверке) |
| Операционная система | AlmaLinux 9.8 |
| Приложение | NetBox 4.7.1 при первичной установке → 4.7.3 после обновления |
| Runtime | Python 3.12.15 (подтверждено при обновлении) |
| База данных | PostgreSQL 16.15 |
| Очереди и кеш | Redis 6.2.24 |
| WSGI | Gunicorn, `127.0.0.1:8001` |
| Reverse proxy | Nginx |
| Службы | `netbox`, `netbox-rq`, `postgresql-16`, `redis`, `nginx` |

Путь запроса:

```text
Browser → Nginx :80 / :443 → Gunicorn 127.0.0.1:8001 → NetBox
                                             ├── PostgreSQL :5432
                                             └── Redis :6379
Background jobs → netbox-rq → Redis → PostgreSQL
```

PostgreSQL и Redis размещены **локально** и не открываются во внешние подсети. TLS завершается на Nginx, а Gunicorn слушает только loopback. Настройке HTTPS через Microsoft AD CS посвящена [вторая статья](/ru/notes/security/netbox-microsoft-adcs-https/).

## 02 / Подготовка AlmaLinux

Устанавливаем обновления и необходимые пакеты:

```bash
sudo dnf update -y
sudo dnf install -y \
  git curl wget nginx redis openssl \
  python3.12 python3.12-devel python3.12-pip \
  gcc gcc-c++ make libxml2-devel libxslt-devel \
  libffi-devel openssl-devel zlib-devel \
  policycoreutils-python-utils

python3.12 --version
getenforce
```

Для PostgreSQL 16 используем официальный репозиторий PGDG (пример для EL9/x86_64):

```bash
sudo dnf install -y \
  https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm
sudo dnf -qy module disable postgresql
sudo dnf install -y postgresql16 postgresql16-server postgresql16-devel
sudo /usr/pgsql-16/bin/postgresql-16-setup initdb
sudo systemctl enable --now postgresql-16 redis nginx

/usr/pgsql-16/bin/psql --version
redis-server --version
```

Если PostgreSQL уже установлен и содержит данные, **не запускайте `initdb` повторно**. Сначала проверьте существующий кластер и план миграции.

## 03 / База данных PostgreSQL и Redis

Создаём роль и базу; пароль вводим интерактивно, без записи в историю shell:

```bash
sudo -u postgres psql
```

```sql
CREATE ROLE netbox LOGIN;
\password netbox
CREATE DATABASE netbox OWNER netbox ENCODING 'UTF8';
\connect netbox
CREATE EXTENSION IF NOT EXISTS ltree;
\dx
\q
```

Начиная с NetBox 4.7 используется расширение PostgreSQL `ltree`, поэтому база должна поддерживать его, а роль NetBox должна иметь необходимые права на создание расширений и объектов схемы. Проверяем подключение:

```bash
psql -h 127.0.0.1 -U netbox -d netbox -c 'SELECT current_database();'
redis-cli -h 127.0.0.1 ping
# Ожидается: PONG
```

Redis должен оставаться привязанным к loopback (`bind 127.0.0.1` либо эквивалентная настройка). Не публикуйте порт 6379: запись в очередь задач NetBox — чувствительная операция с точки зрения безопасности.

## 04 / Получение NetBox из Git

Для первоначальной установки использовался релиз 4.7.1; для новых установок следует выбирать актуальный исправленный релиз:

```bash
sudo git clone \
  --branch v4.7.1 --depth 1 \
  https://github.com/netbox-community/netbox.git \
  /opt/netbox

cd /opt/netbox
git describe --tags --exact-match
```

Создаём сервисного пользователя и локальный конфигурационный файл:

```bash
sudo useradd --system --home-dir /opt/netbox \
  --shell /sbin/nologin netbox

sudo cp /opt/netbox/netbox/netbox/configuration_example.py \
  /opt/netbox/netbox/netbox/configuration.py

python3.12 /opt/netbox/netbox/generate_secret_key.py
```

Сгенерируйте **ещё одно, отдельное случайное значение** для `API_TOKEN_PEPPERS`: оба секрета обязательны в конфигурации NetBox 4.7 и не должны публиковаться в Git.

В `/opt/netbox/netbox/netbox/configuration.py` задаём как минимум:

```python
ALLOWED_HOSTS = ['netbox.lab.shandrov.ru']

DATABASES = {
    'default': {
        'NAME': 'netbox',
        'USER': 'netbox',
        'PASSWORD': 'REPLACE_WITH_DB_PASSWORD',
        'HOST': '127.0.0.1',
        'PORT': '5432',
        'CONN_MAX_AGE': 300,
    }
}

REDIS = {
    'tasks': {
        'HOST': '127.0.0.1', 'PORT': 6379,
        'PASSWORD': '', 'DATABASE': 0, 'SSL': False,
    },
    'caching': {
        'HOST': '127.0.0.1', 'PORT': 6379,
        'PASSWORD': '', 'DATABASE': 1, 'SSL': False,
    },
}

SECRET_KEY = 'REPLACE_WITH_INDEPENDENT_RANDOM_SECRET'
API_TOKEN_PEPPERS = {
    1: 'REPLACE_WITH_INDEPENDENT_RANDOM_PEPPER',
}
```

Не используйте `ALLOWED_HOSTS = ['*']` в постоянной конфигурации. Имя `netbox.lab.shandrov.ru` в этой статье **пример**, не адрес развёрнутого корпоративного сервиса.

Выставляем права на конфигурацию и каталоги пользовательских данных:

```bash
sudo chown root:netbox /opt/netbox/netbox/netbox/configuration.py
sudo chmod 640 /opt/netbox/netbox/netbox/configuration.py
sudo chown -R netbox:netbox \
  /opt/netbox/netbox/media \
  /opt/netbox/netbox/reports \
  /opt/netbox/netbox/scripts
```

## 05 / Python environment, миграции и администратор

Штатный `upgrade.sh` создаёт `venv`, устанавливает зависимости, применяет миграции и собирает статические файлы:

```bash
sudo PYTHON=/usr/bin/python3.12 /opt/netbox/upgrade.sh

cd /opt/netbox/netbox
sudo -u netbox /opt/netbox/venv/bin/python manage.py check
sudo -u netbox /opt/netbox/venv/bin/python manage.py showmigrations | tail -n 20
```

Создаём первого администратора интерактивно:

```bash
cd /opt/netbox/netbox
sudo -u netbox /opt/netbox/venv/bin/python manage.py createsuperuser
```

Команда `manage.py --version` выводит **версию Django**, а не релиз NetBox. Для NetBox, установленного из Git, релиз проверяется так:

```bash
cd /opt/netbox
git describe --tags --exact-match
```

В нашей установке Django был 6.1.1, а тег приложения — `v4.7.1`.

## 06 / Gunicorn и systemd

Сохраняем локальную конфигурацию Gunicorn отдельно от `contrib`:

```bash
sudo cp /opt/netbox/contrib/gunicorn.py /opt/netbox/gunicorn.py
sudoedit /opt/netbox/gunicorn.py
```

В конфигурации проверяем строку:

```python
bind = '127.0.0.1:8001'
```

Используем штатные unit-файлы NetBox:

```bash
sudo cp /opt/netbox/contrib/netbox.service \
  /opt/netbox/contrib/netbox-rq.service \
  /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now netbox netbox-rq

systemctl is-active netbox netbox-rq
ss -lntp | grep ':8001'
```

`netbox-rq` отвечает за фоновые задания; наличие только работающего web-интерфейса ещё не означает полноценную работоспособность NetBox.

## 07 / Nginx, SELinux и firewalld

Создаём `/etc/nginx/conf.d/netbox.conf`. На этом этапе для первого запуска используем HTTP **только внутри доверенной сети**, затем переходим на HTTPS:

```nginx
server {
    listen 80;
    server_name netbox.lab.shandrov.ru;

    client_max_body_size 20m;

    location /static/ {
        alias /opt/netbox/netbox/static/;
    }

    location / {
        proxy_pass http://127.0.0.1:8001;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Для работы обратного прокси при включённом SELinux:

```bash
sudo setsebool -P httpd_can_network_connect 1
sudo semanage fcontext -a -t httpd_sys_content_t \
  '/opt/netbox/netbox/static(/.*)?'
sudo restorecon -Rv /opt/netbox/netbox/static
sudo nginx -t
sudo systemctl reload nginx
```

Команда `semanage fcontext -a` применяется при **первом** добавлении правила. Если правило уже существует, просмотрите `semanage fcontext -l` и используйте `-m` для изменения.

Порт HTTP на сервере разрешаем только с административной подсети; замените демонстрационный CIDR на свой:

```bash
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="10.20.30.0/24" service name="http" accept'
sudo firewall-cmd --reload
sudo firewall-cmd --list-all
```

Не добавляйте общий `--add-service=http`, если доступ должен быть ограничен сетями администраторов. После перехода на TLS аналогично разрешается `https`, а правило `http` может оставаться исключительно для контролируемого перенаправления.

## 08 / Реальные сложности: права после `umask 077`

В ходе настройки обнаружилась проблема с доступом к статическим ресурсам после операций, выполненных с ограничительным `umask 077`. Симптом: сам NetBox отвечает, а стили или JavaScript возвращают `403`.

Диагностика:

```bash
namei -l /opt/netbox/netbox/static
sudo nginx -t
sudo journalctl -u nginx -n 80 --no-pager
sudo ausearch -m AVC -ts recent
```

Права проверяем **по всей цепочке директорий**; веб-серверу нужен доступ на проход к публичной статике. Корректируем только публичный каталог, **не** ослабляя права на `configuration.py` и приватные ключи:

```bash
sudo find /opt/netbox/netbox/static -type d -exec chmod 755 {} +
sudo find /opt/netbox/netbox/static -type f -exec chmod 644 {} +
sudo restorecon -Rv /opt/netbox/netbox/static
```

Если система не выдаёт AVC, не следует отключать SELinux ради диагностики. Также не нужно выполнять `chmod -R 777 /opt/netbox`.

## 09 / Финальные проверки

```bash
systemctl is-active postgresql-16 redis netbox netbox-rq nginx
redis-cli ping
cd /opt/netbox && git describe --tags --exact-match
sudo -u netbox /opt/netbox/venv/bin/python \
  /opt/netbox/netbox/manage.py check
ss -lntp | grep -E ':(80|8001|5432|6379)\b'
curl -I -H 'Host: netbox.lab.shandrov.ru' http://127.0.0.1/
```

Ожидаем активные сервисы, `PONG`, отсутствие ошибок `manage.py check`, ответ Nginx без `502` и успешную загрузку интерфейса.

### Что ещё проверить перед промышленной эксплуатацией

- Регулярный `pg_dump` с **проверкой восстановления** и сохранением `media`, `configuration.py` и неизменных секретов; снапшот VM сам по себе не заменяет проверяемый backup.
- Мониторинг `netbox`, `netbox-rq`, PostgreSQL, Redis, Nginx, диска и срока действия TLS-сертификата.
- Права пользователей, ограничение административных подсетей, подключение к корпоративной идентификации — отдельным этапом.
- Обновление **с 4.7.1 до 4.7.3** выполнено 19 октября 2026 года; [журнал и воспроизводимая процедура](/ru/notes/linux/netbox-upgrade-4-7-1-to-4-7-3/).

## Результат

NetBox запущен на AlmaLinux под systemd, хранит данные в PostgreSQL, использует Redis для кеширования и фоновых задач и обслуживается через Nginx. Продолжение цикла — [выпуск и установка HTTPS-сертификата от Microsoft AD CS](/ru/notes/security/netbox-microsoft-adcs-https/) и [обновление NetBox до 4.7.3](/ru/notes/linux/netbox-upgrade-4-7-1-to-4-7-3/).

## Источники

- [NetBox — установка и требования](https://netbox.readthedocs.io/en/stable/installation/)
- [NetBox — Release Archive or Git](https://netbox.readthedocs.io/en/stable/installation/3-netbox/)
- [NetBox — Gunicorn](https://netbox.readthedocs.io/en/stable/installation/4a-gunicorn/)
- [NetBox — HTTP Server и SELinux](https://netbox.readthedocs.io/en/stable/installation/5-http-server/)
- [NetBox 4.7 — Release Notes](https://netbox.readthedocs.io/en/stable/release-notes/version-4.7/)