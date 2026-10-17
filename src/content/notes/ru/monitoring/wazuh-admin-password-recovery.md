---
title: "Wazuh 4.14: сброс пароля admin, ошибка 429 и восстановление Indexer"
description: "Практический runbook на Wazuh 4.14.9: диагностика The backup could not be created, JVM circuit breaker, проблемы прав на backup и безопасная смена пароля admin."
category: "Мониторинг и безопасность"
tags: ["wazuh", "opensearch", "wazuh-indexer", "almalinux", "security", "jvm", "troubleshooting", "runbook"]
published: 2026-10-17
updated: 2026-10-17
status: current
testedOn: ["Wazuh 4.14.9", "OpenSearch 2.19.6", "AlmaLinux 9", "All-in-one deployment"]
featured: false
lang: ru
translationKey: "monitoring/wazuh-admin-password-recovery"
---

## Контекст

При входе в Wazuh Dashboard появилось сообщение **Invalid username or password**. Повторная вставка сохранённого пароля не помогла. Первая попытка восстановить доступ штатной утилитой Wazuh закончилась не сменой пароля, а ошибкой резервного копирования:

~~~text
INFO: Updating the internal users.
ERROR: The backup could not be created
~~~

За этим сообщением скрывались две независимые проблемы: почти полностью заполненный **JVM Heap** Wazuh Indexer и недоступный для процесса OpenSearch каталог временной резервной копии. В результате пришлось восстанавливать Indexer, а уже затем менять пароль.

Ниже — проверенный порядок диагностики и восстановления для **Wazuh 4.14.9 / OpenSearch 2.19.6 / AlmaLinux 9**, установленного по схеме **all-in-one**: Manager, Indexer, Dashboard и Filebeat на одном хосте. В распределённой конфигурации обновление служебных учётных данных требует дополнительных действий на других узлах.

Все сетевые адреса и имена узлов в статье заменены универсальными примерами. Никакие пароли, приватные ключи и реальные конфигурации внутренних пользователей не публикуются.

## 01 / Уточняем, какую учётную запись восстанавливаем

