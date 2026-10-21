# Windows RAM module inventory (pilot)

This is a read-only PowerShell 5.1 collector for Win32_PhysicalMemory. It reports slot, bank, manufacturer, PartNumber, GiB, SMBIOS DDR type, nominal and configured speed. It deliberately excludes hardware serial numbers and user credentials.

## Run local pilot

Download `Collect-RamInventory.ps1` to the target Windows workstation, then run it in PowerShell with no SharePath. It saves timestamped JSON under `C:\ProgramData\CorpInventory\RAM`.

The companion Linux validation and Excel merger is included in the [pilot package delivered in the conversation](../../README.md) and should be reviewed before adding to this repo; no GPO has been deployed.

## Proposed secure collection

Once local JSON is verified, provision a **separate restricted SMB drop share** (not SYSVOL or NETLOGON). Domain computers running as SYSTEM may create their own reports, but should not enumerate or read others' reports; apply share and NTFS permissions. An authorized collection service performs ingestion and retention.

Test one workstation under SYSTEM, then a small pilot OU, before broadening the GPO scope. Windows HypervisorPresent and KSC HST_VM_TYPE are not reliable sole determinants of physical/virtual status.

Keep computer names, inventory JSON, reports, internal UNC paths and credentials **out of public GitHub**.
