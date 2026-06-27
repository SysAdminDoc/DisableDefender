# ---------------------------------------------------------------------------
# Phase: Services (multi-strategy fallback)
# ---------------------------------------------------------------------------
function Set-ServiceStart {
    param(
        [Parameter(Mandatory)][string]$Service,
        [Parameter(Mandatory)][ValidateSet('Boot','System','Automatic','Manual','Disabled')][string]$State
    )
    if ($script:RefuseTouchServices -contains $Service) {
        Write-Log "REFUSED firewall/network service: $Service" ERROR
        return $false
    }
    $map = @{ Boot=0; System=1; Automatic=2; Manual=3; Disabled=4 }
    $value = $map[$State]
    $subKey  = "SYSTEM\CurrentControlSet\Services\$Service"
    $regPath = "HKLM:\$subKey"
    if (-not (Test-Path -LiteralPath $regPath)) {
        Write-Log "Service $Service not present, skipping." DEBUG
        return $true
    }
    # 1. Direct write
    try {
        Set-ItemProperty -LiteralPath $regPath -Name 'Start' -Value $value -Type DWord -ErrorAction Stop
        Write-Log "Service $Service Start=$State (direct)." DEBUG
        return $true
    } catch {}
    # 2. ACL takeover -> direct write
    if (Grant-RegKeyControl -SubKey $subKey) {
        try {
            Set-ItemProperty -LiteralPath $regPath -Name 'Start' -Value $value -Type DWord -ErrorAction Stop
            Write-Log "Service $Service Start=$State (ACL takeover)." DEBUG
            return $true
        } catch {}
    }
    # 3. SYSTEM via scheduled task
    if (Invoke-AsSystem -Execute 'reg.exe' -Argument "add `"HKLM\$subKey`" /v Start /t REG_DWORD /d $value /f") {
        Start-Sleep -Milliseconds 500
        $actual = (Get-ItemProperty -LiteralPath $regPath -Name 'Start' -ErrorAction SilentlyContinue).Start
        if ($actual -eq $value) {
            Write-Log "Service $Service Start=$State (SYSTEM task)." DEBUG
            return $true
        }
    }
    Write-Log "Service $Service could not be set to $State. Boot to Safe Mode for full effect." WARN
    return $false
}

function Get-TargetServices {
    $list = [System.Collections.ArrayList]::new($script:DefenderServices)
    if ($script:IncludeMDEMode) {
        foreach ($s in $script:MDEServices) { [void]$list.Add($s) }
        Write-Log "MDE services included in target list (Sense)." WARN
    }
    return $list.ToArray()
}

function Disable-DefenderServices {
    $targets = Get-TargetServices
    Write-Log "Stopping Defender services..." INFO
    foreach ($s in $targets) {
        if ($script:RefuseTouchServices -contains $s) { continue }
        if ($WhatIfPreference) { Write-Log "WhatIf: would stop service $s" INFO; continue }
        sc.exe stop $s 2>&1 | Out-Null
    }
    Write-Log "Stop signals sent." OK
    foreach ($s in $targets) {
        Set-ServiceStart -Service $s -State Disabled | Out-Null
    }
    Save-AclBackup
    Write-Log "Defender services disabled." OK
}

function Restore-DefenderServices {
    Write-Log "Restoring default Defender service start types..." INFO
    $defaults = @{
        WinDefend             = 'Automatic'
        WdFilter              = 'Boot'
        WdBoot                = 'Boot'
        WdNisDrv              = 'Manual'
        WdNisSvc              = 'Manual'
        Sense                 = 'Manual'
        MDCoreSvc             = 'Manual'
        MDDlpSvc              = 'Manual'
        MsSecFlt              = 'System'
        MsSecCore             = 'System'
        SgrmAgent             = 'Manual'
        SgrmBroker            = 'Automatic'
        SecurityHealthService = 'Manual'
        wscsvc                = 'Automatic'
        webthreat             = 'Manual'
        webthreatdefsvc       = 'Manual'
        webthreatdefusersvc   = 'Automatic'
    }
    foreach ($k in $defaults.Keys) {
        Set-ServiceStart -Service $k -State $defaults[$k] | Out-Null
    }
    Write-Log "Services restored." OK
}
