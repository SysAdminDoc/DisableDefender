# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
function Confirm-Prereqs {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        Write-Log "Windows: $($os.Caption) build $($os.Version)" INFO
    } catch {}
    try {
        $mpVer = (Get-MpComputerStatus -ErrorAction Stop).AMProductVersion
        if ($mpVer) { Write-Log "Defender platform: $mpVer" INFO }
    } catch {}

    $tp = Test-TamperProtection
    if ($tp -eq $true) {
        Write-Log "Tamper Protection is ON. Disable it first in Windows Security UI." ERROR
        if (-not $script:ForceMode) {
            throw "Tamper Protection blocks changes. Disable it manually, then retry. Use -Force to proceed anyway."
        }
    } elseif ($null -eq $tp) {
        Write-Log "Could not query Tamper Protection (Get-MpComputerStatus failed). Defender may already be partially removed." WARN
    } else {
        Write-Log "Tamper Protection is OFF." OK
    }
    $safe = (Get-CimInstance Win32_ComputerSystem).BootupState
    if ($safe -like '*Fail-safe*') {
        Write-Log "Running in Safe Mode - service registry edits should succeed." OK
        $script:InSafeMode = $true
    } else {
        $script:InSafeMode = $false
    }

    # Managed device detection -- warn about compliance/SIEM risks
    $managed = @()
    try {
        $dsreg = dsregcmd.exe /status 2>&1 | Out-String
        if ($dsreg -match 'MDMUrl\s*:\s*https://') { $managed += 'Intune/MDM enrolled' }
    } catch {}
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\CCM') { $managed += 'SCCM managed' }
    $senseSvc = Get-Service -Name 'Sense' -ErrorAction SilentlyContinue
    if ($senseSvc -and $senseSvc.Status -eq 'Running') { $managed += 'MDE onboarded (Sense running)' }
    if ($managed.Count -gt 0) {
        Write-Log "Managed device detected: $($managed -join '; '). Disabling Defender may trigger compliance violations, conditional access revocation, and SIEM alerts." WARN
        if (-not $script:ForceMode) {
            throw "This device is managed ($($managed -join '; ')). Use -Force to proceed anyway."
        }
    }
}
