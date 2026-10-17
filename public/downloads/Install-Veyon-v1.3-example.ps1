# PUBLIC EXAMPLE — NOT A DROP-IN PRODUCTION SCRIPT.
# Anonymized, adapted from the operator's reviewed Install-Veyon-v1.3.ps1.
# Deliberately uses invalid SHA256 placeholders and RFC 5737 documentation IPs.
# Before any test: review script, provide your OWN verified hashes and matching
# manifest.json, approved AD group, firewall allowlist, certificates, and OU scope.
# Do not deploy to domain controllers or servers. No warranty of fitness.
#Requires -Version 5.1
# Illustrative Veyon Service deployment, based on a reviewed v1.3 implementation, Windows 10/11 workstations only.
# Intended to run as LOCAL SYSTEM from a GPO scheduled task.
# No reboots, no Veyon Master, no changes to global firewall policy.
[CmdletBinding()]
param(
    [string]$Repository = '\\ad.example.com\NETLOGON\Software\Veyon',
    [switch]$WhatIfCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Version = '4.11.3.0'
$Expected = @{
    x64    = 'REPLACE_WITH_VERIFIED_X64_SHA256'
    x86    = 'REPLACE_WITH_VERIFIED_X86_SHA256'
    Config = 'REPLACE_WITH_VERIFIED_CONFIG_SHA256'
}
$DataDir = Join-Path $env:ProgramData 'Example\Veyon'
$CacheDir = Join-Path $DataDir 'Cache'
$LogPath = Join-Path $DataDir 'deploy.log'
$StatePath = Join-Path $DataDir 'deploy-state.json'
$RuleName = 'Example Veyon - Authorized Operators'
$TempBlockName = 'Example Veyon - Temporary Deployment Block'
$MutexName = 'Global\Example-Veyon-Deploy'
$Mutex = $null
$MutexAcquired = $false
$TemporaryBlockCreated = $false

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2} {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $env:COMPUTERNAME, $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    Write-Output $line
}

function Assert-Hash {
    param([string]$File, [string]$Sha256)
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { throw "Missing file: $File" }
    $actual = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actual -ne $Sha256.ToUpperInvariant()) { throw "SHA256 mismatch for $File : $actual" }
}

function Is-True {
    param([object]$Value)
    return ([string]$Value -match '^(true|1)$')
}

function Get-CliPath {
    foreach ($p in @("$env:ProgramFiles\Veyon\veyon-cli.exe", "${env:ProgramFiles(x86)}\Veyon\veyon-cli.exe")) {
        if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) { return $p }
    }
    return $null
}

function Get-InstalledVersion {
    $cli = Get-CliPath
    if (-not $cli) { return $null }
    $info = (Get-Item -LiteralPath $cli).VersionInfo
    foreach ($v in @($info.ProductVersion, $info.FileVersion)) {
        if ([string]$v -match '^(\d+\.\d+\.\d+)(?:\.(\d+))?') {
            if ($matches[2]) { return ('{0}.{1}' -f $matches[1], $matches[2]) }
            return ('{0}.0' -f $matches[1])
        }
    }
    throw "Existing Veyon binary has an unrecognized version: $cli"
}

function Assert-FirewallBaseline {
    $profiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore)
    if ($profiles.Count -eq 0) { throw 'Cannot read effective Windows Firewall profiles' }
    foreach ($p in $profiles) {
        if ($p.Enabled -ne $true -or [string]$p.DefaultInboundAction -eq 'Allow') {
            throw "Unsafe firewall baseline for $($p.Name): Enabled=$($p.Enabled), DefaultInbound=$($p.DefaultInboundAction)"
        }
    }
}

function Test-FirewallRule {
    param([string[]]$RemoteAddresses)
    $rules = @(Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue)
    if ($rules.Count -ne 1) { return $false }
    $r = $rules[0]
    if ([string]$r.Enabled -ne 'True' -or [string]$r.Direction -ne 'Inbound' -or [string]$r.Action -ne 'Allow') { return $false }
    $p = $r | Get-NetFirewallPortFilter
    if ([string]$p.Protocol -ne 'TCP' -or [string]$p.LocalPort -ne '11100') { return $false }
    # Windows Firewall returns /24 subnets as /255.255.255.0 on some systems.
    # Canonicalize both representations before comparing the pinned allowlist.
    $a = @((($r | Get-NetFirewallAddressFilter).RemoteAddress) | ForEach-Object { ([string]$_) -replace '/255\.255\.255\.0$', '/24' } | Sort-Object)
    $b = @($RemoteAddresses | ForEach-Object { ([string]$_) -replace '/255\.255\.255\.0$', '/24' } | Sort-Object)
    return (($a -join '|') -eq ($b -join '|'))
}

