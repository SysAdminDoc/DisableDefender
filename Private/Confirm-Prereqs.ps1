# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
function Test-LanguageMode {
    $mode = $ExecutionContext.SessionState.LanguageMode
    return [string]$mode
}

function Test-AppControlPolicy {
    try {
        $sacPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Protected'
        if (Test-Path -LiteralPath $sacPath) {
            $sacVal = (Get-ItemProperty -LiteralPath $sacPath -Name 'VerifiedAndReputablePolicyState' -ErrorAction SilentlyContinue).VerifiedAndReputablePolicyState
            if ($sacVal -eq 1) { return 'Enforcing' }
            if ($sacVal -eq 2) { return 'Evaluation' }
        }
    } catch {}
    try {
        $ciPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy'
        if (Test-Path -LiteralPath $ciPath) {
            $enforced = (Get-ItemProperty -LiteralPath $ciPath -Name 'VerifiedAndReputablePolicyStateMinutes' -ErrorAction SilentlyContinue)
            if ($enforced) { return 'Present' }
        }
    } catch {}
    return 'Off'
}

function Confirm-LanguageAndAppControl {
    $langMode = Test-LanguageMode
    Write-Log "PowerShell language mode: $langMode" INFO

    $sacStatus = Test-AppControlPolicy
    if ($sacStatus -ne 'Off') {
        Write-Log "Smart App Control / App Control: $sacStatus" WARN
    }

    if ($langMode -eq 'ConstrainedLanguage') {
        Write-Log "ConstrainedLanguage mode blocks Add-Type, WPF/XAML, and .NET interop required by this tool." ERROR
        Write-Log "Remediation: run from FullLanguage mode, sign the scripts with a trusted certificate, or use the offline remove bundle (New-OfflineRemoveBundle) which operates on registry hives directly." WARN
        if (-not $script:ForceMode) {
            throw "ConstrainedLanguage mode is not supported. Use -Force to attempt anyway (may fail on Add-Type/WPF operations)."
        }
    } elseif ($langMode -ne 'FullLanguage') {
        Write-Log "Unexpected PowerShell language mode: $langMode. This tool requires FullLanguage." WARN
        if (-not $script:ForceMode) {
            throw "PowerShell language mode '$langMode' is not supported. Use -Force to attempt anyway."
        }
    } else {
        Write-Log "PowerShell language mode: FullLanguage" OK
    }
}

function Confirm-Prereqs {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        Write-Log "Windows: $($os.Caption) build $($os.Version)" INFO
    } catch {}
    try {
        $mpVer = (Get-MpComputerStatus -ErrorAction Stop).AMProductVersion
        if ($mpVer) { Write-Log "Defender platform: $mpVer" INFO }
    } catch {}

    Confirm-LanguageAndAppControl

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