Пользователь \`admin\`, применяемый для входа в Dashboard, — внутренний пользователь **Wazuh Indexer / OpenSearch Security**. Это не системный Linux-пользователь \`root\`. Учётные записи \`wazuh\` и \`wazuh-wui\` относятся к Wazuh Server API и обслуживаются отдельно.

Для восстановления **только** \`admin\` используется утилита \`wazuh-passwords-tool.sh -u admin\`. Не применяйте \`--change-all\`, когда изменение остальных служебных паролей не планировалось.

## 02 / Снимаем исходное состояние, ничего не меняя

Работаем от \`root\`:

~~~bash
rpm -q wazuh-manager wazuh-indexer wazuh-dashboard

systemctl is-active \
  wazuh-manager wazuh-indexer wazuh-dashboard filebeat

free -h
swapon --show
df -h /etc/wazuh-indexer
df -i /etc/wazuh-indexer

grep -nE '^[[:space:]]*-Xm[sx]' \
  /etc/wazuh-indexer/jvm.options

curl -ksS --connect-timeout 5 -o /dev/null \
  -w 'HTTP %{http_code}\n' \
  https://127.0.0.1:9200/
~~~

При локальной установке Indexer может слушать только loopback:

~~~bash
grep -n '^network.host:' /etc/wazuh-indexer/opensearch.yml
ss -lntp | grep ':9200'
~~~

При проверке HTTPS API *без* учётных данных:

| HTTP | Интерпретация |
|---|---|
| \`401\` | API отвечает и требует аутентификацию; правильность пароля пока не проверена |
| \`429\` | Запрос отклонён; возможна защита Circuit Breaker |
| \`503\` | Indexer или его компоненты пока не готовы |
| \`000\` | Нет корректного HTTP-ответа; смотрим curl и логи |

Сразу после старта OpenSearch может ненадолго возвращать \`503\`: это не повод для серии поспешных перезапусков.

## 03 / Почему утилита не смогла создать backup

Скрипт смены пароля перед обновлением пользователя выгружает конфигурацию OpenSearch Security через \`securityadmin.sh\`. Общее сообщение \`The backup could not be created\` не сообщает, **почему** операция не удалась.

Чтобы увидеть первопричину, отдельно запускаем **только выгрузку** security-конфигурации в закрытый каталог *за пределами* \`/etc/wazuh-indexer\`:

~~~bash
BACKUP_DIR=$(mktemp -d /root/wazuh-security-backup.XXXXXX)

JAVA_HOME=/usr/share/wazuh-indexer/jdk \
OPENSEARCH_CONF_DIR=/etc/wazuh-indexer \
/usr/share/wazuh-indexer/plugins/opensearch-security/tools/securityadmin.sh \
  -backup "$BACKUP_DIR" \
  -icl -p 9200 -nhnv \
  -cacert /etc/wazuh-indexer/certs/root-ca.pem \
  -cert /etc/wazuh-indexer/certs/admin.pem \
  -key /etc/wazuh-indexer/certs/admin-key.pem \
  -h 127.0.0.1

RC=$?
echo "SECURITYADMIN EXIT CODE: $RC"
test "$RC" -eq 0 && test -s "$BACKUP_DIR/internal_users.yml" \
  && echo "SECURITY BACKUP: OK"
~~~

Адрес \`127.0.0.1\` подходит только там, где Indexer действительно слушает локальный интерфейс. Пути сертификатов также сверяем с собственной установкой. Содержимое \`internal_users.yml\` и резервных копий Security Plugin необходимо защищать от постороннего доступа.

В этом инциденте команда завершилась кодом \`255\` с диагностикой:

~~~text
HTTP/1.1 429 Too Many Requests
circuit_breaking_exception
[parent] Data too large
memory required: 976.6 MiB
memory limit:    972.7 MiB
~~~

Это не ошибка чтения пароля и не проблема свободного места на диске: Indexer отклонял запрос \`/_plugins/_security/whoami\` из-за нехватки памяти JVM.

## 04 / Диагностика и настройка JVM Heap

Файл \`/etc/wazuh-indexer/jvm.options\` содержал:

~~~text
-Xms1024m
-Xmx1024m
~~~

Лог \`/var/log/wazuh-indexer/wazuh-cluster.log\` повторял:

~~~text
attempting to trigger G1GC due to high heap usage
GC did not bring memory usage down
~~~

После GC в памяти оставалось примерно 965–985 MiB из выделенных 1024 MiB. Этого оказалось недостаточно для нормальной работы Indexer.

На конкретной all-in-one VM было около **11 GiB RAM** и достаточно доступной памяти ОС. Поэтому Heap увеличили до **2 GiB**, сохранив резерв для Manager, Dashboard, Filebeat и системы. Это значение **не универсально**: при других объёмах RAM и нагрузке его надо подбирать отдельно.

Перед изменением:

~~~bash
cp -a /etc/wazuh-indexer/jvm.options \
  "/etc/wazuh-indexer/jvm.options.bak.$(date +%Y%m%d-%H%M%S)"
~~~

Для первоначальной конфигурации именно с \`1024m\`:

~~~bash
sed -i \
  -e 's/^-Xms1024m$/-Xms2048m/' \
  -e 's/^-Xmx1024m$/-Xmx2048m/' \
  /etc/wazuh-indexer/jvm.options

grep -nE '^[[:space:]]*-Xm[sx]' \
  /etc/wazuh-indexer/jvm.options
~~~

Ожидаем:

~~~text
-Xms2048m
-Xmx2048m
~~~

Начальное и максимальное значения Heap должны совпадать. Перезапуск Indexer выполняем в окно обслуживания: поиск по событиям и Dashboard могут быть временно недоступны.

~~~bash
systemctl restart wazuh-indexer
systemctl status wazuh-indexer --no-pager -l
~~~

## 05 / Отдельная ловушка: AccessDeniedException из-за каталога backup

При первом перезапуске после настройки Heap Wazuh Indexer не поднялся. В \`journalctl\` оказалась важная строка:

~~~text
org.opensearch.bootstrap.BootstrapException:
java.nio.file.AccessDeniedException: /etc/wazuh-indexer/backup
~~~

В конфигурационном дереве осталась резервная копия с владельцем \`root:root\`. Сначала её каталог имел права \`0600\` (для каталога отсутствует \`x\`); даже после изменения на \`0700\` он был недоступен сервисному пользователю \`wazuh-indexer\`. OpenSearch обходит каталог конфигурации при запуске и аварийно завершается, встретив недоступный путь.

**Не следует выполнять \`chmod -R 777\` или без разбора менять владельца всего \`/etc/wazuh-indexer\`.** В этом сценарии правильнее сохранить временный backup вне конфигурационного дерева:

~~~bash
install -d -m 700 /root/wazuh-indexer-backups

if [ -d /etc/wazuh-indexer/backup ]; then
  mv -v /etc/wazuh-indexer/backup \
    "/root/wazuh-indexer-backups/backup-$(date +%Y%m%d-%H%M%S)"
fi

systemctl reset-failed wazuh-indexer
systemctl start wazuh-indexer
~~~

Если запуск не удался, смотрим первичную ошибку:

~~~bash
journalctl -u wazuh-indexer -n 100 --no-pager -l
tail -n 100 /var/log/wazuh-indexer/wazuh-cluster.log
~~~

После переноса каталога сервис успешно стартовал. Повторный запуск с Heap 2 GiB также завершился успешно. Таким образом, ошибка загрузки была связана **с правами резервной копии**, а не с новым размером Heap.

## 06 / Проверяем Indexer до смены пароля

~~~bash
systemctl is-active \
  wazuh-manager wazuh-indexer wazuh-dashboard filebeat

curl -ksS --connect-timeout 5 -o /dev/null \
  -w 'HTTP %{http_code}\n' \
  https://127.0.0.1:9200/

grep -nE '^[[:space:]]*-Xm[sx]' \
  /etc/wazuh-indexer/jvm.options
~~~

После устранения проблем резервная копия OpenSearch Security выгрузилась успешно:

~~~text
Connected as "CN=admin,OU=Wazuh,O=Wazuh,L=California,C=US"
OpenSearch Version: 2.19.6
Clusterstate: GREEN
SUCC: Configuration for 'internalusers' stored ...
SECURITYADMIN EXIT CODE: 0
SECURITY BACKUP: OK
~~~

Здесь \`CN=admin\` — имя субъекта сертификата, а не проверка пользовательского пароля для входа в Dashboard.

## 07 / Штатный сброс пароля admin

После подтверждённого backup:

~~~bash
bash /usr/share/wazuh-indexer/plugins/opensearch-security/tools/wazuh-passwords-tool.sh \
  -u admin
~~~

В описанном случае утилита вывела:

~~~text
INFO: Updating the internal users.
INFO: A backup of the internal users has been saved ...
INFO: The filebeat.yml file has been updated to use the Filebeat Keystore username and password.
WARNING: Password changed. Remember to update the password in the Wazuh dashboard, Wazuh server, and Filebeat nodes if necessary, and restart the services.
~~~

**Пароль надо сохранить в защищённом хранилище.** Не публикуйте ни его, ни приватные ключи, ни \`internal_users.yml\`. Не передавайте пароль как аргумент \`-p\` в командной строке без понимания риска раскрытия через историю shell и список процессов. При работе с конкретной версией утилиты сверьте её поддерживаемые параметры.

После успешного сброса снова проверяем каталог \`/etc/wazuh-indexer/backup\`: скрипт может создавать его при операции. Если каталог остался с правами, препятствующими будущему запуску Indexer, сохраняем его вне дерева конфигурации, как показано выше. Каталог \`/etc/wazuh-indexer/internalusers-backup\` без необходимости не трогаем.

## 08 / Контроль результата

Проверяем пользовательскую аутентификацию отдельно от проверки HTTPS API. Команда \`curl -u admin\` попросит новый пароль интерактивно:

~~~bash
curl -ksS -u admin \
  'https://127.0.0.1:9200/_plugins/_security/authinfo?pretty'

curl -ksS -u admin \
  'https://127.0.0.1:9200/_cluster/health?pretty'
~~~

Далее выполняем вход через Wazuh Dashboard с новым паролем. Успешное сообщение утилиты **ещё не равно** проверенной авторизации; в рассматриваемом инциденте вход в веб-панель был подтверждён отдельно.

Контролируем связанные компоненты:

~~~bash
systemctl is-active \
  wazuh-manager wazuh-indexer wazuh-dashboard filebeat

filebeat test output -c /etc/filebeat/filebeat.yml
journalctl -u filebeat -n 60 --no-pager
~~~

Если после смены credentials доставка событий нарушена, сверяем Filebeat Keystore и действующую конфигурацию, затем перезапускаем именно затронутую службу. В распределённой установке проверяем и обновляем credentials каждого узла в соответствии с официальной процедурой.

## 09 / Итоговый чек-лист

- [ ] Все компоненты Wazuh активны, Indexer отвечает на HTTPS.
- [ ] Heap подобран по ресурсам и нагрузке; нет постоянных отказов \`429\`.
- [ ] Backup OpenSearch Security создан, проверен и хранится в защищённом каталоге.
- [ ] В конфигурационном дереве нет недоступного Indexer каталога временного backup.
- [ ] Пароль \`admin\` изменён и сохранён в менеджере секретов.
- [ ] Вход в Dashboard с новым паролем успешно проверен.
- [ ] Filebeat передаёт события и Manager принимает агентов.
- [ ] В публичных логах и статье нет секретов или внутренних идентификаторов.

## Вывод

Сообщение \`The backup could not be created\` само по себе не объясняет отказ смены пароля. В нашем инциденте причиной стал **\`429 circuit_breaking_exception\`**, вызванный почти полностью занятым JVM Heap. Отдельно проявилась **\`AccessDeniedException\`** при запуске Indexer из-за прав на временный backup.

Рабочая последовательность восстановления: **диагностика → стабилизация Indexer → безопасный backup Security Plugin → сброс только \`admin\` → проверка авторизации и доставки событий**.

### Источники

- [Wazuh: Password management](https://documentation.wazuh.com/current/user-manual/user-administration/password-management.html)
- [Wazuh: Wazuh indexer tuning](https://documentation.wazuh.com/current/user-manual/wazuh-indexer/wazuh-indexer-tuning.html)
- [Wazuh: Remote upgrading of agents](https://documentation.wazuh.com/current/user-manual/agent/agent-management/remote-upgrading/upgrading-agent.html)
