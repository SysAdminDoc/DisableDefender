# ---------------------------------------------------------------------------
# Phase: policy keys (expanded w/ privacy.sexy findings)
# ---------------------------------------------------------------------------
function Set-DefenderPolicy {
    Write-Log "Applying Defender policy keys..." INFO
    $result = New-DefenderActionResult -Name 'DefenderPolicy' -Simulation:$WhatIfPreference

    try {
        $mpStatus = Get-MpComputerStatus -ErrorAction Stop
        if ($mpStatus.AMProductVersion) {
            $ver = [version]$mpStatus.AMProductVersion
            if ($ver -ge [version]'4.18.2007.8') {
                Write-Log "DisableAntiSpyware is a no-op on platform $($mpStatus.AMProductVersion) -- kept for legacy compatibility only." WARN
            }
        }
    } catch {}

    foreach ($entry in Get-DefenderPolicyCatalog) {
        $childResult = Set-RegValue $entry.Path $entry.Name $entry.Value
        Merge-DefenderActionResult -Result $result -ChildResult $childResult
    }

    $completed = Complete-DefenderActionResult -Result $result
    $level = if ($completed.Succeeded) { 'OK' } else { 'WARN' }
    Write-Log "Policy result: attempted=$($completed.Attempted) changed=$($completed.Changed) verified=$($completed.Verified) errors=$(@($completed.Errors).Count)." $level
    return $completed
}

function Clear-DefenderPolicy {
    Write-Log "Removing Defender policy keys..." INFO
    $result = New-DefenderActionResult -Name 'DefenderPolicyRestore' -Simulation:$WhatIfPreference
    $roots = @(
        $script:PolicyRoot, $script:RealTimeRoot, $script:SpynetRoot,
        $script:SignatureRoot, $script:ReportingRoot, $script:MpEngineRoot,
        $script:ScanRoot, $script:UXRoot, $script:NISRoot,
        $script:ATPRoot, $script:MRTRoot, $script:MsAntimalware
    )
    foreach ($r in $roots) {
        $exists = Test-Path -LiteralPath $r
        if ($WhatIfPreference) {
            Add-DefenderEffect -Result $result -Target $r -Attempted $false -Changed $false `
                -Verified (-not $exists) -Required (-not $exists) `
                -Evidence @{ Expected = 'Absent'; Actual = $(if ($exists) { 'Present' } else { 'Absent' }); State = 'Simulation' }
            continue
        }
        try {
            if ($exists) {
                Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction Stop
            }
            $verified = -not (Test-Path -LiteralPath $r)
            $errors = if ($verified) { @() } else { @('Registry policy root remained after removal.') }
            Add-DefenderEffect -Result $result -Target $r -Attempted $exists -Changed ($exists -and $verified) `
                -Verified $verified -Evidence @{ Expected = 'Absent'; Actual = $(if ($verified) { 'Absent' } else { 'Present' }) } `
                -Errors $errors
            if ($exists -and $verified) { Write-Log "Removed $r" DEBUG }
        } catch {
            Add-DefenderEffect -Result $result -Target $r -Attempted $true -Changed $false `
                -Verified $false -Evidence @{ Expected = 'Absent'; Actual = 'Unknown' } -Errors $_.Exception.Message
        }
    }

    $smartScreenState = Get-DefenderRegistryValueState -Path $script:SmartScreen -Name 'EnableSmartScreen'
    if ($WhatIfPreference) {
        Add-DefenderEffect -Result $result -Target "$($script:SmartScreen)\EnableSmartScreen" `
            -Attempted $false -Changed $false -Verified ($smartScreenState.Readable -and -not $smartScreenState.Exists) `
            -Required ($smartScreenState.Readable -and -not $smartScreenState.Exists) `
            -Evidence @{ Expected = 'Absent'; Actual = $(if ($smartScreenState.Exists) { $smartScreenState.Value } else { 'Absent' }); State = 'Simulation' }
    } else {
        try {
            if (-not $smartScreenState.Readable) {
                throw "Could not read current registry value: $($smartScreenState.Error)"
            }
            if ($smartScreenState.Exists) {
                Remove-ItemProperty -LiteralPath $script:SmartScreen -Name 'EnableSmartScreen' -ErrorAction Stop
            }
            $afterSmartScreen = Get-DefenderRegistryValueState -Path $script:SmartScreen -Name 'EnableSmartScreen'
            $verified = $afterSmartScreen.Readable -and -not $afterSmartScreen.Exists
            Add-DefenderEffect -Result $result -Target "$($script:SmartScreen)\EnableSmartScreen" `
                -Attempted $smartScreenState.Exists -Changed ($smartScreenState.Exists -and $verified) `
                -Verified $verified -Evidence @{ Expected = 'Absent'; Actual = $(if ($afterSmartScreen.Exists) { $afterSmartScreen.Value } else { 'Absent' }) } `
                -Errors $(if ($verified) { @() } else { @('SmartScreen policy value remained after removal.') })
        } catch {
            Add-DefenderEffect -Result $result -Target "$($script:SmartScreen)\EnableSmartScreen" `
                -Attempted $true -Changed $false -Verified $false -Evidence @{ Expected = 'Absent'; Actual = 'Unknown' } `
                -Errors $_.Exception.Message
        }
    }

    # Restore WMI Autologger entries
    $loggerRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger'
    foreach ($logger in @('DefenderApiLogger','DefenderAuditLogger')) {
        $lPath = Join-Path $loggerRoot $logger
        if (Test-Path -LiteralPath $lPath) {
            $childResult = Set-RegValue -Path $lPath -Name 'Start' -Value 1
            Merge-DefenderActionResult -Result $result -ChildResult $childResult
        } else {
            Add-DefenderEffect -Result $result -Target "$lPath\Start" -Attempted $false -Changed $false `
                -Verified $true -Evidence @{ Expected = 'NotApplicable'; Actual = 'PathAbsent' }
        }
    }

    $completed = Complete-DefenderActionResult -Result $result
    $level = if ($completed.Succeeded) { 'OK' } else { 'WARN' }
    Write-Log "Policy restore result: attempted=$($completed.Attempted) changed=$($completed.Changed) verified=$($completed.Verified) errors=$(@($completed.Errors).Count)." $level
    return $completed
}
