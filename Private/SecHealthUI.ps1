# ---------------------------------------------------------------------------
# Phase: Appx (SecHealthUI)
# ---------------------------------------------------------------------------
function Get-SecHealthUIDeprovisionPaths {
    $markerRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned'
    return @(
        (Join-Path $markerRoot 'Microsoft.SecHealthUI_8wekyb3d8bbwe'),
        (Join-Path $markerRoot 'Microsoft.Windows.SecHealthUI_cw5n1h2txyewy')
    )
}

function Get-DefenderSecHealthUIState {
    try {
        $installedPackages = @(Get-AppxPackage -AllUsers -Name 'Microsoft.SecHealthUI' -ErrorAction Stop)
        if ($installedPackages.Count -eq 0) {
            $installedPackages = @(Get-AppxPackage -AllUsers -ErrorAction Stop |
                Where-Object { $_.Name -like '*SecHealthUI*' })
        }
        $provisionedPackages = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop |
            Where-Object { $_.DisplayName -like '*SecHealthUI*' })
        $markers = @((Get-SecHealthUIDeprovisionPaths) | Where-Object {
            Test-Path -LiteralPath $_ -ErrorAction Stop
        })
        return [PSCustomObject]@{
            Supported           = $true
            Readable            = $true
            InstalledPackages   = $installedPackages
            ProvisionedPackages = $provisionedPackages
            Markers             = $markers
            Error               = $null
        }
    } catch {
        if ($_.Exception.Message -match 'not recognized|CommandNotFoundException|is not recognized') {
            return [PSCustomObject]@{
                Supported           = $false
                Readable            = $true
                InstalledPackages   = @()
                ProvisionedPackages = @()
                Markers             = @()
                Error               = $null
            }
        }
        return [PSCustomObject]@{
            Supported           = $true
            Readable            = $false
            InstalledPackages   = @()
            ProvisionedPackages = @()
            Markers             = @()
            Error               = $_.Exception.Message
        }
    }
}

