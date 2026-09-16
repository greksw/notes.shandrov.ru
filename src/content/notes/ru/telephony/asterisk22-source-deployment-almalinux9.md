---
title: "Развёртывание Asterisk 22 из исходников на AlmaLinux 9 с проверкой загрузок и контролируемым запуском"
description: "Воспроизводимая схема сборки Asterisk 22 из исходников на AlmaLinux 9: фиксированная версия и SHA-256, bundled pjproject, отдельная системная учётная запись и явный запуск через systemd."
category: "Телефония и VoIP"
tags: ["asterisk", "voip", "almalinux", "pjsip", "systemd", "security"]
published: 2026-09-16
updated: 2026-09-16
status: lab
testedOn: []
featured: true
lang: ru
translationKey: "telephony/asterisk22-source-deployment-almalinux9"
---

## Контекст

Asterisk сравнительно легко собрать из исходников — и так же легко развернуть небезопасно.

Типичные проблемные упрощения:

- скачивать архив без проверки целостности;
- запускать upstream helper scripts до проверки исходников;
- устанавливать sample-конфигурацию поверх существующей АТС;
- запускать сервис сразу после `make install`;
- смешивать установку ПО с настройкой SIP trunk, dialplan и firewall;
- считать успешную сборку доказательством готовности PBX к production.

В этой заметке используется более узкая модель: установить фиксированную версию Asterisk 22 из исходников на AlmaLinux 9, проверить SHA-256 до распаковки, создать отдельную сервисную учётную запись, установить systemd unit и оставить запуск сервиса под явным контролем администратора.

Практическая реализация находится в публичном репозитории:

<https://github.com/greksw/asterisk-deployment>

Сейчас репозиторий закреплён на Asterisk `22.11.0` LTS. Реальная production-миграция с Asterisk 13 на 22 — отдельная задача и в этой статье не выдаётся за уже выполненную.

## Область статьи

Здесь рассматривается именно software layer:

```text
AlmaLinux 9
  -> build dependencies
  -> проверенный архив Asterisk
  -> bundled pjproject
  -> make / make install
  -> отдельная учётная запись asterisk
  -> systemd unit
  -> явное включение/запуск сервиса
```

Автоматически не настраиваются:

- SIP/PJSIP trunks;
- extensions;
- dialplan;
- RTP/firewall/NAT;
- TLS/SRTP;
- AMI/ARI;
- CDR;
- Fail2Ban;
- мониторинг;
- backup policy;
- миграция со старого Asterisk.

Разделение этих слоёв упрощает troubleshooting и rollback.

## Почему Asterisk 22

Asterisk 22 — LTS-ветка. На сентябрь 2026 года проект Asterisk указывает для 22.x полную поддержку до октября 2028 года и security fixes до октября 2029 года.

Asterisk 13 завершил жизненный цикл ещё в октябре 2021 года. Поэтому переход 13 -> 22 — это не обычный minor upgrade, а полноценная платформенная миграция.

За промежуточные версии изменились конфигурационные форматы и состав модулей, поэтому старую конфигурацию нельзя безоговорочно переносить как есть.

## Версия и checksum должны фиксироваться вместе

Deployment helper хранит версию и ожидаемый SHA-256 рядом:

```bash
DEFAULT_ASTERISK_VERSION='22.11.0'
DEFAULT_ASTERISK_SHA256='3bd5ee040509a3d3cd9b1ba9520c18e6ec0a7e7981ca68c457dcd36ba3c54d94'
```

Если переопределяется версия, требуется указать и соответствующий digest.

То есть команда вида:

```bash
./auto_install_asterisk.sh --version 22.x.y
```

не должна молча скачать другой архив при старом доверенном checksum.

Версию и SHA-256 нужно менять и проверять вместе.

## Предварительный просмотр без изменений системы

Скрипт умеет показать план развёртывания:

```bash
./auto_install_asterisk.sh --print-plan
```

План включает:

```text
version
sha256
source URL
source workspace
число parallel build jobs
install samples yes/no
upstream prereqs yes/no
enable service yes/no
start service yes/no
```

Это удобно для change review до запуска от root.

## Явная проверка ОС

Скрипт намеренно ограничен AlmaLinux 9:

