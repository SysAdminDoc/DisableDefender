# ---------------------------------------------------------------------------
# Phase: Services (multi-strategy fallback)
# ---------------------------------------------------------------------------
function Test-ServiceStartValue {
    param(
        [Parameter(Mandatory)][string]$RegistryPath,
        [Parameter(Mandatory)][int]$ExpectedValue
    )

    try {
        $actual = (Get-ItemProperty -LiteralPath $RegistryPath -Name 'Start' -ErrorAction Stop).Start
        return ([int]$actual -eq $ExpectedValue)
    } catch {
        return $false
    }
}

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
    if (Test-RestoreManifestRecording) {
        try {
            $startValue = (Get-ItemProperty -LiteralPath $regPath -Name 'Start' -ErrorAction Stop).Start
            $stateMap = @{
                '0' = 'Boot'
                '1' = 'System'
                '2' = 'Automatic'
                '3' = 'Manual'
                '4' = 'Disabled'
            }
            $startKey = [string][int]$startValue
            if ($stateMap.ContainsKey($startKey)) {
                Write-RestoreManifestEntry -Phase 'Services' -Action 'SetServiceStart' -Target $Service -Data ([ordered]@{
                    Service = $Service
                    State   = $stateMap[$startKey]
                })
            }
        } catch {}
    }
    # 1. Direct write
    try {
        Set-ItemProperty -LiteralPath $regPath -Name 'Start' -Value $value -Type DWord -ErrorAction Stop
        if (Test-ServiceStartValue -RegistryPath $regPath -ExpectedValue $value) {
            Write-Log "Service $Service Start=$State (direct)." DEBUG
            return $true
        }
        Write-Log "Service $Service direct Start=$State write did not persist." DEBUG
    } catch {}
    # 2. ACL takeover -> direct write
    if (Grant-RegKeyControl -SubKey $subKey) {
        try {
            Set-ItemProperty -LiteralPath $regPath -Name 'Start' -Value $value -Type DWord -ErrorAction Stop
            if (Test-ServiceStartValue -RegistryPath $regPath -ExpectedValue $value) {
                Write-Log "Service $Service Start=$State (ACL takeover)." DEBUG
                return $true
            }
            Write-Log "Service $Service ACL Start=$State write did not persist." DEBUG
        } catch {}
    }
    # 3. SYSTEM via scheduled task
    if (Invoke-AsSystem -Execute 'reg.exe' -Argument "add `"HKLM\$subKey`" /v Start /t REG_DWORD /d $value /f") {
        Start-Sleep -Milliseconds 500
        if (Test-ServiceStartValue -RegistryPath $regPath -ExpectedValue $value) {
            Write-Log "Service $Service Start=$State (SYSTEM task)." DEBUG
            return $true
        }
        Write-Log "Service $Service SYSTEM Start=$State write did not persist." WARN
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
        try {
            $service = Get-Service -Name $s -ErrorAction Stop
            if ($service.Status -eq 'Running') {
                Write-RestoreManifestEntry -Phase 'Services' -Action 'StartService' -Target $s -Data ([ordered]@{
                    Service = $s
                })
            }
        } catch {}
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
