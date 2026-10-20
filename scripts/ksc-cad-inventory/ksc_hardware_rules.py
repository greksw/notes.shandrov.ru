"""Pure, sanitized classification helpers for KSC 15.1 hardware reports.

Model-family evidence is heuristic. VRAM=0 is unknown, never zero.
Modernization priority is screening, not a performance benchmark.
"""
import re

VM_CPU = re.compile(r"QEMU|Virtual CPU|Common KVM|VMware Virtual|Hyper-V Virtual", re.I)
VM_NAME = re.compile(r"(?:^|[-_])VM\d*(?:$|[-_])|\bVIRTUAL[-_]", re.I)

def host_status(host, hardware):
    pc = host.get("name", "")
    try:
        vm_type = int(host.get("vm_type"))
    except (ValueError, TypeError):
        vm_type = 0
    names = " ".join(str(d.get("model","")) for d in hardware if d.get("type") == 1)
    if VM_CPU.search(names):
        return "Виртуальная машина", "Виртуальная модель CPU"
    if VM_NAME.search(pc):
        return "Виртуальная машина", "Признак VM в имени ПК (проверить)"
    if vm_type == 2:
        return "Физический ПК", "HST_VM_TYPE=2"
    if vm_type == 0:
        return "Проверить вручную", "HST_VM_TYPE неизвестен"
    return "Проверить вручную", f"HST_VM_TYPE={vm_type}; нет независимого признака ВМ"

NVME = [
    r"\bMSI\s+M(?:390|450|460|470|480)\b",
    r"\b(?:WD[_ ]?BLACK\s+)?SN(?:5\d\d|7\d\d|8\d\d)\b",
    r"\bWD\s+PC\s+SN\d+\b",
    r"\bMicron[_ -]?(?:2210|2400)\b",
    r"\bTOSHIBA[-_ ]RC500\b",
    r"\bKINGSTON\s+SFYRS\d+\b",
    r"\bTS\d+(?:GMTE|TMTE)\d+S\b",
    r"\bWDS\d+G3X0C\b",
    r"\bHFM\d+GD3JX\b",
    r"\bUMIS\s+RPJTJ\b",
]
SATA = [
    r"\bTOSHIBA[-_ ]TR200\b", r"\bWDS\d+G2B0A\b",
    r"\bMSI\s+S270\b", r"\bKINGSTON\s+(?:SV300S37A|SKC600)\b",
    r"\bSanDisk\s+(?:Ultra\s+II|SD9SN8)\b",
]
HDD = [
    r"\bST\d{3,5}(?:DM|VX|LM)\d+\b",
    r"\bWD(?:C\s+)?WD(?:10EZEX|10PURZ|5000AAKX)\b",
    r"\bSeagate\s+Seven\b",
]

def classify_storage(model, rpm=None):
    name = (model or "").strip()
    for rules, kind in ((NVME,"NVMe SSD"),(SATA,"SATA SSD"),(HDD,"HDD")):
        if any(re.search(rule, name, re.I) for rule in rules):
            return kind, "Справочник модельных семейств"
    if re.search(r"\bnvme\b|\bpcie\s*ssd\b", name, re.I):
        return "NVMe SSD", "Тип в названии"
    if re.search(r"\bssd\b|solid[ -]?state", name, re.I):
        return "SSD (интерфейс неизвестен)", "Тип в названии"
    if re.search(r"\bhdd\b|hard[ -]?disk", name, re.I):
        return "HDD", "Тип в названии"
    try:
        if rpm is not None and int(rpm)>0:
            return "HDD", "Положительный RPM"
    except (TypeError,ValueError):
        pass
    return "Не определён", "Недостаточно данных KSC"

def vram_mb(raw):
    try:
        result = int(raw)
        return result if result > 0 else None
    except (ValueError,TypeError,OverflowError):
        return None

def intel_generation(cpu):
    match = re.search(r"\bi[3579][ -](\d{4,5})[A-Z]*\b", cpu, re.I)
    if match:
        digits = match.group(1)
        return int(digits[:2]) if len(digits)==5 else int(digits[0])
    match = re.search(r"\b(1[0-4])(?:th|st|nd|rd)\s+Gen\b", cpu, re.I)
    return int(match.group(1)) if match else None

OLD_GPU = re.compile(
    r"(?:GT\s*710|GT\s*730|GTS\s*450|GTX\s*560\s*Ti|GTX\s*650|"
    r"Quadro\s*2000|Radeon\s+HD\s*[0-6]\d{3})\b", re.I
)

def modernization_priority(cpu, ram_gib, gpu, disk_classes, cad):
    """Inventory screening priority only. Higher score means review first."""
    if not cpu or cpu == "Нет данных" or not isinstance(ram_gib,(int,float)) or ram_gib<=0:
        return "Проверить", 0, "Неполные сведения CPU/RAM"
    points, reasons = 0, []
    gen = intel_generation(cpu)
    old = gen is not None and gen<=4
    old |= bool(re.search(r"\b(?:Celeron|Pentium|Athlon\s+II|AMD\s+E2-|AMD\s+FX)\b",cpu,re.I))
    if old:
        points+=4; reasons.append("Процессор старой платформы")
    elif gen is not None and 5<=gen<=7:
        points+=2; reasons.append("Intel Core 5–7-го поколения")
    elif re.search(r"Ryzen\s+[3579]\s+1\d{3}\b",cpu,re.I):
        points+=2; reasons.append("AMD Ryzen первого поколения")
    if ram_gib<=8:
        points+=2; reasons.append("RAM ≤8 ГиБ")
    elif ram_gib<=12:
        points+=1; reasons.append("RAM ≤12 ГиБ")
    if OLD_GPU.search(gpu or ""):
        points+=2; reasons.append("GPU устаревшего класса")
    if disk_classes and all(x=="HDD" for x in disk_classes):
        points+=1; reasons.append("Только HDD по данным KSC")
    if old and ("SOLIDWORKS 2023" in cad or "Siemens NX" in cad):
        points+=1; reasons.append("SOLIDWORKS 2023/NX на старой платформе")
    priority = "Высокий" if points>=5 else "Средний" if points>=2 else "Низкий"
    return priority, points, "; ".join(reasons) or "Нет выявленных признаков высокого риска"
