function New-OfflineRemoveBundle {
    <#
    .SYNOPSIS
        Generates a self-contained script for offline Defender removal from WinRE
        or a secondary Windows installation.
    .DESCRIPTION
        Creates Invoke-OfflineDefenderRemove.ps1 in the specified output directory.
        The generated script loads registry hives from an offline Windows volume,
        applies policy keys, disables services, and removes SafeBoot entries --
        all without requiring Tamper Protection to be off. The script refuses to
        run against the live system root.

        Operations that require a live OS (Set-MpPreference, scheduled tasks,
        Appx removal, DISM package removal) are not included. After booting the
        target volume, run DisableDefender -Mode Health to verify and complete
        remaining steps. The generated script writes versioned transaction,
        baseline, and result JSON beside itself. Pass -RecoveryAction Rollback
        with a baseline path to replay the captured offline baseline.
    .PARAMETER OutputDirectory
        Directory where the generated script is written. Defaults to the current
        directory.
    .PARAMETER Force
        Preserve an explicit caller choice to include -Force in the generated
        live-completion command. Force is never added implicitly.
    .EXAMPLE
        New-OfflineRemoveBundle -OutputDirectory C:\OfflineBundle
    .EXAMPLE
        New-OfflineRemoveBundle | Select-Object -ExpandProperty ScriptPath
    #>
    [CmdletBinding()]
    param(
        [string]$OutputDirectory = '.',
        [switch]$Force
    )

    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }

    $outputPath = Join-Path (Resolve-Path -LiteralPath $OutputDirectory).Path 'Invoke-OfflineDefenderRemove.ps1'
    $generatedDate = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

    $scriptContent = @'
#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
    DisableDefender Offline Remove __VERSION__
    Generated __DATE__ by New-OfflineRemoveBundle

    Removes Microsoft Defender from an offline Windows volume by editing its
    registry hives directly. Bypasses live Tamper Protection because the
    Defender driver (WdFilter) is not loaded on the offline volume.

    Usage from WinRE or a secondary Windows install:
      .\Invoke-OfflineDefenderRemove.ps1 -TargetVolume D:\
      .\Invoke-OfflineDefenderRemove.ps1 -TargetVolume D:\ -RecoveryAction Rollback `
          -BaselinePath .\offline-remove.<transaction-id>.baseline.json

    DOES NOT touch the Windows Firewall. Firewall services and policy paths
    are on a hard refuse-list.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, HelpMessage = 'Root of the offline Windows volume (e.g. D:\)')]
    [string]$TargetVolume,

    [switch]$IncludeMDE,

    [ValidateSet('Apply','Rollback')]
    [string]$RecoveryAction = 'Apply',

    [string]$BaselinePath,

    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
$script:Version = '__VERSION__'
$script:HiveMountSoftware = 'DD_OFFLINE_SOFTWARE'
$script:HiveMountSystem   = 'DD_OFFLINE_SYSTEM'
$script:SoftwareHiveMounted = $false
$script:SystemHiveMounted   = $false
$script:ActionCount = 0
$script:ErrorCount  = 0
$script:ControlSet  = $null
$script:TransactionSchemaVersion = 1
$script:BaselineSchemaVersion = 1
$script:ResultSchemaVersion = 1
$script:TransactionId = [guid]::NewGuid().ToString()
$script:ArtifactDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:TransactionPath = Join-Path $script:ArtifactDirectory `
    "offline-remove.$($script:TransactionId).transaction.json"
$script:BaselineArtifactPath = Join-Path $script:ArtifactDirectory `
    "offline-remove.$($script:TransactionId).baseline.json"
$script:ResultPath = Join-Path $script:ArtifactDirectory `
    "offline-remove.$($script:TransactionId).result.json"
$script:Baseline = $null
$script:Transaction = $null

# ---------------------------------------------------------------------------
# Inline configuration (self-contained, no module dependency)
# ---------------------------------------------------------------------------
$script:DefenderServices = @(
    'WinDefend','WdFilter','WdBoot','WdNisDrv','WdNisSvc',
    'MDCoreSvc','MDDlpSvc','MsSecFlt','MsSecCore',
    'SgrmAgent','SgrmBroker','SecurityHealthService','wscsvc',
    'webthreat','webthreatdefsvc','webthreatdefusersvc'
)

$script:MDEServices = @('Sense')