function Assert-VeyonConfig {
    param([object]$Config)
    if (-not (Is-True $Config.AccessControl.AccessRestrictedToUserGroups)) { throw 'AccessRestrictedToUserGroups must be true' }
    if (-not (Is-True $Config.UserGroups.UseDomainUserGroups)) { throw 'UseDomainUserGroups must be true' }
    if (-not ([string]$Config.Network.FirewallExceptionEnabled -match '^(false|0)$')) { throw 'Automatic firewall exception must be disabled' }
    if ([int]$Config.Network.VeyonServerPort -ne 11100) { throw 'Unexpected Veyon server port' }
    $groups = ConvertTo-Json -InputObject $Config.AccessControl.AuthorizedUserGroups -Compress -Depth 10
    if ($groups -notmatch 'GG-EXAMPLE-Veyon-Operators') { throw 'Expected AD operator group missing from Veyon configuration' }
    if ($null -ne $Config.PSObject.Properties['Core']) { throw 'Deployment configuration contains Core/InstallationID data' }
}

function Test-ConfiguredKeys {
    param([string]$Cli)
    if (-not $Cli) { return $false }

    # Veyon 4.11.3 can return an empty string for a valid VeyonServerPort key
    # through `config get`, even though `config export` contains port 11100.
    # Read the exported *effective* configuration rather than CLI get output.
    # Keep the full export in an ACL-restricted directory and delete it after reading.
    $privateDir = Join-Path $DataDir 'Private'
    $exportFile = Join-Path $privateDir ('effective-{0}.json' -f ([Guid]::NewGuid().ToString('N')))
    try {
        New-Item -ItemType Directory -Path $privateDir -Force | Out-Null
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sidText in @('S-1-5-18','S-1-5-32-544')) {
            $sid = New-Object System.Security.Principal.SecurityIdentifier($sidText)
            $inheritFlags = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
            $rule = New-Object -TypeName System.Security.AccessControl.FileSystemAccessRule -ArgumentList @(
                $sid,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                $inheritFlags,
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow
            )
            $acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $privateDir -AclObject $acl -ErrorAction Stop

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Cli
        $psi.Arguments = 'config export "' + $exportFile + '"'
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true

        $process = New-Object System.Diagnostics.Process
        try {
            $process.StartInfo = $psi
            if (-not $process.Start()) { throw 'Could not start veyon-cli config export' }
            $null = $process.StandardOutput.ReadToEnd()
            $stderrText = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            if ($process.ExitCode -ne 0) {
                throw "veyon-cli config export exit code $($process.ExitCode): $stderrText"
            }
        } finally {
            $process.Dispose()
        }

        if (-not (Test-Path -LiteralPath $exportFile -PathType Leaf)) {
            throw 'veyon-cli config export did not create output file'
        }
        $effective = Get-Content -LiteralPath $exportFile -Raw -Encoding UTF8 | ConvertFrom-Json

        $accessOK = Is-True $effective.AccessControl.AccessRestrictedToUserGroups
        $domainOK = Is-True $effective.UserGroups.UseDomainUserGroups
        $firewallOK = ([string]$effective.Network.FirewallExceptionEnabled -match '^(false|0)$')
        $portOK = ([string]$effective.Network.VeyonServerPort -eq '11100')
        $groups = @($effective.AccessControl.AuthorizedUserGroups)
        $groupOK = ($groups.Count -eq 1 -and [string]$groups[0] -eq 'GG-EXAMPLE-Veyon-Operators')

        $checkOK = $accessOK -and $domainOK -and $firewallOK -and $portOK -and $groupOK
        if (-not $checkOK) {
            Write-Log "Veyon effective configuration mismatch: access=$accessOK domain=$domainOK autoFirewallDisabled=$firewallOK port11100=$portOK operatorGroupOnly=$groupOK" 'WARN'
        }
        return [bool]$checkOK
    } catch {
        Write-Log "Veyon effective configuration verification error: $($_.Exception.Message)" 'WARN'
        return $false
    } finally {
        if (Test-Path -LiteralPath $exportFile -PathType Leaf) {
            Remove-Item -LiteralPath $exportFile -Force -ErrorAction SilentlyContinue
        }
    }
}

