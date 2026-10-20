#!/usr/bin/env python3
"""KSC 15.1 hardware CPU inventory joined to an existing CAD CSV.

Read-only KlAkOAPI calls. Pilot: SSH loopback tunnel; production: valid TLS CA.
Derived from a real inventory of 104 computers / 103 CPU host IDs.
This sanitized published revision needs its own end-to-end validation.
"""
import argparse
import csv
import getpass
import re
import warnings
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path

from openpyxl import Workbook
from openpyxl.styles import Alignment, Font, PatternFill
from openpyxl.utils import get_column_letter
from KlAkOAPI.AdmServer import KlAkAdmServer
from KlAkOAPI.ChunkAccessor import KlAkChunkAccessor
from KlAkOAPI.HostGroup import KlAkHostGroup
from KlAkOAPI.Params import KlAkArray
from KlAkOAPI.SrvView import KlAkSrvView


def get(item, name):
    if hasattr(item, "GetNames"):
        return item[name] if name in item.GetNames() else None
    if isinstance(item, dict):
        return item.get(name)
    return None


def string(item, name):
    value = get(item, name)
    return "" if value is None else str(value).strip()


def integer(item, name):
    try:
        value = int(get(item, name))
        return value if value > 0 else None
    except (ValueError, TypeError):
        return None


def integer(item, field):
    try:
        v = get(item, field)
        n = int(v)
        return n if n >= 0 else None
    except (TypeError, ValueError, OverflowError):
        return None


def vendor(model):
    text = model.casefold()
    if "intel" in text:
        return "Intel"
    if any(part in text for part in ("amd", "ryzen", "epyc", "athlon")):
        return "AMD"
    return "Не определён"


def fetch_hosts(server):
    api = KlAkHostGroup(server)
    chunks = KlAkChunkAccessor(server)
    answer = api.FindHosts(
        '(KLHST_WKS_HOSTNAME="*")',
        ["KLHST_WKS_HOSTNAME", "KLHST_WKS_DN", "HST_VM_TYPE", "KLHST_WKS_LAST_NAGENT_CONNECTED"],
        [], {"KLGRP_FIND_FROM_CUR_VS_ONLY": True}, 3600,
    )
    accessor = answer.OutPar("strAccessor")
    found = {}
    try:
        count = int(chunks.GetItemsCount(accessor).RetVal())
        for start in range(0, count, 100):
            response = chunks.GetItemsChunk(accessor, start, min(100, count - start))
            records = response.OutPar("pChunk")["KLCSP_ITERATOR_ARRAY"]
            for record in records:
                host_id = string(record, "KLHST_WKS_HOSTNAME")
                computer = string(record, "KLHST_WKS_DN")
                if host_id:
                    found[host_id] = {"name": (computer or host_id).upper(), "vm_type": get(record, "HST_VM_TYPE"), "last_seen": string(record, "KLHST_WKS_LAST_NAGENT_CONNECTED")}
    finally:
        chunks.Release(accessor)
    return found


def fetch_hardware(server):
    api = KlAkSrvView(server)
    requested = KlAkArray([
        "KLHST_WKS_HOSTNAME", "dev_type", "dev_id", "dev_name", "dev_descr",
        "dev_manuf", "dev_xpar2", "dev_xpar3", "CpuCores", "CpuThreads",
        "CpuSpeed", "StorageRotationRate", "VideoCardMemorySize",
        "RamType", "RamPartNum", "SerialNum",
    ])
    response = api.ResetIterator("HWInvPCSrvViewName", "", requested, KlAkArray([]), {}, lifetimeSec=3600)
    token = response.OutPar("wstrIteratorId")
    by_host, types = defaultdict(list), Counter()
    try:
        total = int(api.GetRecordCount(token).RetVal())
        for offset in range(0, total, 200):
            data = api.GetRecordRange(token, offset, min(total, offset + 200))
            for item in data.OutPar("pRecords")["KLCSP_ITERATOR_ARRAY"]:
                kind = integer(item, "dev_type")
                types[kind] += 1
                host_id = string(item, "KLHST_WKS_HOSTNAME")
                if not host_id:
                    continue
                by_host[host_id].append({
                    "type": kind,
                    "device_id": string(item, "dev_id"),
                    "serial": string(item, "SerialNum"),
                    "model": string(item, "dev_name") or string(item, "dev_descr"),
                    "manufacturer": string(item, "dev_manuf"),
                    "cores": integer(item, "CpuCores"),
                    "threads": integer(item, "CpuThreads"),
                    "speed": integer(item, "CpuSpeed"),
                    "xpar2": integer(item, "dev_xpar2"),
                    "xpar3": integer(item, "dev_xpar3"),
                    "rpm": integer(item, "StorageRotationRate"),
                    "vram": integer(item, "VideoCardMemorySize"),
                    "ram_type": string(item, "RamType"),
                    "ram_part": string(item, "RamPartNum"),
                })
    finally:
        api.ReleaseIterator(token)
    return by_host, total, types