$script:RefuseTouchServices = @(
    'mpssvc','BFE','SharedAccess','MpsDrv','mpsdrv','MsSecWfp',
    'IKEEXT','PolicyAgent','Dnscache','Dhcp','Wlansvc','NetSetupSvc'
)

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Write-OfflineLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK','DEBUG')][string]$Level = 'INFO'
    )
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line  = "[$stamp] [$Level] $Message"
    if ($script:LogTarget) {
        try { Add-Content -LiteralPath $script:LogTarget -Value $line -ErrorAction Stop } catch {}
    }
    $color = switch ($Level) {
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'DEBUG' { 'DarkGray' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
}

# ---------------------------------------------------------------------------
# Transaction, baseline, and result artifacts
# ---------------------------------------------------------------------------
function Write-OfflineJsonArtifact {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$InputObject,
        [ValidateRange(2, 32)][int]$Depth = 16
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        throw "Artifact directory does not exist: $directory"
    }
    $json = $InputObject | ConvertTo-Json -Depth $Depth
    $temporaryPath = Join-Path $directory (
        '.{0}.{1:N}.tmp' -f [System.IO.Path]::GetFileName($Path), [guid]::NewGuid())
    try {
        [System.IO.File]::WriteAllText(
            $temporaryPath,
            $json,
            (New-Object System.Text.UTF8Encoding($false)))
        if ([System.IO.File]::Exists($Path)) {
            [System.IO.File]::Replace($temporaryPath, $Path, $null, $true)
        } else {
            [System.IO.File]::Move($temporaryPath, $Path)
        }
    } finally {
        if ([System.IO.File]::Exists($temporaryPath)) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Read-OfflineJsonArtifact {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [ValidateRange(1, 16777216)][int]$MaximumBytes = 16777216
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.Length -gt $MaximumBytes) {
        throw "$Name artifact exceeds the $MaximumBytes byte limit: $Path"
    }
    $document = Get-Content -Raw -LiteralPath $Path -ErrorAction Stop |
        ConvertFrom-Json -ErrorAction Stop
    if ([int]$document.SchemaVersion -ne 1) {
        throw "$Name artifact has unsupported schema $($document.SchemaVersion)."
    }
    return $document
}

function Get-OfflineCanonicalTarget {
    $candidate = $TargetVolume.TrimEnd('/')
    $resolved = Resolve-Path -LiteralPath $candidate -ErrorAction SilentlyContinue
    if ($resolved) { return $resolved.Path.TrimEnd('\') }
    return [System.IO.Path]::GetFullPath($candidate).TrimEnd('\')
}

function Save-OfflineTransaction {
    if ($null -eq $script:Transaction) { return }
    $script:Transaction['Updated'] = (Get-Date).ToString('o')
    Write-OfflineJsonArtifact -Path $script:TransactionPath `
        -InputObject $script:Transaction -Depth 16
}

function Save-OfflineBaseline {
    if ($null -eq $script:Baseline) { return }
    Write-OfflineJsonArtifact -Path $script:BaselineArtifactPath `
        -InputObject $script:Baseline -Depth 20
}

function Initialize-OfflineTransaction {
    $now = (Get-Date).ToString('o')
    $script:Transaction = [ordered]@{
        SchemaVersion = $script:TransactionSchemaVersion
        TransactionId = $script:TransactionId
        Status = 'Created'
        RecoveryAction = $RecoveryAction
        TargetVolume = Get-OfflineCanonicalTarget
        Started = $now
        Updated = $now
        BaselinePath = $script:BaselineArtifactPath
        ResultPath = $script:ResultPath
        Mounts = [ordered]@{
            Software = [ordered]@{
                MountName = $script:HiveMountSoftware
                Loaded = $false
                Unloaded = $false
                UnloadAttempts = 0
                Events = @()
            }
            System = [ordered]@{
                MountName = $script:HiveMountSystem
                Loaded = $false
                Unloaded = $false
                UnloadAttempts = 0
                Events = @()
            }
        }
        Mutations = @()
        Errors = @()
    }
    Save-OfflineTransaction
}

function Initialize-OfflineBaseline {
    $script:Baseline = [ordered]@{
        SchemaVersion = $script:BaselineSchemaVersion
        TransactionId = $script:TransactionId
        TargetVolume = Get-OfflineCanonicalTarget
        Created = (Get-Date).ToString('o')
        Entries = @()
    }
    Save-OfflineBaseline
}

function Add-OfflineTransactionError {
    param([Parameter(Mandatory)][string]$Message)

    if ($null -eq $script:Transaction) { return }
    $script:Transaction['Errors'] += @($Message)
    try { Save-OfflineTransaction } catch {}
}

function Add-OfflineMountEvent {
    param(
        [Parameter(Mandatory)][ValidateSet('Software','System')][string]$Hive,
        [Parameter(Mandatory)][string]$Event,
        [switch]$Loaded,
        [switch]$Unloaded,
        [switch]$ClearLoaded
    )

    if ($null -eq $script:Transaction) { return }
    $mount = $script:Transaction['Mounts'][$Hive]
    $mount['Events'] += @([ordered]@{
        Event = $Event
        At = (Get-Date).ToString('o')
    })
    if ($Loaded) { $mount['Loaded'] = $true }
    if ($ClearLoaded) { $mount['Loaded'] = $false }
    if ($Unloaded) { $mount['Unloaded'] = $true }
    Save-OfflineTransaction
}

function Add-OfflineMutationJournal {
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Path,
        [string]$Name,
        $Before,
        $After,
        [ValidateSet('Prepared','Applied','Failed','RolledBack')]
        [string]$Status = 'Prepared',
        [string]$ErrorMessage
    )

    $entry = [ordered]@{
        Sequence = @($script:Transaction['Mutations']).Count + 1
        Kind = $Kind
        Path = $Path
        Name = $Name
        Status = $Status
        Started = (Get-Date).ToString('o')
        Completed = $null
        Before = $Before
        After = $After
        Error = $ErrorMessage
    }
    $script:Transaction['Mutations'] += @($entry)
    Save-OfflineTransaction
    return $entry
}

function Close-OfflineRegistryKey {
    param($Key)

    if ($null -eq $Key) { return }
    try {
        if ($Key.PSObject.Methods.Name -contains 'Close') {
            $Key.Close()
        } elseif ($Key.PSObject.Methods.Name -contains 'Dispose') {
            $Key.Dispose()
        }
    } catch {}
}

function Get-OfflineRegistryValueSnapshot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [string]$Type = 'DWord'
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return [ordered]@{
            Kind = 'Value'
            Path = $Path
            Name = $Name
            KeyExists = $false
            Exists = $false
            Type = $Type
            Value = $null
        }
    }

    $key = $null
    try {
        $key = Get-Item -LiteralPath $Path -ErrorAction Stop
        $names = @($key.GetValueNames())
        $exists = $names -contains $Name
        $kind = if ($exists) { [string]$key.GetValueKind($Name) } else { $Type }
        $value = if ($exists) {
            $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        } else { $null }
        return [ordered]@{
            Kind = 'Value'
            Path = $Path
            Name = $Name
            KeyExists = $true
            Exists = $exists
            Type = $kind
            Value = $value
        }
    } finally {
        Close-OfflineRegistryKey -Key $key
    }
}

function Test-OfflineRegistryValueSnapshot {
    param(
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)]$Actual
    )

    if ([bool]$Expected.Exists -ne [bool]$Actual.Exists) { return $false }
    if (-not $Expected.Exists) { return $true }
    if ([string]$Expected.Type -ne [string]$Actual.Type) { return $false }
    $expectedValue = if ($null -eq $Expected.Value) { '<null>' } else {
        $Expected.Value | ConvertTo-Json -Depth 12 -Compress
    }
    $actualValue = if ($null -eq $Actual.Value) { '<null>' } else {
        $Actual.Value | ConvertTo-Json -Depth 12 -Compress
    }
    return [string]$expectedValue -eq [string]$actualValue
}

