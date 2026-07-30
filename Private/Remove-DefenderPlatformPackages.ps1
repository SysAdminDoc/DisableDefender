# ---------------------------------------------------------------------------
# Phase: Platform package removal (Remove mode only)
# ---------------------------------------------------------------------------
function Get-DefenderPlatformPackageState {
    $output = @()
    try {
        $output = @(& dism.exe /Online /Get-Packages /Format:Table 2>&1)
        $exitCode = [int]$LASTEXITCODE
    } catch {
        return [PSCustomObject]@{
            Readable = $false
            ExitCode = -1
            Packages = @()
            Output   = @($output)
            Error    = $_.Exception.Message
        }
    }

    if ($exitCode -ne 0) {
        return [PSCustomObject]@{
            Readable = $false
            ExitCode = $exitCode
            Packages = @()
            Output   = @($output)
            Error    = "DISM package enumeration exited $exitCode."
        }
    }

    $packages = @($output -split "`n" |
        Where-Object { $_ -match 'Windows-Defender|SecurityClient|Defender-Features|Defender-AM-Default' } |
        ForEach-Object { ($_ -split '\|')[0].Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique)
    return [PSCustomObject]@{
        Readable = $true
        ExitCode = $exitCode
        Packages = $packages
        Output   = @($output)
        Error    = $null
    }
}

function Invoke-DefenderDismPackageRemoval {
    param(
        [Parameter(Mandatory)][string]$PackageName
    )

    $output = @(& dism.exe /Online /Remove-Package /PackageName:$PackageName /Quiet /NoRestart 2>&1)
    return [PSCustomObject]@{
        ExitCode = [int]$LASTEXITCODE
        Output   = @($output)
    }
}

function Invoke-DefenderDismRestoreHealth {
    $output = @(& dism.exe /Online /Cleanup-Image /RestoreHealth /NoRestart 2>&1)
    return [PSCustomObject]@{
        ExitCode = [int]$LASTEXITCODE
        Output   = @($output)
    }
}

function Remove-DefenderPlatformPackages {
    Write-Log "Enumerating Defender platform packages..." INFO
    $result = New-DefenderActionResult -Name 'DismPackages:Remove' -Simulation:$WhatIfPreference
    $before = Get-DefenderPlatformPackageState
    if (-not $before.Readable) {
        Add-DefenderEffect -Result $result -Target 'DISM:Get-Packages' -Attempted $false `
            -Changed $false -Verified $false `
            -Evidence @{ Expected = 'Readable'; Actual = 'Failed'; ExitCode = $before.ExitCode } `
            -Errors $before.Error
        return (Complete-DefenderActionResult -Result $result)
    }

    $packages = @($before.Packages)
    if ($packages.Count -eq 0) {
        Write-Log "No Defender DISM packages found (LTSC/Server Core or already removed)." DEBUG
        Add-DefenderEffect -Result $result -Target 'DefenderPlatformPackages' `
            -Attempted $false -Changed $false -Verified $true `
            -Evidence @{ Expected = 'Absent'; Actual = 'Absent'; EnumerationExitCode = $before.ExitCode }
        return (Complete-DefenderActionResult -Result $result)
    }

    $removals = @{}
    foreach ($package in $packages) {
        if ($WhatIfPreference) {
            Add-DefenderEffect -Result $result -Target $package -Required $false `
                -Attempted $false -Changed $false -Verified $false `
                -Evidence @{ Expected = 'Absent'; Actual = 'Present'; State = 'Simulation' }
            continue
        }

        Write-RestoreManifestEntry -Phase 'DISM' -Action 'DismRestoreHealth' -Target $package -Data ([ordered]@{
            PackageName = $package
        })
        Write-Log "DISM remove: $package" DEBUG
        try {
            $removals[$package] = Invoke-DefenderDismPackageRemoval -PackageName $package
        } catch {
            $removals[$package] = [PSCustomObject]@{
                ExitCode = -1
                Output   = @($_.Exception.Message)
            }
        }
    }

    if ($WhatIfPreference) {
        return (Complete-DefenderActionResult -Result $result)
    }

    $after = Get-DefenderPlatformPackageState
    foreach ($package in $packages) {
        $removal = $removals[$package]
        $verified = $after.Readable -and ($after.Packages -notcontains $package)
        $errors = if ($verified) {
            @()
        } elseif (-not $after.Readable) {
            @("Post-removal DISM enumeration failed: $($after.Error)")
        } elseif ($removal.ExitCode -ne 0) {
            @("DISM removal exited $($removal.ExitCode) and package remained present.")
        } else {
            @('DISM reported success but the package remained present.')
        }
        Add-DefenderEffect -Result $result -Target $package -Attempted $true `
            -Changed $verified -Verified $verified `
            -Evidence @{
                Expected            = 'Absent'
                Actual              = $(if ($verified) { 'Absent' } else { 'Present' })
                RemovalExitCode     = $removal.ExitCode
                EnumerationExitCode = $after.ExitCode
            } -Errors $errors
    }

    $completed = Complete-DefenderActionResult -Result $result
    $level = if ($completed.Succeeded) { 'OK' } else { 'WARN' }
    Write-Log "DISM package result: attempted=$($completed.Attempted) changed=$($completed.Changed) verified=$($completed.Verified) errors=$(@($completed.Errors).Count)." $level
    return $completed
}