```bash
source /etc/os-release

[[ ${ID:-} == 'almalinux' ]]
[[ ${VERSION_ID%%.*} == '9' ]]
```

Это лучше, чем притворяться, что source-build одинаково работает на любом дистрибутиве: отличаются имена пакетов, trust store, SELinux и systemd-интеграция.

## Явный список build dependencies

По умолчанию устанавливается контролируемый набор build packages через DNF, а не запускается upstream prerequisite helper.

В базовый набор входят, например:

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

Список должен оставаться привязанным к целевой ОС и версии Asterisk.

## Скачивание только по HTTPS

Исходники загружаются с официального сайта Asterisk:

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

Важные свойства:

- plain HTTP запрещён;
- HTTP error приводит к отказу;
- redirects разрешены;
- неполная загрузка пишется во временный файл;
- TLS сам по себе не заменяет проверку digest.

## SHA-256 проверяется до распаковки

До любых действий с source tree выполняется:

```bash
printf '%s  %s\n' \
  "$ASTERISK_SHA256" \
  "${TARBALL}.tmp" |
sha256sum --check --status
```

Только после успешной проверки временный файл становится финальным tarball.

Правильный trust order:

```text
download -> verify -> extract -> execute/build
```

а не:

```text
download -> execute helper -> build
```

## Source workspace сохраняется

По умолчанию используется:

```text
/usr/local/src/asterisk-deployment
```

После успешной установки архив и исходники остаются на сервере.

Это полезно для:

- troubleshooting;
- подтверждения, что именно было собрано;
- анализа build state;
- сравнения с будущей версией.

Повторный запуск не использует уже существующий build directory — это снижает риск случайной инкрементальной сборки из старого состояния.

## Bundled pjproject

Конфигурация сборки:

```bash
./configure --with-pjproject-bundled
```

Для Asterisk 22 это позволяет использовать pjproject, согласованный с этой веткой Asterisk, а не случайную системную версию.

Далее:

```bash
make -j"$BUILD_JOBS"
make install
make install-logrotate
ldconfig
```

Количество parallel jobs можно ограничить параметром `--jobs`.

## Sample-конфигурация — только для свежего lab host

`make samples` не выполняется по умолчанию.

При `--install-samples` скрипт сначала проверяет `/etc/asterisk`. Если там уже есть `*.conf`, выполнение прекращается.

Это особенно важно при миграции: существующая production-конфигурация — исходный материал для анализа и преобразования, а не то, что нужно заменить upstream samples.

## Отдельная системная учётная запись

Asterisk запускается не от root, а от отдельной service account.

Подготавливаются основные каталоги:

```text
/etc/asterisk
/run/asterisk
/var/lib/asterisk
/var/log/asterisk
/var/spool/asterisk
```

Типовая модель ownership:

```text
asterisk:asterisk -> runtime/data/log/spool
root:asterisk     -> configuration
```

Это позволяет держать конфигурацию root-owned, оставляя сервису только необходимый read access.

## Controlled systemd unit

Unit использует фактический путь к установленному бинарнику.

Ключевые параметры:

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

До запуска:

```bash
systemd-analyze verify /etc/systemd/system/asterisk.service
```

Успешная проверка unit не доказывает валидность PBX-конфигурации.

## Установка и запуск разделены

Обычный deployment:

```bash
sudo ./auto_install_asterisk.sh --jobs 4
```

Asterisk устанавливается, но не стартует автоматически.

Получается явная точка контроля:

```text
software installed
  -> проверить version/binary
  -> проверить /etc/asterisk
  -> проверить network/security
  -> только затем enable/start
```

Явное enable:

```bash
sudo ./auto_install_asterisk.sh \
  --enable-service
```

Lab-вариант с samples:

```bash
sudo ./auto_install_asterisk.sh \
  --install-samples \
  --start
```

`--start` также включает сервис в autostart.

## Проверка установленной версии

После установки:

```bash
command -v asterisk
asterisk -V
```

После запуска:

```bash
systemctl status asterisk --no-pager
asterisk -rx 'core show version'
```

Для реальной АТС дополнительно нужно проверить:

```text
PJSIP transports
registrations
provider trunks
RTP path
inbound calls
outbound calls
DTMF
caller ID
queues/IVR
voicemail, если используется
CDR/CEL, если используется
monitoring и log rotation
```