function Ensure-OfflineValueBaseline {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Type
    )

    $existing = @($script:Baseline['Entries'] | Where-Object {
        $_.Kind -eq 'Value' -and $_.Path -eq $Path -and $_.Name -eq $Name
    })
    if ($existing.Count -gt 0) { return $existing[0] }

    $entry = Get-OfflineRegistryValueSnapshot -Path $Path -Name $Name -Type $Type
    $script:Baseline['Entries'] += @($entry)
    Save-OfflineBaseline
    return $entry
}

function Get-OfflineRegistryTreeSnapshot {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [ordered]@{
            Kind = 'Tree'
            Path = $Path
            Exists = $false
            Values = @()
            Children = @()
        }
    }

    $key = $null
    try {
        $key = Get-Item -LiteralPath $Path -ErrorAction Stop
        $values = @(
            $key.GetValueNames() | ForEach-Object {
                Get-OfflineRegistryValueSnapshot -Path $Path -Name $_ -Type 'String'
            }
        )
        $children = @(
            Get-ChildItem -LiteralPath $Path -ErrorAction Stop | ForEach-Object {
                Get-OfflineRegistryTreeSnapshot -Path $_.PSPath
            }
        )
        return [ordered]@{
            Kind = 'Tree'
            Path = $Path
            Exists = $true
            Values = @($values)
            Children = @($children)
        }
    } finally {
        Close-OfflineRegistryKey -Key $key
    }
}

function Ensure-OfflineTreeBaseline {
    param([Parameter(Mandatory)][string]$Path)

    $existing = @($script:Baseline['Entries'] | Where-Object {
        $_.Kind -eq 'Tree' -and $_.Path -eq $Path
    })
    if ($existing.Count -gt 0) { return $existing[0] }

    $entry = Get-OfflineRegistryTreeSnapshot -Path $Path
    $script:Baseline['Entries'] += @($entry)
    Save-OfflineBaseline
    return $entry
}

# ---------------------------------------------------------------------------
# Target volume validation
# ---------------------------------------------------------------------------
function Assert-OfflineVolume {
    $target = $TargetVolume.TrimEnd('\/')
    $liveRoot = $env:SystemDrive

    if ($target -eq $liveRoot -or
        "$target\" -eq "$liveRoot\" -or
        (Resolve-Path -LiteralPath $target -ErrorAction SilentlyContinue).Path -eq
        (Resolve-Path -LiteralPath $liveRoot -ErrorAction SilentlyContinue).Path) {
        throw "Refused: $target is the live system drive ($liveRoot). This script targets offline volumes only."
    }

    $windir = Join-Path $target 'Windows'
    if (-not (Test-Path -LiteralPath $windir -PathType Container)) {
        throw "No Windows directory found at $windir. Verify the target volume."
    }

    $configDir = Join-Path $windir 'System32\config'
    foreach ($hive in @('SOFTWARE','SYSTEM')) {
        $hivePath = Join-Path $configDir $hive
        if (-not (Test-Path -LiteralPath $hivePath)) {
            throw "Registry hive not found: $hivePath"
        }
    }

    Write-OfflineLog "Target volume validated: $target" OK
}

# ---------------------------------------------------------------------------
# Registry hive mount / dismount
# ---------------------------------------------------------------------------
function Mount-OfflineHives {
    $target = $TargetVolume.TrimEnd('\/')
    $configDir = Join-Path $target 'Windows\System32\config'

    foreach ($existingMount in @($script:HiveMountSoftware, $script:HiveMountSystem)) {
        if (Test-Path -LiteralPath "Registry::HKEY_USERS\$existingMount") {
            throw "Registry mount point HKU\$existingMount already exists. Dismount it first or use a different session."
        }
    }

    $softwarePath = Join-Path $configDir 'SOFTWARE'
    $systemPath   = Join-Path $configDir 'SYSTEM'

    Add-OfflineMountEvent -Hive Software -Event 'LoadStarted'
    Write-OfflineLog "Loading SOFTWARE hive from $softwarePath ..." INFO
    $result = reg.exe load "HKU\$($script:HiveMountSoftware)" "$softwarePath" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to load SOFTWARE hive: $result"
    }
    $script:SoftwareHiveMounted = $true
    Add-OfflineMountEvent -Hive Software -Event 'Loaded' -Loaded
    Write-OfflineLog "SOFTWARE hive loaded as HKU\$($script:HiveMountSoftware)" OK

    Add-OfflineMountEvent -Hive System -Event 'LoadStarted'
    Write-OfflineLog "Loading SYSTEM hive from $systemPath ..." INFO
    $result = reg.exe load "HKU\$($script:HiveMountSystem)" "$systemPath" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to load SYSTEM hive: $result"
    }
    $script:SystemHiveMounted = $true
    Add-OfflineMountEvent -Hive System -Event 'Loaded' -Loaded
    Write-OfflineLog "SYSTEM hive loaded as HKU\$($script:HiveMountSystem)" OK

    $selectPath = "Registry::HKEY_USERS\$($script:HiveMountSystem)\Select"
    if (-not (Test-Path -LiteralPath $selectPath)) {
        throw "SYSTEM hive has no Select key -- cannot determine the current ControlSet."
    }
    $current = (Get-ItemProperty -LiteralPath $selectPath -Name 'Current' -ErrorAction Stop).Current
    $script:ControlSet = 'ControlSet{0:D3}' -f [int]$current
    Write-OfflineLog "Active ControlSet: $($script:ControlSet)" INFO
}

function Test-OfflineHiveMounted {
    param([Parameter(Mandatory)][ValidateSet('Software','System')][string]$Hive)

    $mountName = if ($Hive -eq 'Software') {
        $script:HiveMountSoftware
    } else {
        $script:HiveMountSystem
    }
    try {
        return [bool](Test-Path -LiteralPath "Registry::HKEY_USERS\$mountName")
    } catch {
        return $true
    }
}

