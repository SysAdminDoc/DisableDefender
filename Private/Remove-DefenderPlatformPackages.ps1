# ---------------------------------------------------------------------------
# Phase: Platform package removal (Remove mode only)
# ---------------------------------------------------------------------------
function Remove-DefenderPlatformPackages {
    Write-Log "Enumerating Defender platform packages..." INFO
    $pkgs = @()
    try {
        $pkgs = (dism.exe /Online /Get-Packages /Format:Table 2>&1) -split "`n" |
                Where-Object { $_ -match 'Windows-Defender|SecurityClient' } |
                ForEach-Object { ($_ -split '\|')[0].Trim() }
    } catch {}
    foreach ($p in $pkgs) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if ($WhatIfPreference) { Write-Log "WhatIf: would DISM remove $p" INFO; continue }
        Write-Log "DISM remove: $p" DEBUG
        dism.exe /Online /Remove-Package /PackageName:$p /Quiet /NoRestart 2>&1 | Out-Null
    }
    Write-Log "Platform package removal attempted." OK
}
