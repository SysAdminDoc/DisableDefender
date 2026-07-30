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

function Get-DefenderServiceStartState {
    param(
        [Parameter(Mandatory)][string]$RegistryPath
    )

    try {
        if (-not (Test-Path -LiteralPath $RegistryPath -ErrorAction Stop)) {
            return [PSCustomObject]@{
                Readable = $true
                Exists   = $false
                Value    = $null
                Error    = $null
            }
        }
        $actual = (Get-ItemProperty -LiteralPath $RegistryPath -Name 'Start' -ErrorAction Stop).Start
        return [PSCustomObject]@{
            Readable = $true
            Exists   = $true
            Value    = [int]$actual
            Error    = $null
        }
    } catch {
        return [PSCustomObject]@{
            Readable = $false
            Exists   = $null
            Value    = $null
            Error    = $_.Exception.Message
        }
    }
}

function Set-ServiceStart {
    param(
        [Parameter(Mandatory)][string]$Service,
        [Parameter(Mandatory)][ValidateSet('Boot','System','Automatic','Manual','Disabled')][string]$State
    )

    $result = New-DefenderActionResult -Name "ServiceStart:$Service" -Simulation:$WhatIfPreference
    $target = "Service:${Service}:Start"
    if ($script:RefuseTouchServices -contains $Service) {
        Write-Log "REFUSED firewall/network service: $Service" ERROR
        Add-DefenderEffect -Result $result -Target $target -Attempted $false -Changed $false `
            -Verified $false -Evidence @{ Expected = $State; Actual = 'Refused' } `
            -Errors "Refused protected Firewall/network service: $Service"
        return (Complete-DefenderActionResult -Result $result)
    }

    $map = @{ Boot=0; System=1; Automatic=2; Manual=3; Disabled=4 }
    $value = $map[$State]
    $subKey  = "SYSTEM\CurrentControlSet\Services\$Service"
    $regPath = "HKLM:\$subKey"
    $before = Get-DefenderServiceStartState -RegistryPath $regPath
    if (-not $before.Readable) {
        Add-DefenderEffect -Result $result -Target $target -Attempted $false -Changed $false `
            -Verified $false -Evidence @{ Expected = $State; Actual = 'Unknown' } -Errors $before.Error
        return (Complete-DefenderActionResult -Result $result)
    }
    if (-not $before.Exists) {
        Write-Log "Service $Service not present, skipping." DEBUG
        Add-DefenderEffect -Result $result -Target $target -Required $false `
            -Attempted $false -Changed $false -Verified $true `
            -Evidence @{ Expected = 'NotApplicable'; Actual = 'Absent' }
        return (Complete-DefenderActionResult -Result $result)
    }
    if ($before.Value -eq $value) {
        Add-DefenderEffect -Result $result -Target $target -Attempted $false -Changed $false `
            -Verified $true -Evidence @{ Expected = $State; Actual = $State; State = 'AlreadyCorrect' }
        return (Complete-DefenderActionResult -Result $result)
    }
    if ($WhatIfPreference) {
        Add-DefenderEffect -Result $result -Target $target -Required $false `
            -Attempted $false -Changed $false -Verified $false `
            -Evidence @{ Expected = $State; ActualValue = $before.Value; State = 'Simulation' }
        return (Complete-DefenderActionResult -Result $result)
    }

    if (Test-RestoreManifestRecording) {
        $stateMap = @{
            '0' = 'Boot'
            '1' = 'System'
            '2' = 'Automatic'
            '3' = 'Manual'
            '4' = 'Disabled'
        }
        $startKey = [string]$before.Value
        if ($stateMap.ContainsKey($startKey)) {
            Write-RestoreManifestEntry -Phase 'Services' -Action 'SetServiceStart' -Target $Service -Data ([ordered]@{
                Service = $Service
                State   = $stateMap[$startKey]
            })
        }
    }

    $attempts = New-Object System.Collections.ArrayList
    # 1. Direct write
    try {
        Set-ItemProperty -LiteralPath $regPath -Name 'Start' -Value $value -Type DWord -ErrorAction Stop
        [void]$attempts.Add([PSCustomObject]@{ Method = 'Direct'; Error = $null })
        if (Test-ServiceStartValue -RegistryPath $regPath -ExpectedValue $value) {
            Write-Log "Service $Service Start=$State (direct)." DEBUG
            Add-DefenderEffect -Result $result -Target $target -Attempted $true -Changed $true `
                -Verified $true -Evidence @{ Expected = $State; Actual = $State; Method = 'Direct'; Attempts = @($attempts) }
            return (Complete-DefenderActionResult -Result $result)
        }
        Write-Log "Service $Service direct Start=$State write did not persist." DEBUG
    } catch {
        [void]$attempts.Add([PSCustomObject]@{ Method = 'Direct'; Error = $_.Exception.Message })
    }

    # 2. ACL takeover -> direct write
    if (Grant-RegKeyControl -SubKey $subKey) {
        try {
            Set-ItemProperty -LiteralPath $regPath -Name 'Start' -Value $value -Type DWord -ErrorAction Stop
            [void]$attempts.Add([PSCustomObject]@{ Method = 'AclTakeover'; Error = $null })
            if (Test-ServiceStartValue -RegistryPath $regPath -ExpectedValue $value) {
                Write-Log "Service $Service Start=$State (ACL takeover)." DEBUG
                Add-DefenderEffect -Result $result -Target $target -Attempted $true -Changed $true `
                    -Verified $true -Evidence @{ Expected = $State; Actual = $State; Method = 'AclTakeover'; Attempts = @($attempts) }
                return (Complete-DefenderActionResult -Result $result)
            }
            Write-Log "Service $Service ACL Start=$State write did not persist." DEBUG
        } catch {
            [void]$attempts.Add([PSCustomObject]@{ Method = 'AclTakeover'; Error = $_.Exception.Message })
        }
    }

    # 3. SYSTEM via scheduled task
    if (Invoke-AsSystem -Execute 'reg.exe' -Argument "add `"HKLM\$subKey`" /v Start /t REG_DWORD /d $value /f") {
        Start-Sleep -Milliseconds 500
        [void]$attempts.Add([PSCustomObject]@{ Method = 'SystemTask'; Error = $null })
        if (Test-ServiceStartValue -RegistryPath $regPath -ExpectedValue $value) {
            Write-Log "Service $Service Start=$State (SYSTEM task)." DEBUG
            Add-DefenderEffect -Result $result -Target $target -Attempted $true -Changed $true `
                -Verified $true -Evidence @{ Expected = $State; Actual = $State; Method = 'SystemTask'; Attempts = @($attempts) }
            return (Complete-DefenderActionResult -Result $result)
        }
        Write-Log "Service $Service SYSTEM Start=$State write did not persist." WARN
    } else {
        [void]$attempts.Add([PSCustomObject]@{ Method = 'SystemTask'; Error = 'SYSTEM task failed.' })
    }

    $after = Get-DefenderServiceStartState -RegistryPath $regPath
    $actual = if ($after.Readable -and $after.Exists) { $after.Value } else { 'Unknown' }
    Write-Log "Service $Service could not be set to $State. Boot to Safe Mode for full effect." WARN
    Add-DefenderEffect -Result $result -Target $target -Attempted $true -Changed $false `
        -Verified $false -Evidence @{ Expected = $State; ActualValue = $actual; Attempts = @($attempts) } `
        -Errors "Service $Service Start value did not converge to $State."
    return (Complete-DefenderActionResult -Result $result)
}

