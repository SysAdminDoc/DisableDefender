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
            InstalledPackages = @($before.InstalledPackages | ForEach-Object {
                [ordered]@{
                    Name            = $_.Name
                    PackageFullName = $_.PackageFullName
                }
            })
            ProvisionedPackages = @($before.ProvisionedPackages | ForEach-Object {
                [ordered]@{
                    DisplayName = $_.DisplayName
                    PackageName = $_.PackageName
                }
            })
            DeprovisionMarkers = @($before.Markers)
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

function Test-DefenderStringSetEqual {
    param(
        [string[]]$Expected,
        [string[]]$Actual
    )

    $expectedSet = @($Expected | Where-Object { $_ } | ForEach-Object {
        $_.ToLowerInvariant()
    } | Sort-Object -Unique)
    $actualSet = @($Actual | Where-Object { $_ } | ForEach-Object {
        $_.ToLowerInvariant()
    } | Sort-Object -Unique)
    return ((ConvertTo-Json $expectedSet -Compress) -eq (ConvertTo-Json $actualSet -Compress))
}

function Get-DefenderBaselinePackageProperty {
    param(
        [AllowNull()]$Item,
        [Parameter(Mandatory)][string]$Property
    )

    if ($null -eq $Item) { return $null }
    if ($Item -is [string]) { return [string]$Item }
    if ($Item.PSObject.Properties.Name -contains $Property) {
        return [string]$Item.$Property
    }
    return $null
}