## Upstream prerequisite helper запускается только явно

В Asterisk есть `contrib/scripts/install_prereq`.

Он удобен, но может изменить package set шире, чем явный dependency list deployment script.

Поэтому по умолчанию он выключен.

При необходимости:

```bash
sudo ./auto_install_asterisk.sh --upstream-prereqs
```

Он запускается только после успешной SHA-256 проверки исходников.

## Security boundary до production

Установка Asterisk не означает, что SIP-сервис уже безопасно опубликован.

Перед production activation нужно отдельно проверить:

- PJSIP authentication;
- ACL для endpoints/providers;
- SIP exposure;
- RTP range и firewall;
- NAT;
- TLS/SRTP;
- AMI/ARI bindings и credentials;
- dialplan authorization;
- toll-fraud controls;
- Fail2Ban или аналогичный механизм, если он нужен;
- logging/retention;
- monitoring;
- backup/restore конфигурации;
- SELinux;
- upgrade/rollback procedure.

Не нужно открывать SIP/RTP шире необходимого только потому, что daemon успешно запущен.

## Граница будущей миграции: Asterisk 13 -> 22

Production-миграцию Asterisk 13 -> 22 нужно оформлять отдельным runbook.

Один из ключевых compatibility checks — SIP channel driver. `chan_sip` был deprecated в Asterisk 17 и удалён в Asterisk 21. Если текущий Asterisk 13 использует `sip.conf` / `chan_sip`, то для Asterisk 22 потребуется переход на `res_pjsip` / `chan_pjsip`, а не простое копирование конфигурации.

Asterisk предоставляет `contrib/scripts/sip_to_pjsip/sip_to_pjsip.py`, но официальная документация прямо рассматривает его как отправную точку, а не как полностью автоматический конвертер любой конфигурации.

Нужно также проверить удалённые модули. Например, `app_macro` и `res_monitor` были удалены в Asterisk 21.

Поэтому миграцию нужно начинать с inventory конфигурации и модулей, а не с копирования `/etc/asterisk` на новый сервер.

## Что собрать со старого Asterisk 13

Перед написанием migration runbook стоит снять минимум:

```bash
asterisk -rx 'core show version'
asterisk -rx 'module show'
asterisk -rx 'sip show settings' 2>/dev/null || true
asterisk -rx 'pjsip show settings' 2>/dev/null || true
asterisk -rx 'dialplan show'
```

И список active config files:

```bash
find /etc/asterisk -maxdepth 1 -type f -name '*.conf' -printf '%f\n' | sort
```

Перед публикацией обязательно санитизировать:

- SIP passwords;
- provider credentials;
- sensitive public IP;
- номера телефонов;
- AMI/ARI credentials;
- внутренние имена, которые не должны быть публичными.

После реальной миграции сильнее будет отдельная статья **Asterisk 13 -> 22 migration runbook** с найденными incompatibilities, тест-планом, cutover и rollback.

## Rollback model

Новый Asterisk 22 нужно готовить параллельно, не разрушая рабочий Asterisk 13.

Безопаснее схема:

```text
build new PBX in parallel
  -> переносить конфигурацию осознанно
  -> тестировать endpoints/trunks
  -> тестировать call flows
  -> определить cutover
  -> сохранить старую PBX для rollback
  -> переключить трафик
  -> выполнить validation
  -> выводить старую PBX только после acceptance
```

Механизм cutover зависит от SIP providers, DNS, IP, NAT и provisioning телефонов.

## Ссылки

- Deployment helper: <https://github.com/greksw/asterisk-deployment>
- Asterisk release lifecycle: <https://docs.asterisk.org/About-the-Project/Asterisk-Versions/>
- Asterisk 22 documentation: <https://docs.asterisk.org/Asterisk_22_Documentation/>
- PJSIP configuration: <https://docs.asterisk.org/Configuration/Channel-Drivers/SIP/Configuring-res_pjsip/>
- Migration from chan_sip to res_pjsip: <https://docs.asterisk.org/Configuration/Channel-Drivers/SIP/Configuring-res_pjsip/Migrating-from-chan_sip-to-res_pjsip/>
- Module deprecations/removals: <https://docs.asterisk.org/Development/Asterisk-Module-Deprecations/>
