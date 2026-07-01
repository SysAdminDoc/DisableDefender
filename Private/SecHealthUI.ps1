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

function Remove-SecHealthUI {
    Write-Log "Removing Windows Security (SecHealthUI) app..." INFO
    try {
        $deprovPaths = Get-SecHealthUIDeprovisionPaths
        if (Test-RestoreManifestRecording) {
            $installedPackages = @(Get-AppxPackage -AllUsers -Name 'Microsoft.SecHealthUI' -ErrorAction SilentlyContinue | ForEach-Object { $_.PackageFullName })
            if ($installedPackages.Count -eq 0) {
                $installedPackages = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*SecHealthUI*' } | ForEach-Object { $_.PackageFullName })
            }
            $provisionedPackages = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like '*SecHealthUI*' } | ForEach-Object { $_.PackageName })
            $existingMarkers = @($deprovPaths | Where-Object { Test-Path -LiteralPath $_ })
            Write-RestoreManifestEntry -Phase 'Appx' -Action 'RestoreSecHealthUI' -Target 'Microsoft.SecHealthUI' -Data ([ordered]@{
                InstalledPackages      = $installedPackages
                ProvisionedPackages    = $provisionedPackages
                DeprovisionMarkerExisted = ($existingMarkers.Count -gt 0)
            })
        }

        $pkgs = @(Get-AppxPackage -AllUsers -Name 'Microsoft.SecHealthUI' -ErrorAction SilentlyContinue)
        if ($pkgs.Count -eq 0) {
            $pkgs = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*SecHealthUI*' })
            if ($pkgs.Count -gt 0) {
                Write-Log "SecHealthUI found via wildcard (LTSC/variant package name: $($pkgs[0].Name))" DEBUG
            }
        }
        foreach ($p in $pkgs) {
            Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction SilentlyContinue
            Write-Log "Removed AppxPackage $($p.PackageFullName)" DEBUG
        }

        $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like '*SecHealthUI*' })
        foreach ($pp in $prov) {
            try {
                if (-not $WhatIfPreference) {
                    & dism.exe /Online /Set-NonRemovableAppPolicy /PackageFamily:$($pp.PackageName) /NonRemovable:0 2>&1 | Out-Null
                }
            } catch {}
            Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName -AllUsers -ErrorAction SilentlyContinue | Out-Null
            Write-Log "Deprovisioned $($pp.PackageName)" DEBUG
        }

        foreach ($markerPath in $deprovPaths) {
            if (-not (Test-Path -LiteralPath $markerPath)) {
                New-Item -Path $markerPath -Force -ErrorAction SilentlyContinue | Out-Null
            }
        }
        Write-Log "Windows Security app removed." OK
    } catch {
        if ($_.Exception.Message -match 'not recognized|CommandNotFoundException') {
            Write-Log "Appx cmdlets unavailable (Server Core or minimal install). SecHealthUI removal skipped." WARN
        } else {
            Write-Log "SecHealthUI removal issue: $_" WARN
        }
    }
}

function Restore-SecHealthUI {
    Write-Log "Re-provisioning Windows Security (SecHealthUI)..." INFO
    try {
        foreach ($markerPath in (Get-SecHealthUIDeprovisionPaths)) {
            if (Test-Path -LiteralPath $markerPath) { Remove-Item -LiteralPath $markerPath -Recurse -Force -ErrorAction SilentlyContinue }
        }
        $manifest = Get-ChildItem "$env:ProgramFiles\WindowsApps" -Filter '*SecHealthUI*' -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($manifest) {
            Add-AppxPackage -DisableDevelopmentMode -Register "$($manifest.FullName)\AppxManifest.xml" -ErrorAction SilentlyContinue
            Write-Log "Re-registered from $($manifest.FullName)" OK
        } else {
            Write-Log "SecHealthUI manifest not found. Run: DISM /Online /Cleanup-Image /RestoreHealth" WARN
        }
    } catch {
        Write-Log "SecHealthUI restore issue: $_" WARN
    }
}