function Restore-DefenderSecHealthUIBaseline {
    param(
        [Parameter(Mandatory)]$Baseline
    )

    $result = New-DefenderActionResult -Name 'SecHealthUI:RestoreRecordedBaseline' -Simulation:$WhatIfPreference
    $before = Get-DefenderSecHealthUIState
    if (-not $before.Readable) {
        return (New-DefenderSingleEffectResult -Name $result.Name -Target 'Microsoft.SecHealthUI' `
            -Attempted $false -Changed $false -Verified $false `
            -Evidence @{ Expected = 'Readable'; Actual = 'Unavailable' } -Errors $before.Error)
    }

    $expectedInstalled = @($Baseline.InstalledPackages | ForEach-Object {
        Get-DefenderBaselinePackageProperty -Item $_ -Property 'PackageFullName'
    } | Where-Object { $_ })
    $expectedProvisioned = @($Baseline.ProvisionedPackages | ForEach-Object {
        Get-DefenderBaselinePackageProperty -Item $_ -Property 'PackageName'
    } | Where-Object { $_ })
    if ($Baseline.PSObject.Properties.Name -contains 'DeprovisionMarkers') {
        $expectedMarkers = @($Baseline.DeprovisionMarkers | ForEach-Object { [string]$_ })
    } elseif ($Baseline.PSObject.Properties.Name -contains 'DeprovisionMarkerExisted' -and
        [bool]$Baseline.DeprovisionMarkerExisted) {
        $expectedMarkers = @((Get-SecHealthUIDeprovisionPaths)[0])
    } else {
        $expectedMarkers = @()
    }

    if ($WhatIfPreference) {
        foreach ($target in @('SecHealthUI:Installed','SecHealthUI:Provisioned','SecHealthUI:DeprovisionMarkers')) {
            Add-DefenderEffect -Result $result -Target $target -Required $false `
                -Attempted $false -Changed $false -Verified $false `
                -Evidence @{ Expected = 'RecordedBaseline'; Actual = 'Simulation' }
        }
        return (Complete-DefenderActionResult -Result $result)
    }

    $mutationErrors = New-Object System.Collections.ArrayList
    $actualInstalled = @($before.InstalledPackages | ForEach-Object PackageFullName)
    foreach ($package in @($before.InstalledPackages)) {
        if ($expectedInstalled -contains [string]$package.PackageFullName) { continue }
        try {
            Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop
        } catch {
            [void]$mutationErrors.Add($_.Exception.Message)
        }
    }
    foreach ($packageFullName in $expectedInstalled) {
        if ($actualInstalled -contains $packageFullName) { continue }
        try {
            $windowsApps = Join-Path $env:ProgramFiles 'WindowsApps'
            $packageDirectory = Get-ChildItem -LiteralPath $windowsApps -Directory -ErrorAction Stop |
                Where-Object { $_.Name -eq $packageFullName } |
                Select-Object -First 1
            if ($null -eq $packageDirectory) {
                throw "Recorded SecHealthUI package directory is unavailable: $packageFullName"
            }
            Add-AppxPackage -DisableDevelopmentMode `
                -Register (Join-Path $packageDirectory.FullName 'AppxManifest.xml') -ErrorAction Stop
        } catch {
            [void]$mutationErrors.Add($_.Exception.Message)
        }
    }

    $actualProvisioned = @($before.ProvisionedPackages | ForEach-Object PackageName)
    foreach ($package in @($before.ProvisionedPackages)) {
        if ($expectedProvisioned -contains [string]$package.PackageName) { continue }
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $package.PackageName `
                -AllUsers -ErrorAction Stop | Out-Null
        } catch {
            [void]$mutationErrors.Add($_.Exception.Message)
        }
    }
    foreach ($packageName in $expectedProvisioned) {
        if ($actualProvisioned -contains $packageName) { continue }
        try {
            $baselineItem = @($Baseline.ProvisionedPackages | Where-Object {
                (Get-DefenderBaselinePackageProperty -Item $_ -Property 'PackageName') -eq $packageName
            } | Select-Object -First 1)
            $displayName = if ($baselineItem.Count -gt 0) {
                Get-DefenderBaselinePackageProperty -Item $baselineItem[0] -Property 'DisplayName'
            } else {
                'Microsoft.SecHealthUI'
            }
            $windowsApps = Join-Path $env:ProgramFiles 'WindowsApps'
            $packageDirectory = Get-ChildItem -LiteralPath $windowsApps -Directory -ErrorAction Stop |
                Where-Object { $_.Name -like "$displayName*" -or $_.Name -eq $packageName } |
                Select-Object -First 1
            if ($null -eq $packageDirectory) {
                throw "Recorded provisioned SecHealthUI package directory is unavailable: $packageName"
            }
            Add-AppxProvisionedPackage -Online -FolderPath $packageDirectory.FullName `
                -SkipLicense -ErrorAction Stop | Out-Null
        } catch {
            [void]$mutationErrors.Add($_.Exception.Message)
        }
    }

    foreach ($markerPath in (Get-SecHealthUIDeprovisionPaths)) {
        $shouldExist = $expectedMarkers -contains $markerPath
        $exists = Test-Path -LiteralPath $markerPath
        try {
            if ($shouldExist -and -not $exists) {
                New-Item -Path $markerPath -Force -ErrorAction Stop | Out-Null
            } elseif (-not $shouldExist -and $exists) {
                Remove-Item -LiteralPath $markerPath -Recurse -Force -ErrorAction Stop
            }
        } catch {
            [void]$mutationErrors.Add($_.Exception.Message)
        }
    }

    $after = Get-DefenderSecHealthUIState
    $afterInstalled = @($after.InstalledPackages | ForEach-Object PackageFullName)
    $afterProvisioned = @($after.ProvisionedPackages | ForEach-Object PackageName)
    $afterMarkers = @($after.Markers | ForEach-Object { [string]$_ })
    $installedVerified = $after.Readable -and
        (Test-DefenderStringSetEqual -Expected $expectedInstalled -Actual $afterInstalled)
    $provisionedVerified = $after.Readable -and
        (Test-DefenderStringSetEqual -Expected $expectedProvisioned -Actual $afterProvisioned)
    $markersVerified = $after.Readable -and
        (Test-DefenderStringSetEqual -Expected $expectedMarkers -Actual $afterMarkers)
    $installedAttempted = -not (Test-DefenderStringSetEqual `
        -Expected $expectedInstalled -Actual $actualInstalled)
    $provisionedAttempted = -not (Test-DefenderStringSetEqual `
        -Expected $expectedProvisioned -Actual $actualProvisioned)
    $markersAttempted = -not (Test-DefenderStringSetEqual `
        -Expected $expectedMarkers -Actual @($before.Markers))

    Add-DefenderEffect -Result $result -Target 'SecHealthUI:Installed' `
        -Attempted $installedAttempted -Changed ($installedAttempted -and $installedVerified) `
        -Verified $installedVerified `
        -Evidence @{ Expected = $expectedInstalled; Actual = $afterInstalled; MutationErrors = @($mutationErrors) } `
        -Errors $(if ($installedVerified) { @() } else { @('Installed SecHealthUI package set differs from the recorded baseline.') })
    Add-DefenderEffect -Result $result -Target 'SecHealthUI:Provisioned' `
        -Attempted $provisionedAttempted -Changed ($provisionedAttempted -and $provisionedVerified) `
        -Verified $provisionedVerified `
        -Evidence @{ Expected = $expectedProvisioned; Actual = $afterProvisioned; MutationErrors = @($mutationErrors) } `
        -Errors $(if ($provisionedVerified) { @() } else { @('Provisioned SecHealthUI package set differs from the recorded baseline.') })
    Add-DefenderEffect -Result $result -Target 'SecHealthUI:DeprovisionMarkers' `
        -Attempted $markersAttempted -Changed ($markersAttempted -and $markersVerified) `
        -Verified $markersVerified `
        -Evidence @{ Expected = $expectedMarkers; Actual = $afterMarkers; MutationErrors = @($mutationErrors) } `
        -Errors $(if ($markersVerified) { @() } else { @('SecHealthUI marker set differs from the recorded baseline.') })
    return (Complete-DefenderActionResult -Result $result)
}

function Restore-SecHealthUI {
    param(
        [AllowNull()]$Baseline
    )

    if ($null -ne $Baseline) {
        return (Restore-DefenderSecHealthUIBaseline -Baseline $Baseline)
    }

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
