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