function Invoke-OfflineHiveUnload {
    param([Parameter(Mandatory)][ValidateSet('Software','System')][string]$Hive)

    $mountName = if ($Hive -eq 'Software') {
        $script:HiveMountSoftware
    } else {
        $script:HiveMountSystem
    }
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        if (-not (Test-OfflineHiveMounted -Hive $Hive)) {
            if ($Hive -eq 'Software') { $script:SoftwareHiveMounted = $false }
            if ($Hive -eq 'System') { $script:SystemHiveMounted = $false }
            Add-OfflineMountEvent -Hive $Hive -Event 'AlreadyUnloaded' -ClearLoaded -Unloaded
            $message = "Refused firewall/network service path: $Path"
            Add-OfflineTransactionError -Message $message
            throw $message
        }

        [gc]::Collect()
        [gc]::WaitForPendingFinalizers()
        Start-Sleep -Milliseconds (250 * $attempt)
        $script:Transaction['Mounts'][$Hive]['UnloadAttempts'] = $attempt
        Add-OfflineMountEvent -Hive $Hive -Event "UnloadAttempt$attempt"
        $result = reg.exe unload "HKU\$mountName" 2>&1
        $exitCode = $LASTEXITCODE
        $stillMounted = Test-OfflineHiveMounted -Hive $Hive
        $script:Transaction['Mounts'][$Hive]['LastUnload'] = [ordered]@{
            Attempt = $attempt
            ExitCode = $exitCode
            StillMounted = $stillMounted
            Output = @($result)
        }
        Save-OfflineTransaction
        if ($exitCode -eq 0 -and -not $stillMounted) {
            if ($Hive -eq 'Software') { $script:SoftwareHiveMounted = $false }
            if ($Hive -eq 'System') { $script:SystemHiveMounted = $false }
            Add-OfflineMountEvent -Hive $Hive -Event 'Unloaded' -ClearLoaded -Unloaded
            Write-OfflineLog "$Hive hive unloaded after attempt $attempt." OK
            return
        }
        Write-OfflineLog "Could not unload $Hive hive on attempt ${attempt}: $result" WARN
    }

    throw "$Hive hive remained mounted after five unload attempts; close all registry handles and retry."
}

function Dismount-OfflineHives {
    $failures = New-Object System.Collections.ArrayList
    foreach ($hive in @('System','Software')) {
        $isFlagged = if ($hive -eq 'System') { $script:SystemHiveMounted } else { $script:SoftwareHiveMounted }
        $journalLoaded = [bool]$script:Transaction['Mounts'][$hive]['Loaded']
        if (-not $isFlagged -and -not $journalLoaded) { continue }
        try {
            Invoke-OfflineHiveUnload -Hive $hive
        } catch {
            [void]$failures.Add($_.Exception.Message)
            Add-OfflineTransactionError -Message $_.Exception.Message
        }
    }
    $residual = @('System','Software') | Where-Object { Test-OfflineHiveMounted -Hive $_ }
    if ($residual.Count -gt 0) {
        $message = "Residual offline registry mounts: $($residual -join ', ')"
        [void]$failures.Add($message)
        Add-OfflineTransactionError -Message $message
    }
    if ($failures.Count -gt 0) {
        throw ($failures -join ' | ')
    }
}

# ---------------------------------------------------------------------------
# Offline registry helpers
# ---------------------------------------------------------------------------
function Get-OfflineSoftwarePath {
    param([Parameter(Mandatory)][string]$SubPath)
    return "Registry::HKEY_USERS\$($script:HiveMountSoftware)\$SubPath"
}

function Get-OfflineSystemPath {
    param([Parameter(Mandatory)][string]$SubPath)
    return "Registry::HKEY_USERS\$($script:HiveMountSystem)\$($script:ControlSet)\$SubPath"
}

