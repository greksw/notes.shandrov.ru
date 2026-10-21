# KSC CAD inventory exporter

Read-only inventory exporter for Kaspersky Security Center 15.1, using the KlAkOAPI package supplied with KSC.

## Setup

Install Python 3.12, create a virtual environment and install `requests` and `openpyxl`. Extract the vendor's `KlAkOAPI.tar.gz` under `vendor/` and point `PYTHONPATH` at the extracted package's parent directory.

For initial testing, forward HTTPS port 13299 from a trusted SSH session and run:

```bash
python scripts/ksc-cad-inventory/export_cad_hosts.py --insecure-local-test --limit 10
```

For ongoing usage, configure an HTTPS hostname that matches the server's certificate and use `--ca-bundle /path/to/ca.pem`. Never rely on disabled TLS verification for unattended production jobs.

## Output

The script produces `reports/cad_hosts.xlsx`, `reports/cad_hosts.csv`, and `reports/cad_errors.csv`. The workbook contains a per-computer matrix, full installation list, sheets for KOMPAS-3D, SOLIDWORKS and Siemens NX, version summary and validation details.

The software data represents the last KSC inventory, not a live endpoint scan. Excludes viewers, add-ons, SOLIDWORKS Document Manager API and similar components.

## Security and validation

Use a dedicated internal KSC account with read-only permissions. Credentials are requested interactively, not saved. Reports contain sensitive internal workstation names and must not be committed to Git. The published revision is adapted from an observed successful run (104 hosts, 62 CAD installs, 32 computers) and has not been independently retested against the productive server.

For the KSC 15.1 response, `GetHostInvProducts` returns a KlAkParams value with array key `GNRL_EA_PARAM_1`; `OutPars()` may be empty.


## Physical workstation hardware report (CPU + RAM + GPU + disks + CAD)

The **two-file** hardware exporter must be downloaded together:
- [ksc_cpu_cad_export.py](ksc_cpu_cad_export.py)
- [ksc_hardware_rules.py](ksc_hardware_rules.py)

Run in the KSC inventory virtual environment with the local SSH tunnel open:

~~~bash
python -m py_compile ksc_cpu_cad_export.py ksc_hardware_rules.py
python ksc_cpu_cad_export.py --insecure-local-test --probe
python ksc_cpu_cad_export.py --insecure-local-test \
  --cad-csv cad_hosts.csv --output ksc_hardware_cad_physical.xlsx
~~~

For unattended production usage, use --ca-bundle with a matching TLS server hostname instead.

The report includes CPU, RAM, GPU, storage, CAD, an **Исключения** sheet and an explicitly heuristic **Приоритет CAD** sheet. The detailed **Методика** sheet describes the scoring. Do **not** merge inventory reports containing private hostnames into a public repository.

### Interpreting the revised report

- The physical-device report contains only devices with HST_VM_TYPE=2, provided no independent virtualization indicator is present.
- A clear virtualization CPU/name signal is listed as **Виртуальная машина**. A device with a conflicting VM type but a laptop/NUC-style name is marked **Проверить вручную**, not presumed to be a confirmed VM or physical device.
- Duplicate, identical CPU signatures are combined for reporting with a warning. Real multiple physical sockets must be checked manually.
- When VideoCardMemorySize is 0 or absent, the VRAM cell is **blank**, meaning no reliable KSC value. Never infer an official VRAM amount from the model name.
- Disk type uses conservative **specific model-family** rules and direct type/RPM evidence. All unsupported models remain **Не определён**.
- The CAD modernization priority is a **preliminary triage score**, not an application benchmark, performance guarantee, GPU certification or purchasing decision.
- A separate end-to-end run of the new revision against the productive KSC instance is still required.
