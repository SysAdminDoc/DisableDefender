# ---------------------------------------------------------------------------
# Phase: Appx (SecHealthUI)
# ---------------------------------------------------------------------------
function Remove-SecHealthUI {
    Write-Log "Removing Windows Security (SecHealthUI) app..." INFO
    try {
        if (Test-RestoreManifestRecording) {
            $allUser = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.SecHealthUI_8wekyb3d8bbwe'
            $installedPackages = @(Get-AppxPackage -AllUsers -Name 'Microsoft.SecHealthUI' -ErrorAction SilentlyContinue | ForEach-Object { $_.PackageFullName })
            $provisionedPackages = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq 'Microsoft.SecHealthUI' } | ForEach-Object { $_.PackageName })
            Write-RestoreManifestEntry -Phase 'Appx' -Action 'RestoreSecHealthUI' -Target 'Microsoft.SecHealthUI' -Data ([ordered]@{
                InstalledPackages      = $installedPackages
                ProvisionedPackages    = $provisionedPackages
                DeprovisionMarkerExisted = (Test-Path -LiteralPath $allUser)
            })
        }
        $pkgs = Get-AppxPackage -AllUsers -Name 'Microsoft.SecHealthUI' -ErrorAction SilentlyContinue
        foreach ($p in $pkgs) {
            Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction SilentlyContinue
            Write-Log "Removed AppxPackage $($p.PackageFullName)" DEBUG
        }
        $prov = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq 'Microsoft.SecHealthUI' }
        foreach ($pp in $prov) {
            try {
                if (-not $WhatIfPreference) {
                    & dism.exe /Online /Set-NonRemovableAppPolicy /PackageFamily:$($pp.PackageName) /NonRemovable:0 2>&1 | Out-Null
                }
            } catch {}
            Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName -AllUsers -ErrorAction SilentlyContinue | Out-Null
            Write-Log "Deprovisioned $($pp.PackageName)" DEBUG
        }
        $allUser = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.SecHealthUI_8wekyb3d8bbwe'
        if (-not (Test-Path -LiteralPath $allUser)) { New-Item -Path $allUser -Force | Out-Null }
        Write-Log "Windows Security app removed." OK
    } catch {
        Write-Log "SecHealthUI removal issue: $_" WARN
    }
}

function Restore-SecHealthUI {
    Write-Log "Re-provisioning Windows Security (SecHealthUI)..." INFO
    try {
        $allUser = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.SecHealthUI_8wekyb3d8bbwe'
        if (Test-Path -LiteralPath $allUser) { Remove-Item -LiteralPath $allUser -Recurse -Force -ErrorAction SilentlyContinue }
        $manifest = Get-ChildItem "$env:ProgramFiles\WindowsApps" -Filter 'Microsoft.SecHealthUI_*' -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
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