function Set-OfflineRegValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [ValidateSet('DWord','QWord','String','ExpandString','MultiString','Binary')]
        [string]$Type = 'DWord'
    )

    if ($Path -match '(?i)\\Services\\(mpssvc|BFE|SharedAccess|MpsDrv|mpsdrv|MsSecWfp|IKEEXT|PolicyAgent|Dnscache|Dhcp|Wlansvc|NetSetupSvc)(?:\\|$)') {
        $message = "Refused firewall/network service path: $Path"
        Add-OfflineTransactionError -Message $message
        throw $message
    }

    foreach ($refused in $script:RefuseTouchServices) {
        if ($Path -like "*\Services\$refused*") {
            Write-OfflineLog "REFUSED firewall/network service path: $Path" ERROR
            return
        }
    }
    if ($Path -like '*\WindowsFirewall*' -or $Path -like '*\SharedAccess\Parameters\FirewallPolicy*') {
        Write-OfflineLog "REFUSED firewall policy path: $Path" ERROR
        $message = "Refused firewall policy path: $Path"
        Add-OfflineTransactionError -Message $message
        throw $message
    }

    $baselineEntry = Ensure-OfflineValueBaseline -Path $Path -Name $Name -Type $Type
    $mutation = Add-OfflineMutationJournal -Kind 'Value' -Path $Path `
        -Name $Name -Before $baselineEntry
    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -Path $Path -Force | Out-Null
        }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        $after = Get-OfflineRegistryValueSnapshot -Path $Path -Name $Name -Type $Type
        if (-not (Test-OfflineRegistryValueSnapshot -Expected ([ordered]@{
                    Exists = $true
                    Type = $Type
                    Value = $Value
                }) -Actual $after)) {
            throw "Value did not verify after write: $Path\$Name"
        }
        $script:ActionCount++
        $mutation['Status'] = 'Applied'
        $mutation['Completed'] = (Get-Date).ToString('o')
        $mutation['After'] = $after
        Save-OfflineTransaction
        Write-OfflineLog "Set $Path\$Name = $Value ($Type)" DEBUG
    } catch {
        $script:ErrorCount++
        $mutation['Status'] = 'Failed'
        $mutation['Completed'] = (Get-Date).ToString('o')
        $mutation['Error'] = $_.Exception.Message
        Save-OfflineTransaction
        Write-OfflineLog "Failed to set ${Path}\${Name}: $($_.Exception.Message)" ERROR
        throw
    }
}

# ---------------------------------------------------------------------------
# Phase: Defender policy keys (offline SOFTWARE hive)
# ---------------------------------------------------------------------------
function Set-OfflineDefenderPolicy {
    Write-OfflineLog 'Writing Defender policy keys to offline SOFTWARE hive ...' INFO

    $policyRoot    = Get-OfflineSoftwarePath 'Policies\Microsoft\Windows Defender'
    $realTimeRoot  = Get-OfflineSoftwarePath 'Policies\Microsoft\Windows Defender\Real-Time Protection'
    $spynetRoot    = Get-OfflineSoftwarePath 'Policies\Microsoft\Windows Defender\Spynet'
    $mpEngineRoot  = Get-OfflineSoftwarePath 'Policies\Microsoft\Windows Defender\MpEngine'
    $nisRoot       = Get-OfflineSoftwarePath 'Policies\Microsoft\Windows Defender\NIS'
    $nisIPSRoot    = Get-OfflineSoftwarePath 'Policies\Microsoft\Windows Defender\NIS\Consumers\IPS'
    $signatureRoot = Get-OfflineSoftwarePath 'Policies\Microsoft\Windows Defender\Signature Updates'
    $scanRoot      = Get-OfflineSoftwarePath 'Policies\Microsoft\Windows Defender\Scan'
    $uxRoot        = Get-OfflineSoftwarePath 'Policies\Microsoft\Windows Defender\UX Configuration'
    $reportingRoot = Get-OfflineSoftwarePath 'Policies\Microsoft\Windows Defender\Reporting'
    $atpRoot       = Get-OfflineSoftwarePath 'Policies\Microsoft\Windows Advanced Threat Protection'
    $mrtRoot       = Get-OfflineSoftwarePath 'Policies\Microsoft\MRT'
    $smartScreen   = Get-OfflineSoftwarePath 'Policies\Microsoft\Windows\System'
    $msAntimalware = Get-OfflineSoftwarePath 'Policies\Microsoft\Microsoft Antimalware'

    Set-OfflineRegValue $policyRoot 'DisableAntiSpyware'            1
    Set-OfflineRegValue $policyRoot 'DisableAntiVirus'              1
    Set-OfflineRegValue $policyRoot 'DisableRoutinelyTakingAction'  1
    Set-OfflineRegValue $policyRoot 'DisableSpecialRunningModes'    1
    Set-OfflineRegValue $policyRoot 'ServiceKeepAlive'              0
    Set-OfflineRegValue $policyRoot 'AllowFastServiceStartup'       0
    Set-OfflineRegValue $policyRoot 'DisableLocalAdminMerge'        1
    Set-OfflineRegValue $policyRoot 'PUAProtection'                 0

    Set-OfflineRegValue $realTimeRoot 'DisableRealtimeMonitoring'                       1
    Set-OfflineRegValue $realTimeRoot 'DisableBehaviorMonitoring'                       1
    Set-OfflineRegValue $realTimeRoot 'DisableOnAccessProtection'                       1
    Set-OfflineRegValue $realTimeRoot 'DisableScanOnRealtimeEnable'                     1
    Set-OfflineRegValue $realTimeRoot 'DisableIOAVProtection'                           1
    Set-OfflineRegValue $realTimeRoot 'DisableRawWriteNotification'                     1
    Set-OfflineRegValue $realTimeRoot 'DisableIntrusionPreventionSystem'                1
    Set-OfflineRegValue $realTimeRoot 'DisableInformationProtectionControl'             1
    Set-OfflineRegValue $realTimeRoot 'LocalSettingOverrideDisableRealtimeMonitoring'   1

    Set-OfflineRegValue $spynetRoot 'SpyNetReporting'                                  0
    Set-OfflineRegValue $spynetRoot 'SubmitSamplesConsent'                              2
    Set-OfflineRegValue $spynetRoot 'DisableBlockAtFirstSeen'                           1
    Set-OfflineRegValue $spynetRoot 'LocalSettingOverrideSpynetReporting'               0

    Set-OfflineRegValue $mpEngineRoot 'MpEnablePus'                0
    Set-OfflineRegValue $mpEngineRoot 'EnableFileHashComputation'   0
    Set-OfflineRegValue $mpEngineRoot 'MpCloudBlockLevel'           0
    Set-OfflineRegValue $mpEngineRoot 'MpBafsExtendedTimeout'       0

    Set-OfflineRegValue $nisRoot    'DisableProtocolRecognition'    1
    Set-OfflineRegValue $nisIPSRoot 'DisableSignatureRetirement'    1
    Set-OfflineRegValue $nisIPSRoot 'ThrottleDetectionEventsRate'   10000000

    Set-OfflineRegValue $signatureRoot 'ForceUpdateFromMU'                             0
    Set-OfflineRegValue $signatureRoot 'DisableScheduledSignatureUpdateOnBattery'       1
    Set-OfflineRegValue $signatureRoot 'RealtimeSignatureDelivery'                      0
    Set-OfflineRegValue $signatureRoot 'DisableUpdateOnStartupWithoutEngine'            1

    Set-OfflineRegValue $scanRoot 'DisableRemovableDriveScanning'                      1
    Set-OfflineRegValue $scanRoot 'DisableArchiveScanning'                              1
    Set-OfflineRegValue $scanRoot 'DisableScanningMappedNetworkDrivesForFullScan'       1
    Set-OfflineRegValue $scanRoot 'DisableScanningNetworkFiles'                         1

    Set-OfflineRegValue $uxRoot 'Notification_Suppress' 1
    Set-OfflineRegValue $reportingRoot 'DisableEnhancedNotifications' 1
    Set-OfflineRegValue $atpRoot 'ForceDefenderPassiveMode' 1
    Set-OfflineRegValue $smartScreen 'EnableSmartScreen' 0
    Set-OfflineRegValue $mrtRoot 'DontOfferThroughWUAU' 1
    Set-OfflineRegValue $mrtRoot 'DontReportInfectionInformation' 1
    Set-OfflineRegValue $msAntimalware 'ServiceKeepAlive' 0

    $bfpRoot = Get-OfflineSoftwarePath 'Policies\Microsoft\Windows Defender\Features\BehavioralNetworkBlocks\BruteForceProtection'
    $repRoot = Get-OfflineSoftwarePath 'Policies\Microsoft\Windows Defender\Features\BehavioralNetworkBlocks\RemoteEncryptionProtection'
    Set-OfflineRegValue $bfpRoot 'BruteForceProtectionConfiguredState' 4
    Set-OfflineRegValue $repRoot 'RemoteEncryptionProtectionConfiguredState' 4

    Write-OfflineLog 'Policy keys written.' OK
}

# ---------------------------------------------------------------------------
# Phase: Defender service Start values (offline SYSTEM hive)
# ---------------------------------------------------------------------------
function Disable-OfflineDefenderServices {
    Write-OfflineLog 'Setting Defender service Start=Disabled in offline SYSTEM hive ...' INFO

    $targets = [System.Collections.ArrayList]::new($script:DefenderServices)
    if ($IncludeMDE) {
        foreach ($s in $script:MDEServices) { [void]$targets.Add($s) }
        Write-OfflineLog 'MDE services (Sense) included in offline target list.' WARN
    }

    foreach ($svc in $targets) {
        if ($script:RefuseTouchServices -contains $svc) {
            Write-OfflineLog "REFUSED firewall/network service: $svc" ERROR
            continue
        }
        $regPath = Get-OfflineSystemPath "Services\$svc"
        if (-not (Test-Path -LiteralPath $regPath)) {
            Write-OfflineLog "Service $svc not present in offline hive, skipping." DEBUG
            continue
        }
        try {
            $current = (Get-ItemProperty -LiteralPath $regPath -Name 'Start' -ErrorAction Stop).Start
            Set-OfflineRegValue -Path $regPath -Name 'Start' -Value 4 -Type DWord
            $verify = (Get-ItemProperty -LiteralPath $regPath -Name 'Start' -ErrorAction Stop).Start
            if ([int]$verify -eq 4) {
                Write-OfflineLog "Service $svc Start: $current -> 4 (Disabled)" OK
            } else {
                $script:ErrorCount++
                Write-OfflineLog "Service $svc Start value did not persist (expected 4, got $verify)." WARN
                throw "Service $svc Start value did not verify."
            }
        } catch {
            Write-OfflineLog "Failed to disable service $svc : $($_.Exception.Message)" ERROR
            throw
        }
    }

    Write-OfflineLog 'Service Start values written.' OK
}

# ---------------------------------------------------------------------------
# Phase: SafeBoot WinDefend removal (offline SYSTEM hive)
# ---------------------------------------------------------------------------
function Remove-OfflineSafeBootWinDefend {
    Write-OfflineLog 'Removing SafeBoot\WinDefend entries from offline SYSTEM hive ...' INFO

    $paths = @(
        (Get-OfflineSystemPath 'Control\SafeBoot\Minimal\WinDefend'),
        (Get-OfflineSystemPath 'Control\SafeBoot\Network\WinDefend')
    )

    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) {
            $baselineEntry = Ensure-OfflineTreeBaseline -Path $path
            $mutation = Add-OfflineMutationJournal -Kind 'Tree' -Path $path `
                -Before $baselineEntry
            try {
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
                $after = Get-OfflineRegistryTreeSnapshot -Path $path
                if ($after.Exists) {
                    throw "SafeBoot path remained after removal: $path"
                }
                $script:ActionCount++
                $mutation['Status'] = 'Applied'
                $mutation['Completed'] = (Get-Date).ToString('o')
                $mutation['After'] = $after
                Save-OfflineTransaction
                Write-OfflineLog "Removed $path" OK
            } catch {
                $script:ErrorCount++
                $mutation['Status'] = 'Failed'
                $mutation['Completed'] = (Get-Date).ToString('o')
                $mutation['Error'] = $_.Exception.Message
                Save-OfflineTransaction
                Write-OfflineLog "Failed to remove SafeBoot path $path : $($_.Exception.Message)" ERROR
                throw
            }
        } else {
            Write-OfflineLog "SafeBoot path not present: $path" DEBUG
        }
    }
}

