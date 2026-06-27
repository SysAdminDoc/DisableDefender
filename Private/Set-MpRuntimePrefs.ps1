# ---------------------------------------------------------------------------
# Phase: Set-MpPreference (runtime, expanded)
# ---------------------------------------------------------------------------
function Set-MpRuntimePrefs {
    Write-Log "Applying Set-MpPreference flags..." INFO
    $boolPrefs = @(
        'DisableRealtimeMonitoring','DisableBehaviorMonitoring','DisableBlockAtFirstSeen',
        'DisableIOAVProtection','DisableScriptScanning','DisableArchiveScanning',
        'DisableIntrusionPreventionSystem','DisableRemovableDriveScanning',
        'DisableScanningMappedNetworkDrivesForFullScan','DisableScanningNetworkFiles',
        'SignatureDisableUpdateOnStartupWithoutEngine',
        'DisableCoreServiceECSIntegration',
        'DisableCoreServiceTelemetry',
        'DisableSshParsing',
        'DisableRdpParsing',
        'DisableDnsOverTcpParsing',
        'DisableInboundConnectionFiltering',
        'DisableNetworkProtectionPerfTelemetry'
    )
    foreach ($p in $boolPrefs) {
        $splat = @{ $p = $true; ErrorAction = 'SilentlyContinue' }
        try { Set-MpPreference @splat } catch {}
    }
    $enumPrefs = @{
        MAPSReporting                = 'Disabled'
        SubmitSamplesConsent         = 'NeverSend'
        PUAProtection                = 'Disabled'
        SignatureScheduleDay         = 'Never'
        ScanScheduleDay              = 'Never'
        EnableControlledFolderAccess = 'Disabled'
        EnableNetworkProtection      = 'Disabled'
        CloudBlockLevel              = 'Default'     # minimum
    }
    foreach ($k in $enumPrefs.Keys) {
        $splat = @{ $k = $enumPrefs[$k]; ErrorAction = 'SilentlyContinue' }
        try { Set-MpPreference @splat } catch {}
    }
    try {
        Add-MpPreference -ExclusionPath @('C:\','D:\','E:\') -ErrorAction SilentlyContinue
        Add-MpPreference -ExclusionExtension @('exe','dll','ps1','bat','cmd','vbs','js','msi') -ErrorAction SilentlyContinue
    } catch {}
    Write-Log "Runtime preferences applied." OK
}

function Clear-MpRuntimePrefs {
    Write-Log "Restoring MpPreference defaults..." INFO
    $prefs = @(
        'DisableRealtimeMonitoring','DisableBehaviorMonitoring','DisableBlockAtFirstSeen',
        'DisableIOAVProtection','DisableScriptScanning','DisableArchiveScanning',
        'DisableIntrusionPreventionSystem','DisableRemovableDriveScanning',
        'DisableScanningMappedNetworkDrivesForFullScan','DisableScanningNetworkFiles',
        'DisableCoreServiceECSIntegration','DisableCoreServiceTelemetry',
        'DisableSshParsing','DisableRdpParsing','DisableDnsOverTcpParsing',
        'DisableInboundConnectionFiltering','DisableNetworkProtectionPerfTelemetry'
    )
    foreach ($p in $prefs) {
        $splat = @{ $p = $false; ErrorAction = 'SilentlyContinue' }
        try { Set-MpPreference @splat } catch {}
    }
    try {
        Set-MpPreference -MAPSReporting Advanced -ErrorAction SilentlyContinue
        Set-MpPreference -SubmitSamplesConsent SendSafeSamples -ErrorAction SilentlyContinue
        Set-MpPreference -PUAProtection Enabled -ErrorAction SilentlyContinue
        Remove-MpPreference -ExclusionPath @('C:\','D:\','E:\') -ErrorAction SilentlyContinue
        Remove-MpPreference -ExclusionExtension @('exe','dll','ps1','bat','cmd','vbs','js','msi') -ErrorAction SilentlyContinue
    } catch {}
    Write-Log "MpPreference defaults restored (may require service restart)." OK
}
