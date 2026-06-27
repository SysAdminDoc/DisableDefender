# ---------------------------------------------------------------------------
# Tamper Protection check
# ---------------------------------------------------------------------------
function Test-TamperProtection {
    try {
        $s = Get-MpComputerStatus -ErrorAction Stop
        return [bool]$s.IsTamperProtected
    } catch { return $null }
}

function New-SafetyRestorePoint {
    if ($script:NoRestorePointMode) { return }
    if ($WhatIfPreference) { Write-Log "WhatIf: would create System Restore point" INFO; return }
    try {
        Enable-ComputerRestore -Drive $env:SystemDrive -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description "$script:AppName v$script:Version pre-op" -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Write-Log "System Restore point created." OK
    } catch {
        Write-Log "Could not create restore point: $_" WARN
    }
}
