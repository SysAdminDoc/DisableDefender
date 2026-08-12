function Invoke-RemoveDefender {
    <#
    .SYNOPSIS
        Aggressively removes Microsoft Defender Antivirus (includes SecHealthUI deprovision,
        SafeBoot trap, DISM package removal). Best run from Safe Mode.
    .DESCRIPTION
        Performs everything Invoke-DisableDefender does, plus:
          - Removes SafeBoot\WinDefend entries so Defender cannot load in Safe Mode
          - Deprovisions the Microsoft.SecHealthUI Appx package
          - DISM-removes Defender platform packages
          - Removes Defender context menu entries
        Firewall is verified intact before and after.
    .PARAMETER Force
        Bypass Tamper Protection, managed-device, and Safe Mode safety gates.
    .PARAMETER NoRestorePoint
        Skip creating a System Restore checkpoint.
    .PARAMETER IncludeMDE
        Also disable the Sense (MDE/EDR) service.
    .PARAMETER Silent
        Suppress console output and prompts.
    .PARAMETER LogPath
        Override the default log file path.
    .PARAMETER Only
        Run only the named action phase keys. Prerequisite, Safe Mode,
        managed/domain, restore-point, and Firewall gates always run.
    .PARAMETER Skip
        Skip the named action phase keys. Safety gates cannot be skipped.
    .PARAMETER AllowRemoting
        Allow execution inside PSRemoting / PSSession contexts.
    .EXAMPLE
        Invoke-RemoveDefender -Force
    .EXAMPLE
        Invoke-RemoveDefender -Force -NoRestorePoint -IncludeMDE
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$Force,
        [switch]$NoRestorePoint,
        [switch]$IncludeMDE,
        [switch]$AllowRemoting,
        [switch]$Silent,
        [string]$LogPath,
        [ValidateSet('Policies','MpPreference','Tasks','Services','SafeBoot','Appx','DISM','ContextMenu')]
        [string[]]$Only,
        [ValidateSet('Policies','MpPreference','Tasks','Services','SafeBoot','Appx','DISM','ContextMenu')]
        [string[]]$Skip,
        [scriptblock]$LogCallback,
        [scriptblock]$CancellationCallback
    )

    $phases = @(
        New-DefenderPhase -Name 'Policy keys' -Key 'Policies' -RequiresResult -Action { Set-DefenderPolicy }
        New-DefenderPhase -Name 'MpPreference' -Key 'MpPreference' -RequiresResult -Action { Set-MpRuntimePrefs }
        New-DefenderPhase -Name 'Scheduled tasks' -Key 'Tasks' -RequiresResult -Action { Disable-DefenderTasks }
        New-DefenderPhase -Name 'Services' -Key 'Services' -RequiresResult -Action { Disable-DefenderServices }
        New-DefenderPhase -Name 'SafeBoot' -Key 'SafeBoot' -RequiresResult -Action { Remove-SafeBootWinDefend }
        New-DefenderPhase -Name 'SecHealthUI' -Key 'Appx' -RequiresResult -Action { Remove-SecHealthUI }
        New-DefenderPhase -Name 'DISM packages' -Key 'DISM' -RequiresResult -Action { Remove-DefenderPlatformPackages }
        New-DefenderPhase -Name 'Context menu' -Key 'ContextMenu' -RequiresResult -Action { Remove-DefenderContextMenu }
    )
    Assert-DefenderActionPhaseSelection -Phases $phases -Only $Only -Skip $Skip

    $shouldProcess = $PSCmdlet.ShouldProcess('Microsoft Defender', 'Remove')
    if (-not $shouldProcess -and -not $WhatIfPreference) { return }

    Set-RunOptions -Force:$Force -NoRestorePoint:$NoRestorePoint -IncludeMDE:$IncludeMDE -AllowRemoting:$AllowRemoting -Silent:$Silent -LogPath $LogPath -LogCallback $LogCallback -CancellationCallback $CancellationCallback
    Confirm-LocalSession -Mode Remove

    Start-RestoreManifest -Mode Remove
    try {
        $preflightPhases = @(
            New-DefenderPhase -Name 'Prerequisites' -Key 'Prerequisites' -Action { Confirm-Prereqs }
            New-DefenderPhase -Name 'Firewall preflight' -Key 'FirewallPreflight' -Action { Assert-FirewallSafety -Stage pre }
            New-DefenderPhase -Name 'Safe Mode gate' -Key 'SafeModeGate' -Action {
                if (-not $script:InSafeMode -and -not $script:ForceMode) {
                    Write-Log "Remove mode works best in Safe Mode. Reboot into Safe Mode and rerun, or pass -Force." WARN
                    throw 'Remove mode requires Safe Mode or -Force.'
                }
            }
            New-DefenderPhase -Name 'Known-bad override gate' -Key 'KnownBadGate' -Action { Confirm-RemoveKnownBadOverrides }
            New-DefenderPhase -Name 'Restore point' -Key 'RestorePoint' -RequiresResult -Action { New-SafetyRestorePoint }
        )
        $postflightPhases = @(
            New-DefenderPhase -Name 'Firewall postflight' -Key 'FirewallPostflight' -Action { Assert-FirewallSafety -Stage post }
        )
        $operationResult = Invoke-DefenderGuardedPhasePlan -Mode Remove -Phases $phases `
            -PreflightPhases $preflightPhases -PostflightPhases $postflightPhases `
            -Only $Only -Skip $Skip
        $hasMutationEvidence = @($operationResult.Phases | Where-Object {
            $null -ne $_.Result
        }).Count -gt 0
        if (-not $operationResult.Simulation -and $hasMutationEvidence) {
            Save-DefenderSurfaceBaseline -Mode Remove
        }
        Write-Log "Remove complete. Reboot required." OK
        return $operationResult
    } finally {
        Stop-RestoreManifest
    }
}