def gib(value):
    return round(value / (1024 ** 3), 2) if value else None


def type_of_storage(item):
    model = item["model"].lower()
    if "nvme" in model:
        return "NVMe SSD (по названию)"
    if "ssd" in model or "solid state" in model:
        return "SSD (по названию)"
    if "hdd" in model or (item["rpm"] or 0) > 0:
        return "HDD"
    return "Неизвестен"


def dedup_hardware(records, category):
    used, unique, duplicates = set(), [], 0
    for item in records:
        if item["type"] != category:
            continue
        if category == 1:
            # Identical CPU signatures are a duplicate unless independently verified.
            key = (item["model"].casefold(), item["cores"], item["threads"], item["speed"])
        else:
            # Do NOT merge equal-size/equal-model DIMMs or SSDs: they can be real devices.
            key = (item["device_id"] or item["serial"])
            if not key:
                unique.append(item)
                continue
        if key in used:
            duplicates += 1
        else:
            used.add(key)
            unique.append(item)
    return unique, duplicates


def skip_reason(host, hardware):
    try:
        vmtype = int(host["vm_type"])
    except (ValueError, TypeError):
        vmtype = 0
    pc = host["name"]
    cpu_names = " ".join(item["model"] for item in hardware if item["type"] == 1)
    if re.search(r"QEMU|Virtual CPU|Common KVM|VMware Virtual|Hyper-V Virtual", cpu_names, re.I):
        return "ВМ: виртуальная модель CPU"
    if re.search(r"(?:^|[-_])VM\d*(?:$|[-_])|\bVIRTUAL[-_]", pc, re.I):
        return "ВМ: характерное имя ПК"
    if vmtype in (1, 3, 4, 5, 6, 7, 8, 9):
        return "ВМ: HST_VM_TYPE=" + str(vmtype)
    if vmtype != 2:
        return "Не определён тип: HST_VM_TYPE=0 или отсутствует"
    return ""

def hardware_info(records):
    cpus, duplicates = dedup_hardware(records, 1)
    rams, _ = dedup_hardware(records, 2)
    disks, _ = dedup_hardware(records, 3)
    gpus, _ = dedup_hardware(records, 4)
    names = "; ".join(sorted({r["model"] for r in cpus}))
    cores = sum(r["cores"] for r in cpus) if cpus and all(r["cores"] for r in cpus) else ""
    threads = sum(r["threads"] for r in cpus) if cpus and all(r["threads"] for r in cpus) else ""
    freq = "; ".join(sorted({str(r["speed"]) for r in cpus if r["speed"]}))
    ram = gib(sum(r["xpar3"] for r in rams)) if rams and all(r["xpar3"] for r in rams) else ""
    gpu = "; ".join(sorted({r["model"] for r in gpus}))
    vram = "; ".join(sorted({str(r["vram"]) for r in gpus if r["vram"] is not None}))
    disk_gb = round(sum(gib(r["xpar2"]) for r in disks), 2) if disks and all(r["xpar2"] for r in disks) else ""
    disk_type = "; ".join(sorted({type_of_storage(r) for r in disks}))
    disk_models = "; ".join(sorted({r["model"] for r in disks}))
    checks = (["Повторы CPU удалены"] if duplicates else [])
    checks += ["Нет CPU"] if not cpus else []
    checks += ["Нет RAM"] if not rams else []
    checks += ["Нет GPU"] if not gpus else []
    checks += ["Нет дисков"] if not disks else []
    data = [names or "Нет данных", vendor(names), len([r for r in records if r["type"] == 1]),
            len(cpus), cores, threads, freq, ram, len(rams), gpu, vram,
            disk_gb, len(disks), disk_type, disk_models, "; ".join(checks) or "OK"]
    return data, cpus, rams, gpus, disks, duplicates

def read_cad(path):
    if not path.is_file():
        raise RuntimeError(f"CAD CSV is missing: {path}")
    by_pc = defaultdict(lambda: defaultdict(set))
    records = 0
    with path.open(encoding="utf-8-sig", newline="") as source:
        reader = csv.DictReader(source, delimiter=";")
        expected = {"Computer", "Software", "Release", "ServicePack", "DisplayVersion"}
        if not expected.issubset(reader.fieldnames or []):
            raise RuntimeError(f"Unexpected CAD CSV columns: {reader.fieldnames}")
        for item in reader:
            pc = (item["Computer"] or "").strip().upper()
            app = (item["Software"] or "").strip()
            release = " ".join(v.strip() for v in (item["Release"], item["ServicePack"]) if v and v.strip())
            if not release:
                release = ("build " + (item["DisplayVersion"] or "").strip()).strip()
            if pc and app:
                by_pc[pc][app].add(release or "Не определена")
                records += 1
    return by_pc, records


