#!/usr/bin/env python3
"""KSC 15.1 hardware CPU inventory joined to an existing CAD CSV.

Read-only KlAkOAPI calls. Pilot: SSH loopback tunnel; production: valid TLS CA.
Derived from a real inventory of 104 computers / 103 CPU host IDs.
This sanitized published revision needs its own end-to-end validation.
"""
import argparse
import csv
import getpass
import warnings
from collections import defaultdict
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
        ["KLHST_WKS_HOSTNAME", "KLHST_WKS_DN"],
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
                    found[host_id] = (computer or host_id).upper()
    finally:
        chunks.Release(accessor)
    return found


def fetch_cpu(server):
    api = KlAkSrvView(server)
    requested = KlAkArray([
        "KLHST_WKS_HOSTNAME", "dev_type", "dev_name", "dev_descr",
        "CpuCores", "CpuThreads", "CpuSpeed",
    ])
    response = api.ResetIterator(
        "HWInvPCSrvViewName", "", requested, KlAkArray([]), {},
        lifetimeSec=3600,
    )
    iterator_id = response.OutPar("wstrIteratorId")
    by_host = defaultdict(list)
    cpu_count = 0
    try:
        total = int(api.GetRecordCount(iterator_id).RetVal())
        print("Hardware records:", total)
        for start in range(0, total, 200):
            response = api.GetRecordRange(iterator_id, start, min(total, start + 200))
            records = response.OutPar("pRecords")["KLCSP_ITERATOR_ARRAY"]
            for item in records:
                if integer(item, "dev_type") != 1:
                    continue
                host_id = string(item, "KLHST_WKS_HOSTNAME")
                if not host_id:
                    continue
                by_host[host_id].append({
                    "model": string(item, "dev_name") or string(item, "dev_descr") or "Неизвестная модель",
                    "cores": integer(item, "CpuCores"),
                    "threads": integer(item, "CpuThreads"),
                    "mhz": integer(item, "CpuSpeed"),
                })
                cpu_count += 1
    finally:
        api.ReleaseIterator(iterator_id)
    print(f"CPU entries: {cpu_count}; CPU host IDs: {len(by_host)}")
    return by_host


def cpu_info(records):
    if not records:
        return ("Нет данных CPU", "", 0, "", "", "")
    models = "; ".join(sorted({item["model"] for item in records}))
    vendors = "; ".join(sorted({vendor(item["model"]) for item in records}))
    cores = sum(item["cores"] for item in records) if all(item["cores"] is not None for item in records) else ""
    threads = sum(item["threads"] for item in records) if all(item["threads"] is not None for item in records) else ""
    mhz = "; ".join(str(x) for x in sorted({item["mhz"] for item in records if item["mhz"] is not None}))
    return (models, vendors, len(records), cores, threads, mhz)


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
    parser.add_argument("--output", type=Path, default=Path("ksc_cpu_cad_inventory.xlsx"))
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
    by_host = fetch_cpu(server)
    if not hosts or not by_host:
        raise RuntimeError("KSC did not return hosts or CPU records")

    per_pc = {pc: cpu_info(by_host.get(host_id, [])) for host_id, pc in hosts.items()}
    host_rows = [[pc, *cpu, "OK" if cpu[2] else "Нет данных"] for pc, cpu in sorted(per_pc.items())]

    model_hosts = defaultdict(set)
    model_details = defaultdict(list)
    for host_id, pc in hosts.items():
        for cpu in by_host.get(host_id, []):
            model_hosts[cpu["model"]].add(pc)
            model_details[cpu["model"]].append(cpu)
    summary_rows = []
    for model, pcs in sorted(model_hosts.items(), key=lambda x: (-len(x[1]), x[0])):
        records = model_details[model]
        cores = ", ".join(str(n) for n in sorted({c["cores"] for c in records if c["cores"]}))
        threads = ", ".join(str(n) for n in sorted({c["threads"] for c in records if c["threads"]}))
        summary_rows.append([vendor(model), model, len(pcs), cores, threads])

    missing = []
    cad_rows = []
    for pc, installed in sorted(cad.items()):
        cpu = per_pc.get(pc, ("Нет данных CPU", "", 0, "", "", ""))
        if not cpu[2]:
            missing.append(pc)
        cad_rows.append([pc, *cpu,
                         ", ".join(sorted(installed.get("SOLIDWORKS", set()))),
                         ", ".join(sorted(installed.get("КОМПАС-3D", set()))),
                         ", ".join(sorted(installed.get("Siemens NX", set()))),
                         "OK" if cpu[2] else "Нет данных CPU"])

    wb = Workbook()
    wb.remove(wb.active)
    sheet(wb, "Процессоры по компьютерам",
          ["Компьютер", "Модель CPU", "Производитель", "Записей CPU",
           "Ядер всего", "Потоков всего", "Частота KSC, МГц", "Статус"],
          host_rows, [26, 58, 19, 15, 15, 17, 22, 19])
    sheet(wb, "Сводка по процессорам",
          ["Производитель", "Модель CPU", "Компьютеров", "Ядер на CPU", "Потоков на CPU"],
          summary_rows, [19, 63, 17, 17, 19])
    sheet(wb, "CPU + CAD",
          ["Компьютер", "Модель CPU", "Производитель", "Записей CPU", "Ядер всего",
           "Потоков всего", "Частота KSC, МГц", "SOLIDWORKS", "КОМПАС-3D",
           "Siemens NX", "Статус CPU"],
          cad_rows, [26, 58, 19, 15, 15, 17, 22, 29, 25, 27, 22])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    wb.save(args.output)

    print("\n===== RESULTS =====")
    print("KSC computers:", len(hosts))
    print("Computers with CPU:", sum(bool(v[2]) for v in per_pc.values()))
    print("Different CPU models:", len(model_hosts))
    print("CAD installations from CSV:", cad_count)
    print("CAD computers from CSV:", len(cad))
    print("CAD computers lacking CPU:", len(missing))
    if missing:
        print("Missing:", ", ".join(missing))
    print("Saved:", args.output.resolve())


if __name__ == "__main__":
    main()
