# ---------------------------------------------------------------------------
# Centralized exit-code table and JSON error envelope for CLI automation.
# ---------------------------------------------------------------------------

$script:ErrorCodeTable = @(
    [PSCustomObject]@{ Code = 'TAMPER_PROTECTION';    ExitCode = 2; Pattern = 'Tamper Protection';                    Repair = @('Toggle Tamper Protection off in Windows Security UI, then retry.') }
    [PSCustomObject]@{ Code = 'SAFE_MODE_REQUIRED';   ExitCode = 3; Pattern = 'Safe Mode';                            Repair = @('Boot to Safe Mode and rerun: .\DisableDefender.ps1 -Mode Remove', 'Or use -Force to proceed in normal boot.') }
    [PSCustomObject]@{ Code = 'FIREWALL_INTEGRITY';   ExitCode = 4; Pattern = 'Firewall';                             Repair = @('netsh advfirewall set allprofiles state on', 'sc.exe config mpssvc start= auto && sc.exe start mpssvc', 'sc.exe config BFE start= auto && sc.exe start BFE') }
    [PSCustomObject]@{ Code = 'MANAGED_DEVICE';       ExitCode = 5; Pattern = 'managed';                              Repair = @('Use -Force to proceed on managed devices.', 'Warning: may trigger compliance violations and conditional access revocation.') }
    [PSCustomObject]@{ Code = 'RESTORE_FAILED';       ExitCode = 6; Pattern = 'Restore verification failed';          Repair = @('.\DisableDefender.ps1 -Mode Health -HealthTarget Restore', 'Follow the repair commands in the health output.') }
    [PSCustomObject]@{ Code = 'PHASE_FILTER_EMPTY';   ExitCode = 7; Pattern = 'Phase filters selected no runnable';   Repair = @('Check -Only / -Skip values match available phase keys.') }
    [PSCustomObject]@{ Code = 'REMOTING_BLOCKED';     ExitCode = 8; Pattern = 'AllowRemoting';                        Repair = @('Use -AllowRemoting to allow execution in PSRemoting/PSSession contexts.') }
    [PSCustomObject]@{ Code = 'DOMAIN_JOINED';        ExitCode = 9; Pattern = 'DomainJoined';                         Repair = @('Use -Force to proceed on domain-joined machines.', 'Warning: may trigger SIEM alerts and compliance violations.') }
)

function Get-DefenderErrorMapping {
    param([Parameter(Mandatory)][string]$Message)

    foreach ($entry in $script:ErrorCodeTable) {
        if ($Message -match [regex]::Escape($entry.Pattern)) {
            return $entry
        }
    }
    return [PSCustomObject]@{ Code = 'UNKNOWN'; ExitCode = 1; Pattern = ''; Repair = @() }
}

function New-DefenderErrorEnvelope {
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Mode,
        [string]$FailedPhase,
        [string]$PhaseStatePath
    )

    $mapping = Get-DefenderErrorMapping -Message $Message

    return [ordered]@{
        Ok             = $false
        Mode           = if ($Mode) { $Mode } else { $null }
        ExitCode       = $mapping.ExitCode
        ErrorCode      = $mapping.Code
        Message        = $Message
        FailedPhase    = if ($FailedPhase) { $FailedPhase } else { $null }
        PhaseStatePath = if ($PhaseStatePath -and (Test-Path -LiteralPath $PhaseStatePath)) { $PhaseStatePath } else { $null }
        RepairCommands = @($mapping.Repair)
        Timestamp      = (Get-Date).ToString('o')
    }
}
