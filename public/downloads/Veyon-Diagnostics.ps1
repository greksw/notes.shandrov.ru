# Read-only, anonymized troubleshooting example for Veyon on Windows.
# Does not alter accounts, configuration, firewall, services or scheduled tasks.
# Windows PowerShell 5.1+
[CmdletBinding()]
param(
    [string]$TargetHost,
    [string]$TaskName = 'Corp-Veyon-AutoDeploy'
)

$ErrorActionPreference = 'Continue'
$cli = Join-Path $env:ProgramFiles 'Veyon\veyon-cli.exe'

Write-Host '=== Host identity ==='
Get-CimInstance Win32_ComputerSystem |
    Select-Object Name, Domain, PartOfDomain | Format-List

Write-Host '=== Local Veyon ==='
Write-Output "CLI installed: $(Test-Path -LiteralPath $cli)"
Get-Service VeyonService -ErrorAction SilentlyContinue |
    Select-Object Name, Status, StartType | Format-Table

if (Test-Path -LiteralPath $cli) {
    foreach ($key in @('UserGroups/Backend',
                       'UserGroups/UseDomainUserGroups',
                       'AccessControl/AccessRestrictedToUserGroups')) {
        Write-Host "Configuration: $key"
        & $cli config get $key 2>&1
    }
}

Write-Host '=== Deployment task (if present) ==='
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    $task | Select-Object TaskName, State,
      @{Name='RunAs';Expression={$_.Principal.UserId}} | Format-Table
    Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue |
        Select-Object LastRunTime, LastTaskResult, NextRunTime | Format-List
} else {
    Write-Output 'Task not present or not accessible.'
}

if ($TargetHost) {
    Write-Host "=== Target: $TargetHost ==="
    try {
        Resolve-DnsName -Name $TargetHost -ErrorAction Stop |
            Select-Object Name, Type, IPAddress, NameHost | Format-Table
    } catch { Write-Warning "DNS lookup failed: $($_.Exception.Message)" }
    try {
        Test-NetConnection -ComputerName $TargetHost -Port 11100 -InformationLevel Detailed |
            Select-Object ComputerName, RemoteAddress, RemotePort, TcpTestSucceeded |
            Format-List
    } catch { Write-Warning "TCP check failed: $($_.Exception.Message)" }
}

Write-Host 'Read-only diagnostics completed. Review identity and access rules on the target.'