---
title: "Оповещения о входе по SSH через XMPP с sendxmpp и проверкой TLS"
description: "Практическая схема отправки уведомлений о входе по SSH на собственный XMPP-сервер без Telegram, встроенных в скрипт паролей и отключения проверки TLS."
category: "Мониторинг и безопасность"
tags: ["ssh", "xmpp", "jabber", "sendxmpp", "security", "linux"]
published: 2026-09-16
updated: 2026-09-16
status: current
testedOn: ["sendxmpp", "OpenSSH", "Linux"]
featured: true
lang: ru
translationKey: "security/ssh-login-alerting-via-xmpp-sendxmpp"
---

## Контекст

Оповещение о входе по SSH полезно как дополнительный сигнал для администратора, но сам механизм уведомления не должен создавать новую проблему с хранением секретов или задерживать вход, если внешний сервис недоступен.

Практичный вариант — выделенная XMPP-учётная запись для уведомлений и отправка через `sendxmpp` по TLS. Учётные данные хранятся в отдельном root-only файле, а JID получателя задаётся отдельно.

Такой подход позволяет отказаться от Telegram Bot API и оставить канал оповещения внутри собственного XMPP-сервиса.

## Схема

```text
событие входа по SSH
  -> скрипт уведомления
  -> sendxmpp
  -> XMPP-сервер
  -> JID администратора
```

Разделяйте:

- учётные данные XMPP;
- JID получателя;
- путь к доверенному CA;
- формирование текста сообщения;
- механизм запуска скрипта после входа по SSH.

## Учётная запись sendxmpp

Создайте отдельный конфигурационный файл, например:

```text
/root/.sendxmpprc-ssh-alert
```

Пример содержимого:

```text
username: ssh-alert
jserver: jabber.example.net
port: 5222
password: replace-with-real-password
```

Ограничьте доступ:

```bash
chown root:root /root/.sendxmpprc-ssh-alert
chmod 600 /root/.sendxmpprc-ssh-alert
```

Реальный пароль не должен находиться в самом скрипте, репозитории, shell history или документации.

## Сначала проверьте отправку вручную

```bash
printf 'test ssh alert\n' | \
sendxmpp \
  -f /root/.sendxmpprc-ssh-alert \
  -r ssh-alert \
  --tls \
  --tls-ca-path /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem \
  admin@example.net \
  -v
```

Путь к CA bundle зависит от дистрибутива. Не отключайте проверку сертификата только ради того, чтобы команда начала работать.

## Скрипт уведомления

Несекретные параметры удобно вынести в начало файла:

```bash
#!/usr/bin/env bash
set -u

XMPP_CONFIG="/root/.sendxmpprc-ssh-alert"
XMPP_TO="admin@example.net"
XMPP_FROM_RESOURCE="ssh-alert"
XMPP_TLS_CA_PATH="/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem"

HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
IP_ADDRESS_SERVER="$(hostname -I 2>/dev/null | awk '{print $1}')"
CURRENT_USER="${PAM_USER:-${USER:-unknown}}"
IP_ADDRESS_CLIENT="${PAM_RHOST:-}"

if [[ -z "$IP_ADDRESS_CLIENT" && -n "${SSH_CLIENT:-}" ]]; then
  IP_ADDRESS_CLIENT="${SSH_CLIENT%% *}"
fi

[[ -n "$IP_ADDRESS_CLIENT" ]] || IP_ADDRESS_CLIENT="unknown"
[[ -n "$IP_ADDRESS_SERVER" ]] || IP_ADDRESS_SERVER="unknown"

MESSAGE="SSH login detected on server: ${HOSTNAME} (IP: ${IP_ADDRESS_SERVER}). User: ${CURRENT_USER} from IP: ${IP_ADDRESS_CLIENT}"

if command -v sendxmpp >/dev/null 2>&1; then
  printf '%s\n' "$MESSAGE" | \
    sendxmpp \
      -f "$XMPP_CONFIG" \
      -r "$XMPP_FROM_RESOURCE" \
      --tls \
      --tls-ca-path "$XMPP_TLS_CA_PATH" \
      "$XMPP_TO"
fi
```

