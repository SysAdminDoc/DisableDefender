# ---------------------------------------------------------------------------
# Tamper Protection check
# ---------------------------------------------------------------------------
function Test-TamperProtection {
    try {
        $s = Get-MpComputerStatus -ErrorAction Stop
        return [bool]$s.IsTamperProtected
    } catch { return $null }
}

function Get-SystemRestoreThrottleMinutes {
    $path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    try {
        $value = (Get-ItemProperty -LiteralPath $path -Name 'SystemRestorePointCreationFrequency' -ErrorAction Stop).SystemRestorePointCreationFrequency
        return [int]$value
    } catch {
        return 1440
    }
}

function Test-SystemRestoreThrottleError {
    param(
        [Parameter(Mandatory)][string]$Message
    )

    return ($Message -match 'restore point.*already.*created' -or
            $Message -match 'SystemRestorePointCreationFrequency' -or
            $Message -match 'frequency.*restore point' -or
            $Message -match 'past\s+\d+\s+minutes')
}

function Get-LatestDefenderRestorePoint {
    try {
        return Get-ComputerRestorePoint -ErrorAction Stop |
            Sort-Object -Property SequenceNumber -Descending |
            Select-Object -First 1
    } catch {
        return $null
    }
}

function New-SafetyRestorePoint {
    $result = New-DefenderActionResult -Name 'SystemRestorePoint' -Simulation:$WhatIfPreference
    if ($script:NoRestorePointMode) {
        Add-DefenderEffect -Result $result -Target 'SystemRestorePoint' -Required $false `
            -Attempted $false -Changed $false -Verified $true `
            -Evidence @{ Expected = 'ExplicitlySkipped'; Actual = 'NoRestorePoint' }
        return (Complete-DefenderActionResult -Result $result)
    }
    if ($WhatIfPreference) {
        Write-Log "WhatIf: would create System Restore point" INFO
        Add-DefenderEffect -Result $result -Target 'SystemRestorePoint' -Required $false `
            -Attempted $false -Changed $false -Verified $false `
            -Evidence @{ Expected = 'Created'; Actual = 'Simulation' }
        return (Complete-DefenderActionResult -Result $result)
    }

    $before = Get-LatestDefenderRestorePoint
    $description = "$script:AppName v$script:Version pre-op"
    try {
        Enable-ComputerRestore -Drive $env:SystemDrive -ErrorAction Stop
        Checkpoint-Computer -Description $description -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        $after = Get-LatestDefenderRestorePoint
        $verified = $null -ne $after -and
            $after.Description -eq $description -and
            ($null -eq $before -or [int64]$after.SequenceNumber -gt [int64]$before.SequenceNumber)
        Add-DefenderEffect -Result $result -Target 'SystemRestorePoint' -Attempted $true `
            -Changed $verified -Verified $verified `
            -Evidence @{
                Expected       = $description
                Actual         = if ($null -ne $after) { $after.Description } else { 'Unavailable' }
                BeforeSequence = if ($null -ne $before) { $before.SequenceNumber } else { $null }
                AfterSequence  = if ($null -ne $after) { $after.SequenceNumber } else { $null }
            } -Errors $(if ($verified) { @() } else { @('The new System Restore point could not be verified.') })
        if ($verified) { Write-Log "System Restore point created and verified." OK }
    } catch {
        $message = $_.Exception.Message
        if (Test-SystemRestoreThrottleError -Message $message) {
            $minutes = Get-SystemRestoreThrottleMinutes
            Write-Log "System Restore point skipped by Windows throttle interval ($minutes minutes). Existing restore point cadence is being honored. Details: $message" WARN
            $latest = Get-LatestDefenderRestorePoint
            $verified = $null -ne $latest
            Add-DefenderEffect -Result $result -Target 'SystemRestorePoint' -Required $verified `
                -Attempted $true -Changed $false -Verified $verified `
                -Evidence @{
                    Expected        = 'ExistingRestorePoint'
                    Actual          = if ($verified) { $latest.Description } else { 'Unavailable' }
                    Sequence        = if ($verified) { $latest.SequenceNumber } else { $null }
                    ThrottleMinutes = $minutes
                } -Errors $(if ($verified) { @() } else { @('Windows throttled creation and no existing restore point could be verified.') })
        } else {
            Write-Log "Could not create restore point: $message" WARN
            Add-DefenderEffect -Result $result -Target 'SystemRestorePoint' -Attempted $true `
                -Changed $false -Verified $false `
                -Evidence @{ Expected = 'Created'; Actual = 'Failed' } -Errors $message
        }
    }
    return (Complete-DefenderActionResult -Result $result)
}
