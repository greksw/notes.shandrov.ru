#requires -Version 5.1
<#
.SYNOPSIS
  Collect installed RAM module information from a Windows endpoint.
.DESCRIPTION
  Read-only Win32_PhysicalMemory scan. Saves timestamped JSON locally.
  Optionally copies JSON to a restricted SMB drop as SYSTEM.
  No RAM-module serial numbers or user credentials are collected.
#>
[CmdletBinding()]
param(
    [string]$OutputDir = 'C:\ProgramData\CorpInventory\RAM',
    [string]$SharePath = '',
    [ValidateRange(1, 365)]
    [int]$RetentionDays = 30
)
$ErrorActionPreference = 'Stop'

function Resolve-SmbiosMemoryType {
    param([int]$Code)
    switch ($Code) {
        21 { 'DDR2' }
        24 { 'DDR3' }
        26 { 'DDR4' }
        27 { 'LPDDR3' }
        30 { 'LPDDR4' }
        31 { 'LPDDR4X' }
        34 { 'DDR5' }
        35 { 'LPDDR5' }
        default { "Unknown ($Code)" }
    }
}

New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
$computerName = $env:COMPUTERNAME.ToUpperInvariant()
if ($computerName -notmatch '^[A-Z0-9_-]{1,63}$') {
    throw 'COMPUTERNAME contains unexpected characters'
}

try {
    $physicalMemory = @(Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction Stop)
    if ($physicalMemory.Count -eq 0) {
        throw 'Win32_PhysicalMemory returned no memory modules'
    }

    $modules = @(
        foreach ($memory in $physicalMemory) {
            if (-not $memory.Capacity -or [int64]$memory.Capacity -le 0) { continue }
            [PSCustomObject]@{
                Slot          = ([string]$memory.DeviceLocator).Trim()
                Bank          = ([string]$memory.BankLabel).Trim()
                Manufacturer  = ([string]$memory.Manufacturer).Trim()
                PartNumber    = ([string]$memory.PartNumber).Trim()
                CapacityGiB   = [math]::Round([double]$memory.Capacity / 1GB, 2)
                MemoryType    = Resolve-SmbiosMemoryType -Code ([int]$memory.SMBIOSMemoryType)
                SpeedMTs      = [int]$memory.Speed
                ConfiguredMTs = [int]$memory.ConfiguredClockSpeed
            }
        }
    )
    if ($modules.Count -eq 0) {
        throw 'Win32_PhysicalMemory returned no modules with positive capacity'
    }

    $inventory = [PSCustomObject]@{
        SchemaVersion = 1
        ComputerName  = $computerName
        CollectedAt   = (Get-Date).ToUniversalTime().ToString('o')
        TotalRAMGiB   = [math]::Round([double](($modules | Measure-Object CapacityGiB -Sum).Sum), 2)
        Modules       = $modules
    }
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')
    $filename = '{0}_{1}_{2}.json' -f $computerName, $stamp, ([guid]::NewGuid().ToString('N'))
    $destination = Join-Path $OutputDir $filename
    $temporary = Join-Path $OutputDir ('.' + $filename + '.tmp')

    try {
        $inventory | ConvertTo-Json -Depth 5 -Compress |
            Set-Content -LiteralPath $temporary -Encoding UTF8
        [System.IO.File]::Move($temporary, $destination)
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Output "Saved locally: $destination"

    if ($SharePath) {
        if ($SharePath -notmatch '^\\\\[^\\]+\\[^\\]+') {
            throw 'SharePath must be a UNC path such as \\server\RamDrop$'
        }
        $remoteFile = Join-Path $SharePath $filename
        Copy-Item -LiteralPath $destination -Destination $remoteFile -ErrorAction Stop
        Write-Output "Published to SMB: $remoteFile"
    }

    $olderThan = (Get-Date).AddDays(-$RetentionDays)
    Get-ChildItem -LiteralPath $OutputDir -Filter ($computerName + '_*.json') -File -ErrorAction Stop |
        Where-Object { $_.LastWriteTime -lt $olderThan } |
        Remove-Item -Force -ErrorAction Stop
    Write-Output "Computer=$computerName; Modules=$($modules.Count); RAM_GiB=$($inventory.TotalRAMGiB)"
} catch {
    Write-Error ("RAM inventory failed on {0}: {1}" -f $computerName, $_.Exception.Message)
    exit 1
}