Получатель задаётся отдельно:

```bash
XMPP_TO="admin@example.net"
```

Для смены JID не требуется менять учётные данные или остальную логику.

## Для PAM используйте данные самой SSH-сессии

Если скрипт запускается из PAM, `PAM_USER` и `PAM_RHOST` точнее описывают реальную сессию, чем `whoami` и переменные shell profile.

Оповещать стоит только об открытии SSH-сессии:

```bash
[[ ${PAM_TYPE:-} == "open_session" ]] || exit 0
[[ ${PAM_SERVICE:-} == "sshd" ]] || exit 0
```

Это также снижает риск дублирования сообщений.

## Не связывайте доступность XMPP с доступностью SSH

Синхронный сетевой запрос внутри authentication path нежелателен. Проблемы DNS, TLS или самого XMPP-сервера не должны задерживать администратора во время аварии.

На systemd-хосте доставку можно вынести в отдельный transient service:

```bash
systemd-run --quiet --collect --no-block -- \
  /usr/local/sbin/ssh-login-alert --worker \
  --user "$PAM_USER" \
  --remote "${PAM_RHOST:-unknown}"
```

PAM hook после постановки задачи должен завершаться успешно, а ошибки доставки логироваться отдельно.

## Интеграция с PAM

Перед изменением PAM держите уже открытую привилегированную SSH-сессию и сделайте резервную копию:

```bash
cp -a /etc/pam.d/sshd /etc/pam.d/sshd.before-ssh-login-alert
```

Типичная optional session rule:

```text
session optional pam_exec.so quiet /usr/local/sbin/ssh-login-alert
```

`optional` здесь принципиален: уведомление — это наблюдаемость, а не условие успешной аутентификации.

## Установка

```bash
install -o root -g root -m 0755 \
  notify_jabber.sh \
  /usr/local/sbin/ssh-login-alert
```

Файл с учётными данными устанавливайте отдельно с mode `0600`.

Старое имя вроде `notify_telegram.sh` можно временно оставить как compatibility wrapper, но в постоянной эксплуатации название лучше привести к реальному транспорту.

## Не скрывайте ошибки полностью

Постоянный `>/dev/null 2>&1` усложняет диагностику.

Лучше держать успешную отправку тихой, а ошибки писать в journal:

```bash
if ! printf '%s\n' "$MESSAGE" | sendxmpp ...; then
  logger -t ssh-login-alert -- \
    "XMPP delivery failed for user=${CURRENT_USER} remote=${IP_ADDRESS_CLIENT}"
fi
```

Пароль XMPP в лог попадать не должен.

## Что это не заменяет

Такое уведомление не заменяет:

- SSH key policy;
- MFA;
- ограничения по источникам/VPN/bastion;
- Fail2Ban;
- централизованные auth/audit logs;
- SIEM и мониторинг.

XMPP-сообщение — быстрый операторский сигнал, а не основной журнал аудита.

## Проверка

После внедрения подтвердите:

```text
sendxmpp установлен
конфигурационный файл принадлежит root и имеет mode 0600
TLS verification проходит успешно
ручное тестовое сообщение приходит на нужный JID
при недоступном XMPP вход по SSH всё равно проходит
один open_session создаёт одно уведомление
имя пользователя и remote IP корректны
ошибка доставки видна в journal
```

## Когда остановить внедрение

Не продолжайте, если пароль оказался в скрипте или репозитории, для работы приходится отключать TLS verification, уведомление способно задержать/заблокировать SSH-вход, один login создаёт несколько сообщений или PAM тестируется из единственной привилегированной сессии.

## Ссылки

- `sendxmpp(1)`: <https://manpages.debian.org/buster/sendxmpp/sendxmpp.1p.en.html>
- `pam_exec(8)`: <https://man7.org/linux/man-pages/man8/pam_exec.8.html>
- `systemd-run(1)`: <https://www.freedesktop.org/software/systemd/man/latest/systemd-run.html>