# ---------------------------------------------------------------------------
# Offline baseline replay / rollback
# ---------------------------------------------------------------------------
function ConvertTo-OfflineRegistryValue {
    param([Parameter(Mandatory)]$Snapshot)

    switch ([string]$Snapshot.Type) {
        'Binary' { return [byte[]]@($Snapshot.Value) }
        'MultiString' { return [string[]]@($Snapshot.Value) }
        default { return $Snapshot.Value }
    }
}

function Set-OfflineRegistryValueFromSnapshot {
    param([Parameter(Mandatory)]$Snapshot)

    if (-not (Test-Path -LiteralPath $Snapshot.Path)) {
        New-Item -Path $Snapshot.Path -Force | Out-Null
    }
    $key = $null
    try {
        $key = Get-Item -LiteralPath $Snapshot.Path -ErrorAction Stop
        $kind = [System.Enum]::Parse(
            [Microsoft.Win32.RegistryValueKind],
            [string]$Snapshot.Type)
        $key.SetValue(
            [string]$Snapshot.Name,
            (ConvertTo-OfflineRegistryValue -Snapshot $Snapshot),
            $kind)
    } finally {
        Close-OfflineRegistryKey -Key $key
    }
}

function Remove-OfflineRegistryValueFromSnapshot {
    param([Parameter(Mandatory)]$Snapshot)

    if (-not (Test-Path -LiteralPath $Snapshot.Path)) { return }
    $key = $null
    try {
        $key = Get-Item -LiteralPath $Snapshot.Path -ErrorAction Stop
        if (@($key.GetValueNames()) -contains [string]$Snapshot.Name) {
            $key.DeleteValue([string]$Snapshot.Name, $false)
        }
    } finally {
        Close-OfflineRegistryKey -Key $key
    }
    if (-not [bool]$Snapshot.KeyExists -and (Test-Path -LiteralPath $Snapshot.Path)) {
        $remaining = @(Get-ChildItem -LiteralPath $Snapshot.Path -ErrorAction SilentlyContinue)
        $key = Get-Item -LiteralPath $Snapshot.Path -ErrorAction SilentlyContinue
        $remainingValues = if ($key) { @($key.GetValueNames()).Count } else { 0 }
        Close-OfflineRegistryKey -Key $key
        if ($remaining.Count -eq 0 -and $remainingValues -eq 0) {
            Remove-Item -LiteralPath $Snapshot.Path -Force -ErrorAction Stop
        }
    }
}

