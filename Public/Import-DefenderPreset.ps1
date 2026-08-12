function Import-DefenderPreset {
    <#
    .SYNOPSIS
        Applies the supported cloud-sample-submission preset.
    .DESCRIPTION
        Validates the entire versioned preset before changing MpPreference.
        Only the existing runtime preference and exclusion catalogs are
        supported; extra or modified values are rejected before mutation.
    .PARAMETER Path
        Versioned JSON preset produced by Export-DefenderPreset.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $document = Read-DefenderPresetDocument -Path $Path
    $definition = Get-DefenderCloudSampleSubmissionPreset
    $result = New-DefenderActionResult -Name "Preset:$($document.Preset)" -Simulation:$WhatIfPreference
    $pending = New-Object System.Collections.ArrayList

    try {
        $currentPrefs = Get-MpPreference -ErrorAction Stop
    } catch {
        Add-DefenderEffect -Result $result -Target 'Get-MpPreference' -Attempted $false `
            -Changed $false -Verified $false -Evidence @{ Expected = 'Readable'; Actual = 'Unavailable' } `
            -Errors $_.Exception.Message
        $completed = Complete-DefenderActionResult -Result $result
        return [PSCustomObject][ordered]@{
            Ok        = [bool]$completed.Succeeded
            Succeeded = [bool]$completed.Succeeded
            Preset    = [string]$document.Preset
            Result    = $completed
        }
    }

    foreach ($preference in $definition.Preferences.GetEnumerator()) {
        $name = [string]$preference.Key
        $expected = $preference.Value
        if ($currentPrefs.PSObject.Properties.Name -notcontains $name) {
            Add-DefenderEffect -Result $result -Target $name -Required $false `
                -Attempted $false -Changed $false -Verified $true `
                -Evidence @{ Expected = $expected; Actual = 'PropertyUnavailable'; State = 'NotApplicable' }
            continue
        }
        $before = $currentPrefs.$name
        if (Test-DefenderPresetValue -Actual $before -Expected $expected) {
            Add-DefenderEffect -Result $result -Target $name -Attempted $false `
                -Changed $false -Verified $true `
                -Evidence @{ Expected = $expected; Actual = $before; State = 'AlreadyCorrect' }
            continue
        }
        if (-not $PSCmdlet.ShouldProcess("MpPreference:$name", "Set to $expected")) {
            Add-DefenderEffect -Result $result -Target $name -Required $false `
                -Attempted $false -Changed $false -Verified $false `
                -Evidence @{ Expected = $expected; Actual = $before; State = 'Simulation' }
            continue
        }
        $mutationError = $null
        try {
            $splat = @{ ErrorAction = 'Stop' }
            $splat[$name] = $expected
            Set-MpPreference @splat
        } catch {
            $mutationError = $_.Exception.Message
        }
        [void]$pending.Add([PSCustomObject]@{
            Target        = $name
            Expected      = $expected
            Before        = $before
            MutationError = $mutationError
        })
    }

    foreach ($exclusion in $definition.Exclusions.GetEnumerator()) {
        $parameter = [string]$exclusion.Key
        $expectedValues = @($exclusion.Value)
        $propertyAvailable = $currentPrefs.PSObject.Properties.Name -contains $parameter
        if (-not $propertyAvailable) {
            foreach ($value in $expectedValues) {
                Add-DefenderEffect -Result $result -Target "${parameter}:$value" -Required $false `
                    -Attempted $false -Changed $false -Verified $true `
                    -Evidence @{ Expected = 'NotApplicable'; Actual = 'PropertyUnavailable' }
            }
            continue
        }
        foreach ($value in $expectedValues) {
            if (@($currentPrefs.$parameter) -contains $value) {
                Add-DefenderEffect -Result $result -Target "${parameter}:$value" -Attempted $false `
                    -Changed $false -Verified $true `
                    -Evidence @{ Expected = 'Present'; Actual = 'Present'; State = 'AlreadyCorrect' }
                continue
            }
            if (-not $PSCmdlet.ShouldProcess("${parameter}:$value", 'Add exclusion')) {
                Add-DefenderEffect -Result $result -Target "${parameter}:$value" -Required $false `
                    -Attempted $false -Changed $false -Verified $false `
                    -Evidence @{ Expected = 'Present'; Actual = 'Absent'; State = 'Simulation' }
                continue
            }
            $mutationError = $null
            try {
                $splat = @{ ErrorAction = 'Stop' }
                $splat[$parameter] = @($value)
                Add-MpPreference @splat
            } catch {
                $mutationError = $_.Exception.Message
            }
            [void]$pending.Add([PSCustomObject]@{
                Target        = "${parameter}:$value"
                Kind          = 'Exclusion'
                Parameter     = $parameter
                Value         = $value
                Before        = $false
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
                    -Changed $false -Verified $false -Evidence @{ Expected = $item.Expected; Actual = 'Unavailable' } `
                    -Errors "Post-mutation Get-MpPreference failed: $queryError"
                continue
            }
            if ($item.Kind -eq 'Exclusion') {
                $present = $afterPrefs.PSObject.Properties.Name -contains $item.Parameter -and
                    (@($afterPrefs.($item.Parameter)) -contains $item.Value)
                $verified = $present
                $actual = if ($present) { 'Present' } else { 'Absent' }
                $expected = 'Present'
            } else {
                $available = $afterPrefs.PSObject.Properties.Name -contains $item.Target
                $actual = if ($available) { $afterPrefs.($item.Target) } else { $null }
                $verified = $available -and (Test-DefenderPresetValue -Actual $actual -Expected $item.Expected)
                $expected = $item.Expected
            }
            $errors = if ($verified) { @() } elseif ($item.MutationError) { @($item.MutationError) } else { @('Preset value did not converge.') }
            Add-DefenderEffect -Result $result -Target $item.Target -Attempted $true `
                -Changed ($verified -and -not (Test-DefenderPresetValue -Actual $item.Before -Expected $expected)) `
                -Verified $verified -Evidence @{ Expected = $expected; Actual = $actual } -Errors $errors
        }
    }

    $completed = Complete-DefenderActionResult -Result $result
    $level = if ($completed.Succeeded) { 'OK' } else { 'WARN' }
    Write-Log "Defender preset imported: $($document.Preset) attempted=$($completed.Attempted) changed=$($completed.Changed) verified=$($completed.Verified)" $level
    return [PSCustomObject][ordered]@{
        Ok        = [bool]$completed.Succeeded
        Succeeded = [bool]$completed.Succeeded
        Preset    = [string]$document.Preset
        Result    = $completed
    }
}