New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
try {
    $Mutex = New-Object System.Threading.Mutex($false, $MutexName)
    try { $MutexAcquired = $Mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $MutexAcquired = $true }
    if (-not $MutexAcquired) { Write-Log 'Another deployment instance is running; exit'; exit 0 }

    # Guard against accidental server / domain controller deployment.
    $os = Get-CimInstance Win32_OperatingSystem
    if ([int]$os.ProductType -ne 1) { Write-Log 'Skipped: Windows Server / Domain Controller is not supported' 'WARN'; exit 0 }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $WhatIfCheck -and $identity.User.Value -ne 'S-1-5-18') {
        throw 'Live deployment must be run by LOCAL SYSTEM (S-1-5-18)'
    }
    Assert-FirewallBaseline

    # Recover from a previous failed deployment: a temporary deny rule must
    # remain in place until this run has verified the final configuration.
    $existingBlocks = @(Get-NetFirewallRule -DisplayName $TempBlockName -ErrorAction SilentlyContinue)
    if ($existingBlocks.Count -gt 1) { throw 'Duplicate temporary Veyon block rules detected; inspect manually' }
    if ($existingBlocks.Count -eq 1) {
        $block = $existingBlocks[0]
        $blockPort = $block | Get-NetFirewallPortFilter
        if ([string]$block.Enabled -ne 'True' -or
            [string]$block.Direction -ne 'Inbound' -or
            [string]$block.Action -ne 'Block' -or
            [string]$blockPort.Protocol -ne 'TCP' -or
            [string]$blockPort.LocalPort -ne '11100') {
            throw 'Existing Veyon temporary block has unexpected properties; inspect manually'
        }
        $TemporaryBlockCreated = $true
        Write-Log 'Recovered temporary TCP/11100 block from prior deployment attempt'
    }

    $manifestFile = Join-Path $Repository 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestFile -PathType Leaf)) { throw "Manifest unavailable: $manifestFile" }
    $manifest = Get-Content -LiteralPath $manifestFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$manifest.Version -ne $Version) { throw "Unexpected manifest version: $($manifest.Version)" }
    foreach ($k in @('x64','x86')) {
        if ([string]$manifest.Packages.$k.SHA256 -ne $Expected[$k]) { throw "Manifest $k hash differs from pinned value" }
    }
    if ([string]$manifest.Config.SHA256 -ne $Expected.Config) { throw 'Manifest config hash differs from pinned value' }

    $arch = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
    $installerSource = Join-Path (Join-Path $Repository 'Packages') ([string]$manifest.Packages.$arch.File)
    $configSource = Join-Path (Join-Path $Repository 'Config') ([string]$manifest.Config.File)
    Assert-Hash $installerSource $Expected[$arch]
    Assert-Hash $configSource $Expected.Config

    $config = Get-Content -LiteralPath $configSource -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-VeyonConfig $config

    $allowed = @($manifest.Firewall.RemoteAddresses | ForEach-Object { [string]$_ })
    $pinnedAllowed = @('192.0.2.0/24','198.51.100.10')
    if ((@($allowed | Sort-Object) -join '|') -ne (@($pinnedAllowed | Sort-Object) -join '|')) { throw 'Unexpected firewall allowed-address list' }
    if ([int]$manifest.Firewall.Port -ne 11100 -or [string]$manifest.Firewall.Protocol -ne 'TCP') { throw 'Unexpected firewall protocol/port' }

    $installed = Get-InstalledVersion
    if ($installed -and $installed -ne $Version) {
        throw "Existing Veyon version $installed differs from target $Version; manual upgrade review needed"
    }

    $service = Get-Service -Name VeyonService -ErrorAction SilentlyContinue
    $stateTag = "version=$Version;arch=$arch;config=$($Expected.Config);installer=$($Expected[$arch])"
    $stamp = if (Test-Path -LiteralPath $StatePath) { Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 } else { '' }
    $stateGood = -not $TemporaryBlockCreated -and $installed -eq $Version -and $service -and $service.Status -eq 'Running' -and
        $stamp.Trim() -eq $stateTag -and (Test-FirewallRule $allowed) -and (Test-ConfiguredKeys (Get-CliPath))
    if ($stateGood) { Write-Log 'Already current; configuration, service and firewall checks OK'; exit 0 }

    $serviceStatus = if ($service) { [string]$service.Status } else { 'Missing' }
    Write-Log "Candidate: arch=$arch installed=$installed target=$Version service=$serviceStatus"
    if ($WhatIfCheck) { Write-Log 'CHECK ONLY: no installation, import, service restart or firewall changes'; exit 0 }

    $installerLocal = Join-Path $CacheDir ([IO.Path]::GetFileName($installerSource))
    $configLocal = Join-Path $CacheDir ([IO.Path]::GetFileName($configSource))
    Copy-Item -LiteralPath $installerSource -Destination $installerLocal -Force -ErrorAction Stop
    Copy-Item -LiteralPath $configSource -Destination $configLocal -Force -ErrorAction Stop
    Assert-Hash $installerLocal $Expected[$arch]
    Assert-Hash $configLocal $Expected.Config

    $sign = Get-AuthenticodeSignature -LiteralPath $installerLocal
    if ($sign.Status -ne 'Valid' -or -not $sign.SignerCertificate -or
        $sign.SignerCertificate.Subject -notmatch 'CN=Veyon Solutions') {
        throw "Invalid Veyon installer signature: $($sign.Status)"
    }

    if ($installed -ne $Version) {
        if (-not $TemporaryBlockCreated) {
            New-NetFirewallRule -DisplayName $TempBlockName -Direction Inbound -Action Block -Profile Any -Protocol TCP -LocalPort 11100 -Enabled True | Out-Null
            $TemporaryBlockCreated = $true
            Write-Log 'Temporary TCP/11100 block enabled for fresh installation'
        }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $installerLocal
        $psi.Arguments = '/S /NoMaster'
        $psi.WorkingDirectory = $CacheDir
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true

        Write-Log 'Starting Veyon installer via ProcessStartInfo (UseShellExecute=false)'

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi

        try {
            if (-not $process.Start()) {
                throw 'Veyon installer process could not be started'
            }

            Write-Log "Veyon installer started: PID=$($process.Id)"

            if (-not $process.WaitForExit(600000)) {
                Write-Log 'Veyon installer timeout after 600 seconds' 'ERROR'
                try {
                    $process.Kill()
                    $process.WaitForExit(15000) | Out-Null
                } catch {
                    Write-Log "Unable to terminate installer: $($_.Exception.Message)" 'WARN'
                }
                throw 'Veyon installer execution timeout'
            }

            $exitCode = $process.ExitCode

            if ($exitCode -ne 0) {
                throw "Installer exit code: $exitCode"
            }

            Write-Log 'Veyon installer exited with code 0'
        }
        finally {
            $process.Dispose()
        }
    }

    $cli = Get-CliPath
    if (-not $cli) { throw 'veyon-cli.exe missing after installation' }
    # Import also normalizes a prior local installation to the curated config.
    & $cli config import $configLocal | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Veyon config import failed: $LASTEXITCODE" }

    # Disable only other Veyon-related *inbound allow* rules. Never change unrelated rules.
    $otherVeyonAllow = @(Get-NetFirewallRule | Where-Object {
        $_.DisplayName -match 'Veyon' -and $_.DisplayName -ne $RuleName -and $_.DisplayName -ne $TempBlockName -and
        [string]$_.Direction -eq 'Inbound' -and [string]$_.Action -eq 'Allow' -and [string]$_.Enabled -eq 'True'
    })
    foreach ($r in $otherVeyonAllow) {
        Disable-NetFirewallRule -Name $r.Name -ErrorAction Stop
        Write-Log "Disabled broad Veyon allow rule: $($r.DisplayName)"
    }

    $existing = @(Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 1) { throw "Duplicate firewall rules named '$RuleName'" }
    if ($existing.Count -eq 0) {
        New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -Action Allow -Enabled True -Profile Any -Protocol TCP -LocalPort 11100 -RemoteAddress $allowed | Out-Null
        Write-Log 'Created restricted TCP/11100 firewall rule'
    } else {
        $r = $existing[0]
        Set-NetFirewallRule -Name $r.Name -Enabled True -Direction Inbound -Action Allow -Profile Any
        $r | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -RemoteAddress $allowed
        $r | Get-NetFirewallPortFilter | Set-NetFirewallPortFilter -Protocol TCP -LocalPort 11100
        Write-Log 'Updated restricted TCP/11100 firewall rule'
    }
    if (-not (Test-FirewallRule $allowed)) { throw 'Firewall verification failed' }

    Set-Service -Name VeyonService -StartupType Automatic -ErrorAction Stop
    Restart-Service -Name VeyonService -Force -ErrorAction Stop
    $running = Get-Service -Name VeyonService
    $running.WaitForStatus('Running', [TimeSpan]::FromSeconds(35))
    if (-not (Test-ConfiguredKeys $cli)) { throw 'Effective Veyon configuration check failed' }
    if ((Get-InstalledVersion) -ne $Version) { throw 'Installed Veyon version mismatch' }

    if ($TemporaryBlockCreated) {
        Get-NetFirewallRule -DisplayName $TempBlockName -ErrorAction Stop | Remove-NetFirewallRule -ErrorAction Stop
        $TemporaryBlockCreated = $false
        Write-Log 'Temporary deployment block removed'
    }

    Set-Content -LiteralPath $StatePath -Value $stateTag -Encoding UTF8
    Write-Log 'SUCCESS: Veyon Service installation/configuration complete'
} catch {
    Write-Log "FAILED: $($_.Exception.Message)" 'ERROR'
    if ($TemporaryBlockCreated) { Write-Log 'Temporary TCP/11100 block intentionally retained after failure' 'WARN' }
    exit 1
} finally {
    if ($MutexAcquired -and $Mutex) { $Mutex.ReleaseMutex() | Out-Null }
    if ($Mutex) { $Mutex.Dispose() }
}