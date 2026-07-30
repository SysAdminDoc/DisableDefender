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

function Test-DefenderMpPreferenceValue {
    param(
        [AllowNull()]$Actual,
        [AllowNull()]$Expected
    )

    return ([string]$Actual -ieq [string]$Expected)
}

function Invoke-DefenderMpPreferencePlan {
    param(
        [Parameter(Mandatory)][ValidateSet('Disable','Restore')][string]$Mode
    )

    $result = New-DefenderActionResult -Name "MpPreference:$Mode" -Simulation:$WhatIfPreference
    $pending = New-Object System.Collections.ArrayList
    try {
        $currentPrefs = Get-MpPreference -ErrorAction Stop
    } catch {
        Add-DefenderEffect -Result $result -Target 'Get-MpPreference' -Attempted $false `
            -Changed $false -Verified $false -Evidence @{ Expected = 'Readable'; Actual = 'Unavailable' } `
            -Errors $_.Exception.Message
        return (Complete-DefenderActionResult -Result $result)
    }

    foreach ($preference in Get-MpRuntimePreferenceCatalog) {
        $expected = if ($Mode -eq 'Disable') { $preference.DisableValue } else { $preference.RestoreValue }
        if ($currentPrefs.PSObject.Properties.Name -notcontains $preference.Name) {
            Add-DefenderEffect -Result $result -Target $preference.Name -Required $false `
                -Attempted $false -Changed $false -Verified $true `
                -Evidence @{ Expected = $expected; Actual = 'PropertyUnavailable'; State = 'NotApplicable' }
            continue
        }

        $before = $currentPrefs.($preference.Name)
        if (Test-DefenderMpPreferenceValue -Actual $before -Expected $expected) {
            Add-DefenderEffect -Result $result -Target $preference.Name -Attempted $false `
                -Changed $false -Verified $true `
                -Evidence @{ Expected = $expected; Actual = $before; State = 'AlreadyCorrect' }
            continue
        }

        if ($WhatIfPreference) {
            Add-DefenderEffect -Result $result -Target $preference.Name -Required $false `
                -Attempted $false -Changed $false -Verified $false `
                -Evidence @{ Expected = $expected; Actual = $before; State = 'Simulation' }
            continue
        }

        if ($Mode -eq 'Disable' -and (Test-RestoreManifestRecording)) {
            Write-RestoreManifestEntry -Phase 'MpPreference' -Action 'SetMpPreference' -Target $preference.Name -Data ([ordered]@{
                Name  = $preference.Name
                Value = $before
            })
        }

        $mutationError = $null
        try {
            $splat = @{ ErrorAction = 'Stop' }
            $splat[$preference.Name] = $expected
            Set-MpPreference @splat
        } catch {
            $mutationError = $_.Exception.Message
        }
        [void]$pending.Add([PSCustomObject]@{
            Target        = $preference.Name
            Kind          = 'Preference'
            Parameter     = $preference.Name
            Value         = $expected
            Before        = $before
            MutationError = $mutationError
        })
    }

    foreach ($exclusion in Get-MpRuntimeExclusionCatalog) {
        $propertyAvailable = $currentPrefs.PSObject.Properties.Name -contains $exclusion.Parameter
        if (-not $propertyAvailable) {
            foreach ($value in $exclusion.Values) {
                Add-DefenderEffect -Result $result -Target "$($exclusion.Parameter):$value" `
                    -Required $false -Attempted $false -Changed $false -Verified $true `
                    -Evidence @{ Expected = 'NotApplicable'; Actual = 'PropertyUnavailable' }
            }
            continue
        }

        foreach ($value in $exclusion.Values) {
            $beforePresent = @($currentPrefs.($exclusion.Parameter)) -contains $value
            $expectedPresent = ($Mode -eq 'Disable')
            if ($beforePresent -eq $expectedPresent) {
                Add-DefenderEffect -Result $result -Target "$($exclusion.Parameter):$value" `
                    -Attempted $false -Changed $false -Verified $true `
                    -Evidence @{ Expected = $(if ($expectedPresent) { 'Present' } else { 'Absent' }); Actual = $(if ($beforePresent) { 'Present' } else { 'Absent' }); State = 'AlreadyCorrect' }
                continue
            }

            if ($WhatIfPreference) {
                Add-DefenderEffect -Result $result -Target "$($exclusion.Parameter):$value" `
                    -Required $false -Attempted $false -Changed $false -Verified $false `
                    -Evidence @{ Expected = $(if ($expectedPresent) { 'Present' } else { 'Absent' }); Actual = $(if ($beforePresent) { 'Present' } else { 'Absent' }); State = 'Simulation' }
                continue
            }

            if ($Mode -eq 'Disable' -and (Test-RestoreManifestRecording)) {
                if (-not $beforePresent) {
                        Write-RestoreManifestEntry -Phase 'MpPreference' -Action 'RemoveMpPreferenceValue' -Target "$($exclusion.Parameter):$value" -Data ([ordered]@{
                            Parameter = $exclusion.Parameter
                            Value     = $value
                        })
                }
            }

            $mutationError = $null
            try {
                $splat = @{ ErrorAction = 'Stop' }
                $splat[$exclusion.Parameter] = @($value)
                if ($Mode -eq 'Disable') {
                    Add-MpPreference @splat
                } else {
                    Remove-MpPreference @splat
                }
            } catch {
                $mutationError = $_.Exception.Message
            }
            [void]$pending.Add([PSCustomObject]@{
                Target        = "$($exclusion.Parameter):$value"
                Kind          = 'Exclusion'
                Parameter     = $exclusion.Parameter
                Value         = $value
                Before        = $beforePresent
                Expected      = $expectedPresent
                MutationError = $mutationError
            })
        }
    }

    if ($pending.Count -gt 0) {
        try {
            $afterPrefs = Get-MpPreference -ErrorAction Stop
            $queryError = $null
        } catch {
            $afterPrefs = $null
            $queryError = $_.Exception.Message
        }

        foreach ($item in $pending) {
            if ($null -eq $afterPrefs) {
                Add-DefenderEffect -Result $result -Target $item.Target -Attempted $true `
                    -Changed $false -Verified $false `
                    -Evidence @{ Expected = $item.Value; Actual = 'Unavailable'; MutationError = $item.MutationError } `
                    -Errors "Post-mutation Get-MpPreference failed: $queryError"
                continue
            }

            if ($item.Kind -eq 'Preference') {
                $propertyAvailable = $afterPrefs.PSObject.Properties.Name -contains $item.Parameter
                $actual = if ($propertyAvailable) { $afterPrefs.($item.Parameter) } else { $null }
                $verified = $propertyAvailable -and
                    (Test-DefenderMpPreferenceValue -Actual $actual -Expected $item.Value)
                $changed = $verified -and
                    -not (Test-DefenderMpPreferenceValue -Actual $item.Before -Expected $item.Value)
                $expectedEvidence = $item.Value
            } else {
                $propertyAvailable = $afterPrefs.PSObject.Properties.Name -contains $item.Parameter
                $afterPresent = $propertyAvailable -and (@($afterPrefs.($item.Parameter)) -contains $item.Value)
                $verified = $propertyAvailable -and ($afterPresent -eq $item.Expected)
                $changed = $verified -and ($item.Before -ne $item.Expected)
                $actual = if ($afterPresent) { 'Present' } else { 'Absent' }
                $expectedEvidence = if ($item.Expected) { 'Present' } else { 'Absent' }
            }

            $errors = if ($verified) {
                @()
            } elseif ($item.MutationError) {
                @($item.MutationError)
            } else {
                @('MpPreference did not converge to the requested value.')
            }
            Add-DefenderEffect -Result $result -Target $item.Target -Attempted $true `
                -Changed $changed -Verified $verified `
                -Evidence @{ Expected = $expectedEvidence; Actual = $actual; MutationError = $item.MutationError } `
                -Errors $errors
        }
    }

    return (Complete-DefenderActionResult -Result $result)
}

function Set-MpRuntimePrefs {
    Write-Log "Applying Set-MpPreference flags..." INFO
    $completed = Invoke-DefenderMpPreferencePlan -Mode Disable
    $level = if ($completed.Succeeded) { 'OK' } else { 'WARN' }
    Write-Log "MpPreference result: attempted=$($completed.Attempted) changed=$($completed.Changed) verified=$($completed.Verified) errors=$(@($completed.Errors).Count)." $level
    return $completed
}

function Clear-MpRuntimePrefs {
    Write-Log "Restoring MpPreference defaults..." INFO
    $completed = Invoke-DefenderMpPreferencePlan -Mode Restore
    $level = if ($completed.Succeeded) { 'OK' } else { 'WARN' }
    Write-Log "MpPreference restore result: attempted=$($completed.Attempted) changed=$($completed.Changed) verified=$($completed.Verified) errors=$(@($completed.Errors).Count)." $level
    return $completed
}
