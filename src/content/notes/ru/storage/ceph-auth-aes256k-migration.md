---
title: "Миграция Ceph authentication keys на aes256k без потери доступа к кластеру"
description: "Поэтапный operational-подход к ротации Ceph service и client keys с сохранением quorum и administrative access."
category: "Хранилища и резервное копирование"
tags: ["ceph", "proxmox", "security", "authentication", "storage"]
published: 2026-09-16
updated: 2026-09-16
status: current
testedOn: ["Proxmox VE 9.x", "Ceph cluster"]
featured: true
lang: ru
translationKey: "storage/ceph-auth-aes256k-migration"
---

## Контекст

Ceph cluster может оставаться healthy и при этом всё ещё разрешать или фактически использовать authentication key types, которые уже не соответствуют требуемому security baseline.

Ротация таких keys — не один toggle. В authentication участвуют monitors, managers, OSDs и administrative clients, поэтому неполная миграция способна либо заблокировать операторский доступ, либо нарушить взаимодействие между daemons.

Безопасный путь — staged migration, а уже после неё отдельный policy-enforcement step.

## До изменения keys

Сначала подтвердите состояние cluster и recovery path.

- проверьте monitor quorum;
- зафиксируйте текущий health state и существующие warnings;
- убедитесь, что administrative access работает более чем с одного ожидаемого node;
- не совмещайте key rotation с unrelated upgrades или storage maintenance;
- при необходимости перенесите некритичные workloads, если это заметно снижает operational risk.

Цель не в том, чтобы добиться идеально чистого `HEALTH_OK` любой ценой. Важно, чтобы после начала миграции новые проблемы можно было связать именно с authentication change.

## Порядок ротации

Ротируйте service identities контролируемыми группами, а не заменяйте все keys одновременно.

После каждой группы проверяйте, что соответствующие daemons снова подключились, quorum остаётся стабильным, а placement groups не перешли в неожиданный state.

Administrative client keys требуют отдельной осторожности. `client.admin` ротируйте только тогда, когда уже существует другой заведомо рабочий administrative path, и обязательно проверьте новый key до уничтожения старого пути доступа.

## Не ужесточайте monitor policy слишком рано

Нужно разделять два состояния:

1. все известные service/client keys уже переведены на stronger type;
2. monitors полностью запрещают старые insecure key types.

Сначала завершите первый этап и исследуйте active sessions. Только потом применяйте второй.

Если monitor-side restriction включить, пока забытый daemon или client всё ещё использует старый type, security cleanup легко превратится в availability incident.

## Проверка

После каждого этапа проверяйте:

- monitor quorum и manager availability;
- Ceph health и состояние placement groups;
- OSD connectivity;
- authentication с ожидаемых administrative nodes;
- key type у каждой уже ротированной service identity;
- active monitor sessions перед финальным policy restriction.

Если service keys уже соответствуют baseline, но monitors временно всё ещё разрешают старые key types, сохраняйте оставшийся warning явным. Это означает незавершённый enforcement, а не неудачную rotation.

## Эксплуатационный вывод

Для clustered infrastructure security migration лучше разделять **credential replacement** и **policy enforcement**.

Первый этап доказывает совместимость. Второй убирает fallback только после того, как evidence показывает, что он больше не нужен.
