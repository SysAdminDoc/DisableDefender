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
        remaining steps.
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

    DOES NOT touch the Windows Firewall. Firewall services and policy paths
    are on a hard refuse-list.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, HelpMessage = 'Root of the offline Windows volume (e.g. D:\)')]
    [string]$TargetVolume,

    [switch]$IncludeMDE,

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

    Write-OfflineLog "Loading SOFTWARE hive from $softwarePath ..." INFO
    $result = reg.exe load "HKU\$($script:HiveMountSoftware)" "$softwarePath" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to load SOFTWARE hive: $result"
    }
    $script:SoftwareHiveMounted = $true
    Write-OfflineLog "SOFTWARE hive loaded as HKU\$($script:HiveMountSoftware)" OK

    Write-OfflineLog "Loading SYSTEM hive from $systemPath ..." INFO
    $result = reg.exe load "HKU\$($script:HiveMountSystem)" "$systemPath" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Dismount-OfflineHives
        throw "Failed to load SYSTEM hive: $result"
    }
    $script:SystemHiveMounted = $true
    Write-OfflineLog "SYSTEM hive loaded as HKU\$($script:HiveMountSystem)" OK

    $selectPath = "Registry::HKEY_USERS\$($script:HiveMountSystem)\Select"
    if (-not (Test-Path -LiteralPath $selectPath)) {
        throw "SYSTEM hive has no Select key -- cannot determine the current ControlSet."
    }
    $current = (Get-ItemProperty -LiteralPath $selectPath -Name 'Current' -ErrorAction Stop).Current
    $script:ControlSet = 'ControlSet{0:D3}' -f [int]$current
    Write-OfflineLog "Active ControlSet: $($script:ControlSet)" INFO
}

function Dismount-OfflineHives {
    [gc]::Collect()
    [gc]::WaitForPendingFinalizers()
    Start-Sleep -Milliseconds 500

    if ($script:SoftwareHiveMounted) {
        $result = reg.exe unload "HKU\$($script:HiveMountSoftware)" 2>&1
        if ($LASTEXITCODE -eq 0) {
            $script:SoftwareHiveMounted = $false
            Write-OfflineLog "SOFTWARE hive unloaded." OK
        } else {
            Write-OfflineLog "Could not unload SOFTWARE hive: $result -- close all Registry Editor windows and retry." WARN
        }
    }

    if ($script:SystemHiveMounted) {
        $result = reg.exe unload "HKU\$($script:HiveMountSystem)" 2>&1
        if ($LASTEXITCODE -eq 0) {
            $script:SystemHiveMounted = $false
            Write-OfflineLog "SYSTEM hive unloaded." OK
        } else {
            Write-OfflineLog "Could not unload SYSTEM hive: $result -- close all Registry Editor windows and retry." WARN
        }
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

    foreach ($refused in $script:RefuseTouchServices) {
        if ($Path -like "*\Services\$refused*") {
            Write-OfflineLog "REFUSED firewall/network service path: $Path" ERROR
            return
        }
    }
    if ($Path -like '*\WindowsFirewall*' -or $Path -like '*\SharedAccess\Parameters\FirewallPolicy*') {
        Write-OfflineLog "REFUSED firewall policy path: $Path" ERROR
        return
    }

    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -Path $Path -Force | Out-Null
        }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        $script:ActionCount++
        Write-OfflineLog "Set $Path\$Name = $Value ($Type)" DEBUG
    } catch {
        $script:ErrorCount++
        Write-OfflineLog "Failed to set ${Path}\${Name}: $($_.Exception.Message)" ERROR
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
            New-ItemProperty -LiteralPath $regPath -Name 'Start' -Value 4 -PropertyType DWord -Force | Out-Null
            $verify = (Get-ItemProperty -LiteralPath $regPath -Name 'Start' -ErrorAction Stop).Start
            if ([int]$verify -eq 4) {
                $script:ActionCount++
                Write-OfflineLog "Service $svc Start: $current -> 4 (Disabled)" OK
            } else {
                $script:ErrorCount++
                Write-OfflineLog "Service $svc Start value did not persist (expected 4, got $verify)." WARN
            }
        } catch {
            $script:ErrorCount++
            Write-OfflineLog "Failed to disable service $svc : $($_.Exception.Message)" ERROR
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
            try {
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
                if (-not (Test-Path -LiteralPath $path)) {
                    $script:ActionCount++
                    Write-OfflineLog "Removed $path" OK
                } else {
                    $script:ErrorCount++
                    Write-OfflineLog "SafeBoot path remained after removal: $path" WARN
                }
            } catch {
                $script:ErrorCount++
                Write-OfflineLog "Failed to remove SafeBoot path $path : $($_.Exception.Message)" ERROR
            }
        } else {
            Write-OfflineLog "SafeBoot path not present: $path" DEBUG
        }
    }
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

try {
    Assert-OfflineVolume
    Mount-OfflineHives
    try {
        Set-OfflineDefenderPolicy
        Disable-OfflineDefenderServices
        Remove-OfflineSafeBootWinDefend
        Disable-OfflineAutoLogger
    } finally {
        Dismount-OfflineHives
    }

    Write-OfflineLog '' INFO
    Write-OfflineLog "=== Offline removal summary ===" INFO
    Write-OfflineLog "Actions applied: $($script:ActionCount)" INFO
    Write-OfflineLog "Errors: $($script:ErrorCount)" $(if ($script:ErrorCount -gt 0) { 'WARN' } else { 'OK' })
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

    if ($script:ErrorCount -gt 0) {
        exit 1
    }
} catch {
    Write-OfflineLog "FATAL: $($_.Exception.Message)" ERROR
    exit 2
}
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
    }
}