function Get-TargetServices {
    $list = [System.Collections.ArrayList]::new($script:DefenderServices)
    if ($script:IncludeMDEMode) {
        foreach ($s in $script:MDEServices) { [void]$list.Add($s) }
        Write-Log "MDE services included in target list (Sense)." WARN
    }
    return $list.ToArray()
}

function Get-DefenderServiceRuntimeState {
    param(
        [Parameter(Mandatory)][string]$Service
    )

    try {
        $item = Get-Service -Name $Service -ErrorAction Stop
        return [PSCustomObject]@{
            Readable = $true
            Exists   = $true
            Status   = [string]$item.Status
            CanStop  = [bool]$item.CanStop
            Error    = $null
        }
    } catch {
        if ($_.CategoryInfo.Category -eq 'ObjectNotFound' -or
            $_.Exception.Message -match 'cannot find|does not exist|not found') {
            return [PSCustomObject]@{
                Readable = $true
                Exists   = $false
                Status   = 'Absent'
                CanStop  = $false
                Error    = $null
            }
        }
        return [PSCustomObject]@{
            Readable = $false
            Exists   = $null
            Status   = 'Unknown'
            CanStop  = $null
            Error    = $_.Exception.Message
        }
    }
}

function Invoke-DefenderServiceStop {
    param(
        [Parameter(Mandatory)][string]$Service
    )

    & sc.exe stop $Service 2>&1 | Out-Null
    return [int]$LASTEXITCODE
}

