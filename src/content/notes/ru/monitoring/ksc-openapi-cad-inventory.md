---
title: "Инвентаризация КОМПАС-3D, SOLIDWORKS и Siemens NX через KSC 15.1 Open API"
description: "Практический кейс: Python, KlAkOAPI и Excel-отчёт по версиям установленного CAD на рабочих станциях."
category: "Мониторинг и безопасность"
tags: ["kaspersky", "ksc", "python", "inventory", "cad", "solidworks", "kompas-3d", "siemens-nx"]
published: 2026-10-20
updated: 2026-10-20
status: current
testedOn: ["Kaspersky Security Center 15.1", "Windows Server 2022", "Python 3.12.3", "KlAkOAPI 1.0.0.0"]
featured: false
lang: ru
translationKey: "monitoring/ksc-openapi-cad-inventory"
---

## Задача

Нужно получить не каталог программ, а таблицу **какие версии КОМПАС-3D, SOLIDWORKS и Siemens NX установлены на каких компьютерах**, с указанием Service Pack. Отдельные Viewer, конфигурации, API-компоненты и вспомогательные библиотеки не учитываются как основные CAD-системы.

Вместо удалённого опроса каждого компьютера использовали **Kaspersky Security Center 15.1 Open API**. Из инвентаризации 104 компьютеров получено **62 установки CAD на 32 рабочих станциях**. Ошибок API-запросов — 0.

**GitHub:** [Python-экспортёр CAD](https://github.com/greksw/notes.shandrov.ru/blob/main/scripts/ksc-cad-inventory/export_cad_hosts.py) и [README с инструкцией](https://github.com/greksw/notes.shandrov.ru/blob/main/scripts/ksc-cad-inventory/README.md). Публичный код адаптирован и обезличен; после переработки он ещё не проходил отдельный сквозной прогон на продуктивном KSC.

## Архитектура

```text
Kaspersky Security Center 15.1 / Windows Server 2022
  Open API HTTPS:13299
    -> SSH-туннель (пилот) / доверенный HTTPS (production)
    -> Linux / Python 3.12 / KlAkOAPI
       -> HostGroup.FindHosts: список устройств
       -> InventoryApi.GetHostInvProducts: ПО на устройстве
    -> классификация основных CAD
    -> XLSX + CSV
```

Для подключения создан **внутренний пользователь KSC с правами только на чтение** базовой функциональности и инвентаризации приложений. В MMC предварительно включили отображение разделов безопасности. Пароль в код не записывался. SSH на Windows-сервере был включён существующей доменной задачей настройки OpenSSH от SYSTEM с ограничением доверенных сетей — для самого API SSH не обязателен.

## Python и KlAkOAPI

Архив `KlAkOAPI.tar.gz` взят из установленного KSC и перенесён с проверкой контрольной суммы. В данной поставке отсутствовали `setup.py` и `pyproject.toml`; подключение через `PYTHONPATH` оказалось проще прямого `pip install`:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install requests openpyxl
mkdir -p vendor
tar -xzf KlAkOAPI.tar.gz -C vendor --no-same-owner
export PYTHONPATH="$PWD/vendor/KlAkOAPI-1.0.0.0"
```

Библиотека поставляется Kaspersky и не включена в публичный GitHub-репозиторий.

## Диагностика авторизации

Сначала возникла ошибка `Authentication failure`. Для отдельной внутренней записи важно передать в `KlAkAdmServer.Create` параметр `internal_user=True`. После правильной аутентификации сервер отвечал `Authenticated user not authorized` — понадобились разрешения чтения в MMC KSC. Изменяющие права выдавать не пришлось.

Ещё один нюанс: вызов `GetInvProductsList(KlAkParams())` вернул `KlAkResponse`, но `OutPars()` был пустым. Инвентаризация находится внутри `RetVal()`, возвращающего `KlAkParams`. Массив в проверенной среде назывался `GNRL_EA_PARAM_1`, а не ожидаемый `KLEVP_EA_PARAM_1`:

```python
result = response.RetVal()
print(result.GetNames())  # ['GNRL_EA_PARAM_1']
products = result["GNRL_EA_PARAM_1"]
```

Получено **2884 записи каталога приложений**. Однако каталог не связывает программу с конкретным ПК. Для этого использовали `HostGroup.FindHosts` и `GetHostInvProducts(host_id, KlAkParams())`; названия и версии брали из `DisplayName` и `DisplayVersion`.

## Результаты

| CAD | Версия | Установок |
| --- | --- | ---: |
| SOLIDWORKS | 2019 SP03 | 8 |
| SOLIDWORKS | 2019 SP05.1 | 14 |
| SOLIDWORKS | 2023 SP05 | 5 |
| КОМПАС-3D | v16.1 | 6 |
| КОМПАС-3D | v19 | 19 |
| Siemens NX | 12.0.2 | 9 |
| Siemens NX | build 22.06.9220.00005 (релиз не указан) | 1 |
| **Итого** | | **62** |

Запись `SOLIDWORKS 2020 Document Manager API` была в каталоге, но полноценного SOLIDWORKS 2020 в инвентаризации не обнаружено. Учитывать API-компонент как отдельную CAD-установку было бы ошибкой.

## Отчёт и ограничения

Экспортёр формирует `cad_hosts.xlsx` с матрицей компьютеров, детализацией, вкладками по CAD и сводкой версий, а также `cad_hosts.csv` и `cad_errors.csv`. Отчёт включает реальные имена рабочих станций, поэтому его **не публикуют в GitHub**.

Результаты — **последние сведения от агентов KSC**, а не онлайн-проверка ПО. Отсутствие ошибок API не доказывает свежесть инвентаризации. Для регулярного сбора следует дополнительно проверять время последней связи агента и обеспечить верификацию TLS: отключение проверки допустимо лишь при диагностическом запуске через loopback SSH-туннель.

Пример скрипта и его эксплуатационные ограничения: [GitHub — KSC CAD Inventory](https://github.com/greksw/notes.shandrov.ru/tree/main/scripts/ksc-cad-inventory).
