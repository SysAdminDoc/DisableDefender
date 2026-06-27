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

function New-SafetyRestorePoint {
    if ($script:NoRestorePointMode) { return }
    if ($WhatIfPreference) { Write-Log "WhatIf: would create System Restore point" INFO; return }
    try {
        Enable-ComputerRestore -Drive $env:SystemDrive -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description "$script:AppName v$script:Version pre-op" -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Write-Log "System Restore point created." OK
    } catch {
        $message = $_.Exception.Message
        if (Test-SystemRestoreThrottleError -Message $message) {
            $minutes = Get-SystemRestoreThrottleMinutes
            Write-Log "System Restore point skipped by Windows throttle interval ($minutes minutes). Existing restore point cadence is being honored. Details: $message" WARN
        } else {
            Write-Log "Could not create restore point: $message" WARN
        }
    }
}