function Restore-OfflineRegistryTreeSnapshot {
    param([Parameter(Mandatory)]$Snapshot)

    if (-not [bool]$Snapshot.Exists) {
        if (Test-Path -LiteralPath $Snapshot.Path) {
            Remove-Item -LiteralPath $Snapshot.Path -Recurse -Force -ErrorAction Stop
        }
        return
    }
    if (-not (Test-Path -LiteralPath $Snapshot.Path)) {
        New-Item -Path $Snapshot.Path -Force | Out-Null
    }
    foreach ($value in @($Snapshot.Values)) {
        Set-OfflineRegistryValueFromSnapshot -Snapshot $value
    }
    foreach ($child in @($Snapshot.Children)) {
        Restore-OfflineRegistryTreeSnapshot -Snapshot $child
    }
}

function Resolve-OfflineBaselineArtifact {
    if (-not [string]::IsNullOrWhiteSpace($BaselinePath)) {
        return (Resolve-Path -LiteralPath $BaselinePath -ErrorAction Stop).Path
    }
    $candidate = Get-ChildItem -LiteralPath $script:ArtifactDirectory `
        -Filter 'offline-remove.*.baseline.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if ($null -eq $candidate) {
        throw 'No offline baseline artifact was found. Supply -BaselinePath from a completed transaction.'
    }
    return $candidate.FullName
}

function Invoke-OfflineRollback {
    $selectedBaselinePath = Resolve-OfflineBaselineArtifact
    $baseline = Read-OfflineJsonArtifact -Path $selectedBaselinePath `
        -Name 'OfflineRemoveBaseline'
    if ([string]$baseline.TargetVolume -ne [string](Get-OfflineCanonicalTarget)) {
        throw 'Offline baseline target volume does not match the requested rollback volume.'
    }

    $script:BaselineArtifactPath = $selectedBaselinePath
    $script:Baseline = $baseline
    $script:Transaction['BaselinePath'] = $selectedBaselinePath
    $script:Transaction['RecoveryAction'] = 'Rollback'
    $script:Transaction['Status'] = 'RollingBack'
    Save-OfflineTransaction

    $entries = @($baseline.Entries | Sort-Object Sequence -Descending)
    foreach ($entry in $entries) {
        $mutation = Add-OfflineMutationJournal -Kind "Rollback$($entry.Kind)" `
            -Path $entry.Path -Name $entry.Name -Before $entry
        try {
            if ($entry.Kind -eq 'Value') {
                if ($entry.Exists) {
                    Set-OfflineRegistryValueFromSnapshot -Snapshot $entry
                } else {
                    Remove-OfflineRegistryValueFromSnapshot -Snapshot $entry
                }
                $after = Get-OfflineRegistryValueSnapshot -Path $entry.Path `
                    -Name $entry.Name -Type $entry.Type
                if ([bool]$entry.Exists -and
                    -not (Test-OfflineRegistryValueSnapshot -Expected $entry -Actual $after)) {
                    throw "Rollback verification failed for $($entry.Path)\$($entry.Name)"
                }
                if (-not $entry.Exists -and $after.Exists) {
                    throw "Rollback did not remove $($entry.Path)\$($entry.Name)"
                }
            } elseif ($entry.Kind -eq 'Tree') {
                Restore-OfflineRegistryTreeSnapshot -Snapshot $entry
                $after = Get-OfflineRegistryTreeSnapshot -Path $entry.Path
                if ([bool]$entry.Exists -ne [bool]$after.Exists) {
                    throw "Rollback tree verification failed for $($entry.Path)"
                }
            } else {
                throw "Unsupported offline baseline entry kind: $($entry.Kind)"
            }
            $mutation['Status'] = 'RolledBack'
            $mutation['Completed'] = (Get-Date).ToString('o')
            $mutation['After'] = $after
            $script:ActionCount++
            Save-OfflineTransaction
        } catch {
            $script:ErrorCount++
            $mutation['Status'] = 'Failed'
            $mutation['Completed'] = (Get-Date).ToString('o')
            $mutation['Error'] = $_.Exception.Message
            Save-OfflineTransaction
            throw
        }
    }
    $script:Transaction['Status'] = 'RolledBack'
    Save-OfflineTransaction
}

function Get-OfflineResidualMounts {
    return @('System','Software') | Where-Object {
        $isFlagged = if ($_ -eq 'System') { $script:SystemHiveMounted } else { $script:SoftwareHiveMounted }
        $journalLoaded = [bool]$script:Transaction['Mounts'][$_]['Loaded']
        ($isFlagged -or $journalLoaded) -and (Test-OfflineHiveMounted -Hive $_)
    }
}

function Write-OfflineResultArtifact {
    param(
        [Parameter(Mandatory)][ValidateSet('Applied','RolledBack','Failed')][string]$Status,
        [Parameter(Mandatory)][int]$ExitCode,
        [string[]]$AdditionalErrors = @()
    )

    $errors = @($script:Transaction['Errors']) + @($AdditionalErrors)
    $result = [ordered]@{
        SchemaVersion = $script:ResultSchemaVersion
        TransactionId = $script:TransactionId
        TargetVolume = Get-OfflineCanonicalTarget
        RecoveryAction = $RecoveryAction
        Status = $Status
        ExitCode = $ExitCode
        Started = $script:Transaction.Started
        Completed = (Get-Date).ToString('o')
        TransactionPath = $script:TransactionPath
        BaselinePath = $script:Transaction.BaselinePath
        ResultPath = $script:ResultPath
        ActionsApplied = $script:ActionCount
        Errors = @($errors)
        ResidualMounts = @(Get-OfflineResidualMounts)
        CanRollback = [bool](Test-Path -LiteralPath $script:Transaction.BaselinePath)
        Mounts = $script:Transaction.Mounts
        Mutations = @($script:Transaction.Mutations)
    }
    Write-OfflineJsonArtifact -Path $script:ResultPath -InputObject $result -Depth 20
    return $result
}