function Disable-DefenderServices {
    $targets = Get-TargetServices
    $result = New-DefenderActionResult -Name 'DefenderServices:Disable' -Simulation:$WhatIfPreference
    Write-Log "Stopping Defender services..." INFO
    foreach ($s in $targets) {
        $before = Get-DefenderServiceRuntimeState -Service $s
        if (-not $before.Readable) {
            Add-DefenderEffect -Result $result -Target "Service:${s}:Runtime" `
                -Attempted $false -Changed $false -Verified $false `
                -Evidence @{ Expected = 'Stopped'; Actual = 'Unknown' } -Errors $before.Error
            continue
        }
        if (-not $before.Exists) {
            Add-DefenderEffect -Result $result -Target "Service:${s}:Runtime" -Required $false `
                -Attempted $false -Changed $false -Verified $true `
                -Evidence @{ Expected = 'NotApplicable'; Actual = 'Absent' }
            continue
        }
        if ($before.Status -eq 'Stopped') {
            Add-DefenderEffect -Result $result -Target "Service:${s}:Runtime" `
                -Attempted $false -Changed $false -Verified $true `
                -Evidence @{ Expected = 'Stopped'; Actual = 'Stopped'; State = 'AlreadyCorrect' }
            continue
        }
        if (-not $before.CanStop) {
            Add-DefenderEffect -Result $result -Target "Service:${s}:Runtime" -Required $false `
                -Attempted $false -Changed $false -Verified $false `
                -Evidence @{ Expected = 'StoppedAfterReboot'; Actual = $before.Status; State = 'NonStoppable' }
            continue
        }
        if ($WhatIfPreference) {
            Add-DefenderEffect -Result $result -Target "Service:${s}:Runtime" -Required $false `
                -Attempted $false -Changed $false -Verified $false `
                -Evidence @{ Expected = 'Stopped'; Actual = $before.Status; State = 'Simulation' }
            continue
        }

        if (Test-RestoreManifestRecording) {
            if ($before.Status -eq 'Running') {
                Write-RestoreManifestEntry -Phase 'Services' -Action 'StartService' -Target $s -Data ([ordered]@{
                    Service = $s
                })
            }
        }

        $exitCode = Invoke-DefenderServiceStop -Service $s
        Start-Sleep -Milliseconds 300
        $after = Get-DefenderServiceRuntimeState -Service $s
        $verified = $after.Readable -and $after.Exists -and $after.Status -eq 'Stopped'
        $errors = if ($verified) {
            @()
        } elseif ($exitCode -ne 0) {
            @("sc.exe stop exited $exitCode and the service remained $($after.Status).")
        } else {
            @("Service remained $($after.Status) after a successful stop request.")
        }
        Add-DefenderEffect -Result $result -Target "Service:${s}:Runtime" `
            -Attempted $true -Changed $verified -Verified $verified `
            -Evidence @{ Expected = 'Stopped'; Actual = $after.Status; NativeExitCode = $exitCode } -Errors $errors
    }

    foreach ($s in $targets) {
        $childResult = Set-ServiceStart -Service $s -State Disabled
        Merge-DefenderActionResult -Result $result -ChildResult $childResult
    }
    Save-AclBackup
    $completed = Complete-DefenderActionResult -Result $result
    $level = if ($completed.Succeeded) { 'OK' } else { 'WARN' }
    Write-Log "Service result: attempted=$($completed.Attempted) changed=$($completed.Changed) verified=$($completed.Verified) errors=$(@($completed.Errors).Count)." $level
    return $completed
}

function Restore-DefenderServices {
    Write-Log "Restoring default Defender service start types..." INFO
    $result = New-DefenderActionResult -Name 'DefenderServices:Restore' -Simulation:$WhatIfPreference
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
        $childResult = Set-ServiceStart -Service $k -State $defaults[$k]
        Merge-DefenderActionResult -Result $result -ChildResult $childResult
    }
    $completed = Complete-DefenderActionResult -Result $result
    $level = if ($completed.Succeeded) { 'OK' } else { 'WARN' }
    Write-Log "Service restore result: attempted=$($completed.Attempted) changed=$($completed.Changed) verified=$($completed.Verified) errors=$(@($completed.Errors).Count)." $level
    return $completed
}
