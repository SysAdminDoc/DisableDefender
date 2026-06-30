# ---------------------------------------------------------------------------
# Phase: Set-MpPreference (runtime, expanded)
# ---------------------------------------------------------------------------
function Get-MpRuntimePreferenceCatalog {
    return @(
        [PSCustomObject]@{ Name = 'DisableRealtimeMonitoring'; DisableValue = $true; RestoreValue = $false }
        [PSCustomObject]@{ Name = 'DisableBehaviorMonitoring'; DisableValue = $true; RestoreValue = $false }
        [PSCustomObject]@{ Name = 'DisableBlockAtFirstSeen'; DisableValue = $true; RestoreValue = $false }
        [PSCustomObject]@{ Name = 'DisableIOAVProtection'; DisableValue = $true; RestoreValue = $false }
        [PSCustomObject]@{ Name = 'DisableScriptScanning'; DisableValue = $true; RestoreValue = $false }
        [PSCustomObject]@{ Name = 'DisableArchiveScanning'; DisableValue = $true; RestoreValue = $false }
        [PSCustomObject]@{ Name = 'DisableIntrusionPreventionSystem'; DisableValue = $true; RestoreValue = $false }
        [PSCustomObject]@{ Name = 'DisableRemovableDriveScanning'; DisableValue = $true; RestoreValue = $false }
        [PSCustomObject]@{ Name = 'DisableScanningMappedNetworkDrivesForFullScan'; DisableValue = $true; RestoreValue = $false }
        [PSCustomObject]@{ Name = 'DisableScanningNetworkFiles'; DisableValue = $true; RestoreValue = $false }
        [PSCustomObject]@{ Name = 'SignatureDisableUpdateOnStartupWithoutEngine'; DisableValue = $true; RestoreValue = $false }
        [PSCustomObject]@{ Name = 'DisableCoreServiceECSIntegration'; DisableValue = $true; RestoreValue = $false }
        [PSCustomObject]@{ Name = 'DisableCoreServiceTelemetry'; DisableValue = $true; RestoreValue = $false }
        [PSCustomObject]@{ Name = 'DisableSshParsing'; DisableValue = $true; RestoreValue = $false }
        [PSCustomObject]@{ Name = 'DisableRdpParsing'; DisableValue = $true; RestoreValue = $false }
        [PSCustomObject]@{ Name = 'DisableDnsOverTcpParsing'; DisableValue = $true; RestoreValue = $false }
        [PSCustomObject]@{ Name = 'DisableInboundConnectionFiltering'; DisableValue = $true; RestoreValue = $false }
        [PSCustomObject]@{ Name = 'DisableNetworkProtectionPerfTelemetry'; DisableValue = $true; RestoreValue = $false }
        [PSCustomObject]@{ Name = 'MAPSReporting'; DisableValue = 'Disabled'; RestoreValue = 'Advanced' }
        [PSCustomObject]@{ Name = 'SubmitSamplesConsent'; DisableValue = 'NeverSend'; RestoreValue = 'SendSafeSamples' }
        [PSCustomObject]@{ Name = 'PUAProtection'; DisableValue = 'Disabled'; RestoreValue = 'Enabled' }
        [PSCustomObject]@{ Name = 'SignatureScheduleDay'; DisableValue = 'Never'; RestoreValue = 'Everyday' }
        [PSCustomObject]@{ Name = 'ScanScheduleDay'; DisableValue = 'Never'; RestoreValue = 'Everyday' }
        [PSCustomObject]@{ Name = 'EnableControlledFolderAccess'; DisableValue = 'Disabled'; RestoreValue = 'Disabled' }
        [PSCustomObject]@{ Name = 'EnableNetworkProtection'; DisableValue = 'Disabled'; RestoreValue = 'Disabled' }
        [PSCustomObject]@{ Name = 'CloudBlockLevel'; DisableValue = 'Default'; RestoreValue = 'Default' }
    )
}

function Get-MpRuntimeExclusionCatalog {
    return @(
        [PSCustomObject]@{ Parameter = 'ExclusionPath'; Values = @('C:\','D:\','E:\') }
        [PSCustomObject]@{ Parameter = 'ExclusionExtension'; Values = @('exe','dll','ps1','bat','cmd','vbs','js','msi') }
    )
}

function Set-MpRuntimePrefs {
    Write-Log "Applying Set-MpPreference flags..." INFO
    $currentPrefs = $null
    if (Test-RestoreManifestRecording) {
        try { $currentPrefs = Get-MpPreference -ErrorAction Stop } catch {}
    }
    foreach ($preference in Get-MpRuntimePreferenceCatalog) {
        if ($currentPrefs -and ($currentPrefs.PSObject.Properties.Name -contains $preference.Name)) {
            Write-RestoreManifestEntry -Phase 'MpPreference' -Action 'SetMpPreference' -Target $preference.Name -Data ([ordered]@{
                Name  = $preference.Name
                Value = $currentPrefs.($preference.Name)
            })
        }
        $splat = @{ ErrorAction = 'SilentlyContinue' }
        $splat[$preference.Name] = $preference.DisableValue
        try { Set-MpPreference @splat } catch {}
    }
    try {
        if ($currentPrefs) {
            foreach ($exclusion in Get-MpRuntimeExclusionCatalog) {
                foreach ($value in $exclusion.Values) {
                    if (@($currentPrefs.($exclusion.Parameter)) -notcontains $value) {
                        Write-RestoreManifestEntry -Phase 'MpPreference' -Action 'RemoveMpPreferenceValue' -Target "$($exclusion.Parameter):$value" -Data ([ordered]@{
                            Parameter = $exclusion.Parameter
                            Value     = $value
                        })
                    }
                }
            }
        }
        foreach ($exclusion in Get-MpRuntimeExclusionCatalog) {
            $splat = @{ ErrorAction = 'SilentlyContinue' }
            $splat[$exclusion.Parameter] = $exclusion.Values
            Add-MpPreference @splat
        }
    } catch {}
    Write-Log "Runtime preferences applied." OK
}

function Clear-MpRuntimePrefs {
    Write-Log "Restoring MpPreference defaults..." INFO
    foreach ($preference in Get-MpRuntimePreferenceCatalog) {
        $splat = @{ ErrorAction = 'SilentlyContinue' }
        $splat[$preference.Name] = $preference.RestoreValue
        try { Set-MpPreference @splat } catch {}
    }
    try {
        foreach ($exclusion in Get-MpRuntimeExclusionCatalog) {
            $splat = @{ ErrorAction = 'SilentlyContinue' }
            $splat[$exclusion.Parameter] = $exclusion.Values
            Remove-MpPreference @splat
        }
    } catch {}
    Write-Log "MpPreference defaults restored (may require service restart)." OK
}