# ---------------------------------------------------------------------------
# Phase: WMI Autologger disable (offline SYSTEM hive)
# ---------------------------------------------------------------------------
function Disable-OfflineAutoLogger {
    Write-OfflineLog 'Disabling Defender WMI Autologger entries in offline SYSTEM hive ...' INFO

    foreach ($logger in @('DefenderApiLogger','DefenderAuditLogger')) {
        $path = Get-OfflineSystemPath "Control\WMI\Autologger\$logger"
        if (Test-Path -LiteralPath $path) {
            Set-OfflineRegValue $path 'Start' 0
        } else {
            Write-OfflineLog "Autologger $logger not present in offline hive." DEBUG
        }
    }
}

# ---------------------------------------------------------------------------
# Main execution
# ---------------------------------------------------------------------------
$banner = @(
    '',
    ('=' * 72),
    " DisableDefender Offline Remove v$script:Version",
    '  Registry-based Defender removal for offline Windows volumes',
    '  Firewall services and policies are NEVER modified.',
    ('=' * 72),
    ''
)
$banner | ForEach-Object { Write-Host $_ -ForegroundColor DarkCyan }

if (-not $LogPath) {
    $LogPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'offline-remove.log'
}
$script:LogTarget = $LogPath
Write-OfflineLog "Log file: $LogPath" INFO

$primaryError = $null
$cleanupError = $null
try {
    Initialize-OfflineTransaction
    Assert-OfflineVolume
    if ($RecoveryAction -eq 'Rollback') {
        Mount-OfflineHives
        Invoke-OfflineRollback
    } else {
        Initialize-OfflineBaseline
        $script:Transaction['Status'] = 'Running'
        Save-OfflineTransaction
        Mount-OfflineHives
        Set-OfflineDefenderPolicy
        Disable-OfflineDefenderServices
        Remove-OfflineSafeBootWinDefend
        Disable-OfflineAutoLogger
        if ($script:ErrorCount -gt 0) {
            throw "Offline mutation errors were recorded; use -RecoveryAction Rollback with the baseline artifact."
        }
        $script:Transaction['Status'] = 'Applied'
        Save-OfflineTransaction
    }
} catch {
    $primaryError = $_
} finally {
    if ($null -ne $script:Transaction) {
        try {
            Dismount-OfflineHives
        } catch {
            $cleanupError = $_
        }
    }
}

$additionalErrors = New-Object System.Collections.ArrayList
if ($null -ne $primaryError) {
    [void]$additionalErrors.Add($primaryError.Exception.Message)
    Add-OfflineTransactionError -Message $primaryError.Exception.Message
}
if ($null -ne $cleanupError) {
    [void]$additionalErrors.Add($cleanupError.Exception.Message)
    Add-OfflineTransactionError -Message $cleanupError.Exception.Message
}

if ($additionalErrors.Count -gt 0 -or $script:ErrorCount -gt 0) {
    $script:Transaction['Status'] = 'Failed'
    Save-OfflineTransaction
    $failedResult = Write-OfflineResultArtifact -Status Failed -ExitCode 2 `
        -AdditionalErrors @($additionalErrors)
    if ($null -ne $primaryError) {
        Write-OfflineLog "FATAL: $($primaryError.Exception.Message)" ERROR
    }
    if ($null -ne $cleanupError) {
        Write-OfflineLog "FATAL cleanup: $($cleanupError.Exception.Message)" ERROR
    }
    Write-OfflineLog "Transaction result: $($script:ResultPath)" ERROR
    exit 2
}

$finalStatus = if ($RecoveryAction -eq 'Rollback') { 'RolledBack' } else { 'Applied' }
$script:Transaction['Status'] = $finalStatus
Save-OfflineTransaction
$finalResult = Write-OfflineResultArtifact -Status $finalStatus -ExitCode 0
Write-OfflineLog '' INFO
Write-OfflineLog "=== Offline removal transaction summary ===" INFO
Write-OfflineLog "Status: $finalStatus" OK
Write-OfflineLog "Actions applied: $($script:ActionCount)" INFO
Write-OfflineLog "Errors: $($script:ErrorCount)" OK
Write-OfflineLog "Baseline artifact: $($script:Transaction.BaselinePath)" INFO
Write-OfflineLog "Result artifact: $($script:ResultPath)" INFO
Write-OfflineLog '' INFO
Write-OfflineLog 'Limitations of offline removal (complete these after booting the target):' WARN
Write-OfflineLog '  - Set-MpPreference flags (requires live Defender engine)' WARN
Write-OfflineLog '  - Scheduled task disable (requires live Task Scheduler)' WARN
Write-OfflineLog '  - SecHealthUI Appx removal (requires live Appx subsystem)' WARN
Write-OfflineLog '  - DISM platform package removal (requires live DISM or /Image servicing)' WARN
Write-OfflineLog '' INFO
Write-OfflineLog 'Next steps:' INFO
Write-OfflineLog '  1. Boot the target volume.' INFO
Write-OfflineLog '  2. Run: .\DisableDefender.ps1 -Mode Health -HealthTarget Remove' INFO
Write-OfflineLog '  3. Run: .\DisableDefender.ps1 -Mode Remove__FORCE_FLAG__ -Only MpPreference,Tasks,Appx,DISM' INFO
'@

    $scriptContent = $scriptContent.Replace('__VERSION__', $script:Version)
    $scriptContent = $scriptContent.Replace('__DATE__', $generatedDate)
    $forceFlag = if ($Force) { ' -Force' } else { '' }
    $scriptContent = $scriptContent.Replace('__FORCE_FLAG__', $forceFlag)

    Set-Content -LiteralPath $outputPath -Value $scriptContent -Encoding UTF8
    Write-Log "Offline remove bundle generated: $outputPath" OK

    return [PSCustomObject]@{
        ScriptPath = $outputPath
        Version    = $script:Version
        Generated  = $generatedDate
        Force      = [bool]$Force
        TransactionPathPattern = Join-Path (Split-Path -Parent $outputPath) `
            'offline-remove.<transaction-id>.transaction.json'
        BaselinePathPattern = Join-Path (Split-Path -Parent $outputPath) `
            'offline-remove.<transaction-id>.baseline.json'
        ResultPathPattern = Join-Path (Split-Path -Parent $outputPath) `
            'offline-remove.<transaction-id>.result.json'
    }
}
