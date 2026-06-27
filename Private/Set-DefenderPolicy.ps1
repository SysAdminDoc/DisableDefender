# ---------------------------------------------------------------------------
# Phase: policy keys (expanded w/ privacy.sexy findings)
# ---------------------------------------------------------------------------
function Set-DefenderPolicy {
    Write-Log "Applying Defender policy keys..." INFO

    # DisableAntiSpyware is a no-op on platform >= 4.18.2007.8 (Aug 2020) but kept for LTSC 2019/Server 2016
    try {
        $mpStatus = Get-MpComputerStatus -ErrorAction Stop
        if ($mpStatus.AMProductVersion) {
            $ver = [version]$mpStatus.AMProductVersion
            if ($ver -ge [version]'4.18.2007.8') {
                Write-Log "DisableAntiSpyware is a no-op on platform $($mpStatus.AMProductVersion) -- kept for legacy compatibility only." WARN
            }
        }
    } catch {}

    # Root kill switches
    Set-RegValue $script:PolicyRoot 'DisableAntiSpyware'            1
    Set-RegValue $script:PolicyRoot 'DisableAntiVirus'              1
    Set-RegValue $script:PolicyRoot 'DisableRoutinelyTakingAction'  1
    Set-RegValue $script:PolicyRoot 'DisableSpecialRunningModes'    1
    Set-RegValue $script:PolicyRoot 'ServiceKeepAlive'              0   # privacy.sexy issue #426
    Set-RegValue $script:PolicyRoot 'AllowFastServiceStartup'       0
    Set-RegValue $script:PolicyRoot 'DisableLocalAdminMerge'        1
    Set-RegValue $script:PolicyRoot 'PUAProtection'                 0

    # Real-time
    Set-RegValue $script:RealTimeRoot 'DisableRealtimeMonitoring'        1
    Set-RegValue $script:RealTimeRoot 'DisableBehaviorMonitoring'        1
    Set-RegValue $script:RealTimeRoot 'DisableOnAccessProtection'        1
    Set-RegValue $script:RealTimeRoot 'DisableScanOnRealtimeEnable'      1
    Set-RegValue $script:RealTimeRoot 'DisableIOAVProtection'            1
    Set-RegValue $script:RealTimeRoot 'DisableRawWriteNotification'      1
    Set-RegValue $script:RealTimeRoot 'DisableIntrusionPreventionSystem' 1
    Set-RegValue $script:RealTimeRoot 'DisableInformationProtectionControl' 1   # privacy.sexy
    Set-RegValue $script:RealTimeRoot 'LocalSettingOverrideDisableRealtimeMonitoring' 1

    # Spynet / MAPS
    Set-RegValue $script:SpynetRoot 'SpyNetReporting'                    0
    Set-RegValue $script:SpynetRoot 'SubmitSamplesConsent'               2
    Set-RegValue $script:SpynetRoot 'DisableBlockAtFirstSeen'            1
    Set-RegValue $script:SpynetRoot 'LocalSettingOverrideSpynetReporting' 0   # privacy.sexy

    # MpEngine
    Set-RegValue $script:MpEngineRoot 'MpEnablePus'                 0   # privacy.sexy legacy PUA
    Set-RegValue $script:MpEngineRoot 'EnableFileHashComputation'   0   # privacy.sexy
    Set-RegValue $script:MpEngineRoot 'MpCloudBlockLevel'           0   # privacy.sexy
    Set-RegValue $script:MpEngineRoot 'MpBafsExtendedTimeout'       0   # privacy.sexy

    # NIS (Network Inspection) - privacy.sexy
    Set-RegValue $script:NISRoot    'DisableProtocolRecognition'     1
    Set-RegValue $script:NISIPSRoot 'DisableSignatureRetirement'     1
    Set-RegValue $script:NISIPSRoot 'ThrottleDetectionEventsRate'    10000000

    # Signature updates - stop auto updating
    Set-RegValue $script:SignatureRoot 'ForceUpdateFromMU' 0
    Set-RegValue $script:SignatureRoot 'DisableScheduledSignatureUpdateOnBattery' 1
    Set-RegValue $script:SignatureRoot 'RealtimeSignatureDelivery' 0                       # privacy.sexy
    Set-RegValue $script:SignatureRoot 'DisableUpdateOnStartupWithoutEngine' 1             # privacy.sexy

    # Scan
    Set-RegValue $script:ScanRoot 'DisableRemovableDriveScanning' 1
    Set-RegValue $script:ScanRoot 'DisableArchiveScanning' 1
    Set-RegValue $script:ScanRoot 'DisableScanningMappedNetworkDrivesForFullScan' 1
    Set-RegValue $script:ScanRoot 'DisableScanningNetworkFiles' 1

    # UX - suppress notifications
    Set-RegValue $script:UXRoot 'Notification_Suppress' 1                                   # privacy.sexy

    # Reporting
    Set-RegValue $script:ReportingRoot 'DisableEnhancedNotifications' 1

    # Passive mode for MDE
    Set-RegValue $script:ATPRoot 'ForceDefenderPassiveMode' 1

    # SmartScreen
    Set-RegValue $script:SmartScreen 'EnableSmartScreen' 0

    # MRT - stop malicious software removal tool
    Set-RegValue $script:MRTRoot 'DontOfferThroughWUAU' 1
    Set-RegValue $script:MRTRoot 'DontReportInfectionInformation' 1

    # Legacy Microsoft Antimalware (for older Windows)
    Set-RegValue $script:MsAntimalware 'ServiceKeepAlive' 0

    # WMI Autologger -- Defender telemetry continues even after services are disabled
    $loggerRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger'
    foreach ($logger in @('DefenderApiLogger','DefenderAuditLogger')) {
        $lPath = Join-Path $loggerRoot $logger
        if (Test-Path -LiteralPath $lPath) {
            Set-RegValue $lPath 'Start' 0
        }
    }

    # BruteForceProtection / RemoteEncryptionProtection (CSP-only features, registry equivalents)
    $bfpRoot = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Features\BehavioralNetworkBlocks\BruteForceProtection'
    $repRoot = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Features\BehavioralNetworkBlocks\RemoteEncryptionProtection'
    Set-RegValue $bfpRoot 'BruteForceProtectionConfiguredState' 4   # 4 = Off
    Set-RegValue $repRoot 'RemoteEncryptionProtectionConfiguredState' 4

    Write-Log "Policy keys written." OK
}

function Clear-DefenderPolicy {
    Write-Log "Removing Defender policy keys..." INFO
    $roots = @(
        $script:PolicyRoot, $script:RealTimeRoot, $script:SpynetRoot,
        $script:SignatureRoot, $script:ReportingRoot, $script:MpEngineRoot,
        $script:ScanRoot, $script:UXRoot, $script:NISRoot,
        $script:ATPRoot, $script:MRTRoot, $script:MsAntimalware
    )
    foreach ($r in $roots) {
        if (Test-Path -LiteralPath $r) {
            Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Removed $r" DEBUG
        }
    }
    if (Test-Path -LiteralPath $script:SmartScreen) {
        Remove-ItemProperty -LiteralPath $script:SmartScreen -Name 'EnableSmartScreen' -ErrorAction SilentlyContinue
    }
    # Restore WMI Autologger entries
    $loggerRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger'
    foreach ($logger in @('DefenderApiLogger','DefenderAuditLogger')) {
        $lPath = Join-Path $loggerRoot $logger
        if (Test-Path -LiteralPath $lPath) {
            New-ItemProperty -LiteralPath $lPath -Name 'Start' -Value 1 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }
    Write-Log "Policy keys cleared." OK
}