function Invoke-DefenderSecHealthDismPolicy {
    param(
        [Parameter(Mandatory)][string]$PackageName
    )

    $output = @(& dism.exe /Online /Set-NonRemovableAppPolicy `
        /PackageFamily:$PackageName /NonRemovable:0 2>&1)
    return [PSCustomObject]@{
        PackageName = $PackageName
        ExitCode    = [int]$LASTEXITCODE
        Output      = @($output)
    }
}

function Remove-SecHealthUI {
    Write-Log "Removing Windows Security (SecHealthUI) app..." INFO
    $result = New-DefenderActionResult -Name 'SecHealthUI:Remove' -Simulation:$WhatIfPreference
    $before = Get-DefenderSecHealthUIState
    if (-not $before.Readable) {
        Add-DefenderEffect -Result $result -Target 'Microsoft.SecHealthUI' -Attempted $false `
            -Changed $false -Verified $false -Evidence @{ Expected = 'Readable'; Actual = 'Unavailable' } `
            -Errors $before.Error
        return (Complete-DefenderActionResult -Result $result)
    }
    if (-not $before.Supported) {
        Write-Log "Appx cmdlets unavailable (Server Core or minimal install). SecHealthUI removal is not applicable." WARN
        Add-DefenderEffect -Result $result -Target 'Microsoft.SecHealthUI' -Required $false `
            -Attempted $false -Changed $false -Verified $true `
            -Evidence @{ Expected = 'NotApplicable'; Actual = 'AppxUnsupported' }
        return (Complete-DefenderActionResult -Result $result)
    }

    $deprovPaths = @(Get-SecHealthUIDeprovisionPaths)
    if ($WhatIfPreference) {
        foreach ($effect in @(
            @{ Target = 'SecHealthUI:Installed'; Expected = 'Absent'; Actual = $(if ($before.InstalledPackages.Count) { 'Present' } else { 'Absent' }) }
            @{ Target = 'SecHealthUI:Provisioned'; Expected = 'Absent'; Actual = $(if ($before.ProvisionedPackages.Count) { 'Present' } else { 'Absent' }) }
            @{ Target = 'SecHealthUI:DeprovisionMarkers'; Expected = 'Present'; Actual = "$($before.Markers.Count)/$($deprovPaths.Count)" }
        )) {
            $alreadyCorrect = $effect.Expected -eq $effect.Actual -or
                ($effect.Target -eq 'SecHealthUI:DeprovisionMarkers' -and $before.Markers.Count -eq $deprovPaths.Count)
            Add-DefenderEffect -Result $result -Target $effect.Target -Required $alreadyCorrect `
                -Attempted $false -Changed $false -Verified $alreadyCorrect `
                -Evidence @{ Expected = $effect.Expected; Actual = $effect.Actual; State = 'Simulation' }
        }
        return (Complete-DefenderActionResult -Result $result)
    }

    if (Test-RestoreManifestRecording) {
        Write-RestoreManifestEntry -Phase 'Appx' -Action 'RestoreSecHealthUI' -Target 'Microsoft.SecHealthUI' -Data ([ordered]@{
            InstalledPackages        = @($before.InstalledPackages | ForEach-Object PackageFullName)
            ProvisionedPackages      = @($before.ProvisionedPackages | ForEach-Object PackageName)
            DeprovisionMarkerExisted = ($before.Markers.Count -gt 0)
        })
    }

    $installedErrors = New-Object System.Collections.ArrayList
    foreach ($package in $before.InstalledPackages) {
        try {
            Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop
        } catch {
            [void]$installedErrors.Add($_.Exception.Message)
        }
    }

    $provisionedErrors = New-Object System.Collections.ArrayList
    $dismPolicyResults = New-Object System.Collections.ArrayList
    foreach ($package in $before.ProvisionedPackages) {
        try {
            $dismResult = Invoke-DefenderSecHealthDismPolicy -PackageName $package.PackageName
            [void]$dismPolicyResults.Add($dismResult)
            Remove-AppxProvisionedPackage -Online -PackageName $package.PackageName -AllUsers -ErrorAction Stop | Out-Null
        } catch {
            [void]$provisionedErrors.Add($_.Exception.Message)
        }
    }

    $markerErrors = New-Object System.Collections.ArrayList
    foreach ($markerPath in $deprovPaths) {
        if (-not (Test-Path -LiteralPath $markerPath)) {
            try {
                New-Item -Path $markerPath -Force -ErrorAction Stop | Out-Null
            } catch {
                [void]$markerErrors.Add($_.Exception.Message)
            }
        }
    }

    $after = Get-DefenderSecHealthUIState
    $installedVerified = $after.Readable -and $after.InstalledPackages.Count -eq 0
    $provisionedVerified = $after.Readable -and $after.ProvisionedPackages.Count -eq 0
    $markersVerified = $after.Readable -and $after.Markers.Count -eq $deprovPaths.Count
    Add-DefenderEffect -Result $result -Target 'SecHealthUI:Installed' `
        -Attempted ($before.InstalledPackages.Count -gt 0) `
        -Changed ($before.InstalledPackages.Count -gt 0 -and $installedVerified) -Verified $installedVerified `
        -Evidence @{ Expected = 'Absent'; Actual = $(if ($installedVerified) { 'Absent' } else { 'PresentOrUnknown' }); MutationErrors = @($installedErrors) } `
        -Errors $(if ($installedVerified) { @() } elseif ($installedErrors.Count) { @($installedErrors) } else { @('Installed SecHealthUI package remained.') })
    Add-DefenderEffect -Result $result -Target 'SecHealthUI:Provisioned' `
        -Attempted ($before.ProvisionedPackages.Count -gt 0) `
        -Changed ($before.ProvisionedPackages.Count -gt 0 -and $provisionedVerified) -Verified $provisionedVerified `
        -Evidence @{ Expected = 'Absent'; Actual = $(if ($provisionedVerified) { 'Absent' } else { 'PresentOrUnknown' }); DismPolicyResults = @($dismPolicyResults); MutationErrors = @($provisionedErrors) } `
        -Errors $(if ($provisionedVerified) { @() } elseif ($provisionedErrors.Count) { @($provisionedErrors) } else { @('Provisioned SecHealthUI package remained.') })
    Add-DefenderEffect -Result $result -Target 'SecHealthUI:DeprovisionMarkers' `
        -Attempted ($before.Markers.Count -lt $deprovPaths.Count) `
        -Changed ($before.Markers.Count -lt $deprovPaths.Count -and $markersVerified) -Verified $markersVerified `
        -Evidence @{ Expected = $deprovPaths.Count; Actual = $after.Markers.Count; MutationErrors = @($markerErrors) } `
        -Errors $(if ($markersVerified) { @() } elseif ($markerErrors.Count) { @($markerErrors) } else { @('SecHealthUI deprovision marker set is incomplete.') })

    $completed = Complete-DefenderActionResult -Result $result
    $level = if ($completed.Succeeded) { 'OK' } else { 'WARN' }
    Write-Log "SecHealthUI removal result: attempted=$($completed.Attempted) changed=$($completed.Changed) verified=$($completed.Verified) errors=$(@($completed.Errors).Count)." $level
    return $completed
}

function Restore-SecHealthUI {
    Write-Log "Re-provisioning Windows Security (SecHealthUI)..." INFO
    $result = New-DefenderActionResult -Name 'SecHealthUI:Restore' -Simulation:$WhatIfPreference
    $before = Get-DefenderSecHealthUIState
    if (-not $before.Readable) {
        Add-DefenderEffect -Result $result -Target 'Microsoft.SecHealthUI' -Attempted $false `
            -Changed $false -Verified $false -Evidence @{ Expected = 'Readable'; Actual = 'Unavailable' } `
            -Errors $before.Error
        return (Complete-DefenderActionResult -Result $result)
    }
    if (-not $before.Supported) {
        Add-DefenderEffect -Result $result -Target 'Microsoft.SecHealthUI' -Required $false `
            -Attempted $false -Changed $false -Verified $true `
            -Evidence @{ Expected = 'NotApplicable'; Actual = 'AppxUnsupported' }
        return (Complete-DefenderActionResult -Result $result)
    }

    $packagePresent = $before.InstalledPackages.Count -gt 0 -or $before.ProvisionedPackages.Count -gt 0
    $markerPresent = $before.Markers.Count -gt 0
    if ($WhatIfPreference) {
        Add-DefenderEffect -Result $result -Target 'SecHealthUI:Package' -Required $packagePresent `
            -Attempted $false -Changed $false -Verified $packagePresent `
            -Evidence @{ Expected = 'Present'; Actual = $(if ($packagePresent) { 'Present' } else { 'Absent' }); State = 'Simulation' }
        Add-DefenderEffect -Result $result -Target 'SecHealthUI:DeprovisionMarkers' -Required (-not $markerPresent) `
            -Attempted $false -Changed $false -Verified (-not $markerPresent) `
            -Evidence @{ Expected = 'Absent'; Actual = $(if ($markerPresent) { 'Present' } else { 'Absent' }); State = 'Simulation' }
        return (Complete-DefenderActionResult -Result $result)
    }

    $markerErrors = New-Object System.Collections.ArrayList
    foreach ($markerPath in (Get-SecHealthUIDeprovisionPaths)) {
        if (Test-Path -LiteralPath $markerPath) {
            try {
                Remove-Item -LiteralPath $markerPath -Recurse -Force -ErrorAction Stop
            } catch {
                [void]$markerErrors.Add($_.Exception.Message)
            }
        }
    }

    $packageError = $null
    if (-not $packagePresent) {
        try {
            $windowsApps = Join-Path $env:ProgramFiles 'WindowsApps'
            $manifest = Get-ChildItem -LiteralPath $windowsApps -Filter '*SecHealthUI*' `
                -Directory -ErrorAction Stop | Select-Object -First 1
            if ($null -eq $manifest) {
                throw 'SecHealthUI manifest not found. Run DISM /Online /Cleanup-Image /RestoreHealth.'
            }
            Add-AppxPackage -DisableDevelopmentMode -Register (Join-Path $manifest.FullName 'AppxManifest.xml') `
                -ErrorAction Stop
        } catch {
            $packageError = $_.Exception.Message
        }
    }

    $after = Get-DefenderSecHealthUIState
    $packageVerified = $after.Readable -and
        ($after.InstalledPackages.Count -gt 0 -or $after.ProvisionedPackages.Count -gt 0)
    $markersVerified = $after.Readable -and $after.Markers.Count -eq 0
    Add-DefenderEffect -Result $result -Target 'SecHealthUI:Package' `
        -Attempted (-not $packagePresent) -Changed (-not $packagePresent -and $packageVerified) `
        -Verified $packageVerified `
        -Evidence @{ Expected = 'Present'; Actual = $(if ($packageVerified) { 'Present' } else { 'AbsentOrUnknown' }); MutationError = $packageError } `
        -Errors $(if ($packageVerified) { @() } elseif ($packageError) { @($packageError) } else { @('SecHealthUI package did not become present.') })
    Add-DefenderEffect -Result $result -Target 'SecHealthUI:DeprovisionMarkers' `
        -Attempted $markerPresent -Changed ($markerPresent -and $markersVerified) -Verified $markersVerified `
        -Evidence @{ Expected = 'Absent'; Actual = $(if ($markersVerified) { 'Absent' } else { 'PresentOrUnknown' }); MutationErrors = @($markerErrors) } `
        -Errors $(if ($markersVerified) { @() } elseif ($markerErrors.Count) { @($markerErrors) } else { @('SecHealthUI deprovision markers remained.') })

    $completed = Complete-DefenderActionResult -Result $result
    $level = if ($completed.Succeeded) { 'OK' } else { 'WARN' }
    Write-Log "SecHealthUI restore result: attempted=$($completed.Attempted) changed=$($completed.Changed) verified=$($completed.Verified) errors=$(@($completed.Errors).Count)." $level
    return $completed
}