def clean(value):
    # Treat data from remote inventory as text, not an Excel formula.
    if isinstance(value, str) and value.startswith(("=", "+", "-", "@")):
        return "'" + value
    return value


def sheet(book, title, headings, rows, widths):
    tab = book.create_sheet(title)
    tab.append(headings)
    for row in rows:
        tab.append([clean(value) for value in row])
    tab.freeze_panes = "B2"
    tab.auto_filter.ref = tab.dimensions
    tab.sheet_view.showGridLines = False
    tab.row_dimensions[1].height = 30
    for cell in tab[1]:
        cell.fill = PatternFill("solid", fgColor="203864")
        cell.font = Font(color="FFFFFF", bold=True)
        cell.alignment = Alignment(wrap_text=True, vertical="center")
    for column, width in enumerate(widths, 1):
        tab.column_dimensions[get_column_letter(column)].width = width
    return tab


def main():
    parser = argparse.ArgumentParser(description="Read-only KSC CPU inventory + CAD Excel")
    parser.add_argument("--url", default="https://127.0.0.1:13299")
    parser.add_argument("--insecure-local-test", action="store_true")
    parser.add_argument("--ca-bundle", type=Path)
    parser.add_argument("--cad-csv", type=Path, default=Path("cad_hosts.csv"))
    parser.add_argument("--output", type=Path, default=Path("ksc_hardware_cad_physical.xlsx"))
    parser.add_argument("--probe", action="store_true", help="Show device/VM type coverage before exporting")
    args = parser.parse_args()

    if args.insecure_local_test and args.ca_bundle:
        parser.error("Choose --insecure-local-test OR --ca-bundle")
    if args.insecure_local_test:
        if not args.url.startswith(("https://127.0.0.1:", "https://localhost:")):
            parser.error("The insecure mode is allowed only on a loopback SSH tunnel")
        from urllib3.exceptions import InsecureRequestWarning
        warnings.filterwarnings("once", category=InsecureRequestWarning)
        verify = False
    elif args.ca_bundle:
        if not args.ca_bundle.is_file():
            parser.error("CA bundle does not exist")
        verify = str(args.ca_bundle)
    else:
        parser.error("Specify --insecure-local-test for pilot or --ca-bundle for production")

    cad, cad_count = read_cad(args.cad_csv)
    user = input("KSC username [ksc-inventory]: ").strip() or "ksc-inventory"
    password = getpass.getpass("KSC password: ")
    server = KlAkAdmServer.Create(args.url, user, password, domain="", internal_user=True, verify=verify)
    del password

    hosts = fetch_hosts(server)
    hardware, total, types = fetch_hardware(server)
    if not hosts or not hardware:
        raise RuntimeError("No hosts or hardware records returned")
    print("KSC hosts:", len(hosts), "| Hardware records:", total)
    print("dev_type count:", dict(sorted(types.items(), key=lambda x: str(x[0]))))
    print("HST_VM_TYPE count:", dict(Counter(str(h["vm_type"]) for h in hosts.values())))
    if args.probe:
        for kind in (1, 2, 3, 4):
            print(f"dev_type={kind} records={types[kind]}; hosts={sum(any(d['type']==kind for d in rows) for rows in hardware.values())}")
        return

    confirmed = {}
    excluded = []
    for host_id, h in hosts.items():
        reason = skip_reason(h, hardware.get(host_id, []))
        if reason:
            excluded.append([h["name"], str(h["vm_type"]), reason])
        else:
            confirmed[host_id] = h

    hwrows, details_ram, details_gpu, details_disk = [], [], [], []
    by_pc, model_hosts, cpu_duplicate_hosts = {}, defaultdict(set), 0
    for host_id, host in sorted(confirmed.items(), key=lambda x: x[1]["name"]):
        pc = host["name"]
        data, cpus, rams, gpus, disks, duplicates = hardware_info(hardware.get(host_id, []))
        cpu_duplicate_hosts += bool(duplicates)
        full = [pc, *data[:-1], host["last_seen"], data[-1]]
        hwrows.append(full)
        by_pc[pc] = full
        for cpu in cpus:
            model_hosts[(vendor(cpu["model"]), cpu["model"])].add(pc)
        for r in rams:
            details_ram.append([pc, r["model"], r["manufacturer"], gib(r["xpar3"]), r["ram_type"], r["ram_part"], r["xpar2"]])
        for r in gpus:
            details_gpu.append([pc, r["model"], r["manufacturer"], r["vram"]])
        for r in disks:
            details_disk.append([pc, r["model"], r["manufacturer"], gib(r["xpar2"]), type_of_storage(r), r["rpm"]])

    cad_rows, cad_unmatched = [], []
    for pc, installed in sorted(cad.items()):
        if pc not in by_pc:
            cad_unmatched.append(pc)
            excluded.append([pc, "", "Инженерный ПК отсутствует в подтверждённой физической выборке"])
            continue
        row = by_pc[pc]
        cad_rows.append([*row[:-2],
                         ", ".join(sorted(installed.get("SOLIDWORKS", set()))),
                         ", ".join(sorted(installed.get("КОМПАС-3D", set()))),
                         ", ".join(sorted(installed.get("Siemens NX", set()))),
                         row[-1]])

    headers = ["Компьютер", "CPU модель", "Производитель", "CPU сырых",
               "CPU уникальных", "Ядра", "Потоки", "Частота CPU (МГц)",
               "RAM (ГиБ)", "Модулей RAM", "GPU модель", "VRAM (МБ)",
               "Диски (ГиБ)", "Накопителей", "Тип дисков",
               "Модели накопителей", "Связь агента KSC", "Контроль"]
    wb = Workbook()
    wb.remove(wb.active)
    sheet(wb, "Итоги", ["Показатель", "Значение"], [
        ["Дата", datetime.now().astimezone().isoformat(timespec="seconds")],
        ["KSC устройств", len(hosts)], ["Подтверждённые физические", len(confirmed)],
        ["Виртуальные и неопределённые", len(hosts) - len(confirmed)],
        ["Устройств с дублями CPU", cpu_duplicate_hosts],
        ["CAD компьютеров", len(cad)], ["CAD компьютеров в физической выборке", len(cad_rows)],
        ["CAD компьютеров вне выборки", len(cad_unmatched)],
        ["Критерий", "HST_VM_TYPE=2, нет признаков виртуализации"],
        ["Неизвестный тип", "Исключается до ручной проверки"],
        ["Источник", "Сохранённая инвентаризация KSC, не live-проверка"]
    ], [45, 80])
    sheet(wb, "Оборудование", headers, hwrows,
          [26, 59, 20, 16, 18, 14, 15, 23, 16, 16, 59, 18, 18, 17, 29, 58, 34, 35])
    summary_rows = [[v, model, len(pcs)] for (v, model), pcs in
                    sorted(model_hosts.items(), key=lambda x: (-len(x[1]), x[0][1]))]
    sheet(wb, "Сводка CPU", ["Производитель", "Модель", "Компьютеров"], summary_rows, [20, 65, 19])
    sheet(wb, "CPU + CAD", [*headers[:-2], "SOLIDWORKS", "КОМПАС-3D", "Siemens NX", "Контроль"],
          cad_rows, [26, 59, 20, 16, 18, 14, 15, 23, 16, 16, 59, 18, 18, 17, 29, 58, 30, 30, 30, 35])
    sheet(wb, "Модули RAM", ["Компьютер", "RAM", "Производитель", "ГиБ", "Тип", "PartNum", "МГц"],
          details_ram, [26, 56, 25, 16, 20, 33, 18])
    sheet(wb, "GPU", ["Компьютер", "Модель GPU", "Производитель", "VRAM МБ"],
          details_gpu, [26, 59, 26, 18])
    sheet(wb, "Накопители", ["Компьютер", "Модель", "Производитель", "ГиБ", "Класс", "RPM"],
          details_disk, [26, 59, 26, 18, 31, 16])
    sheet(wb, "Исключения", ["Компьютер", "HST_VM_TYPE", "Причина"],
          sorted(excluded), [28, 21, 67])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    wb.save(args.output)
    print("===== RESULTS =====")
    print("KSC hosts:", len(hosts), "confirmed physical:", len(confirmed), "excluded/unknown:", len(hosts) - len(confirmed))
    print("Duplicate CPU hosts:", cpu_duplicate_hosts)
    print("RAM rows:", len(details_ram), "GPU rows:", len(details_gpu), "storage rows:", len(details_disk))
    print("CAD computers:", len(cad), "physical with inventory:", len(cad_rows), "excluded/unknown:", len(cad_unmatched))
    if cad_unmatched:
        print("REVIEW excluded CAD machines:", ", ".join(cad_unmatched))
    print("Saved:", args.output.resolve())



if __name__ == "__main__":
    main()
