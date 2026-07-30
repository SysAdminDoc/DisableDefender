function Invoke-DisableDefender {
    <#
    .SYNOPSIS
        Reversibly disables Microsoft Defender Antivirus while preserving the Windows Firewall.
    .DESCRIPTION
        Applies Defender policy keys, Set-MpPreference flags, disables scheduled tasks,
        stops and disables Defender services. Firewall services are on a refuse-list and
        verified intact before and after the operation. A System Restore point is created
        unless -NoRestorePoint is passed.
    .PARAMETER Force
        Bypass Tamper Protection and managed-device safety gates.
    .PARAMETER NoRestorePoint
        Skip creating a System Restore checkpoint.
    .PARAMETER IncludeMDE
        Also disable the Sense (MDE/EDR) service. Blinds enterprise SOC monitoring.
    .PARAMETER Silent
        Suppress console output while still writing the log file.
    .PARAMETER LogPath
        Override the default log file path.
    .PARAMETER Only
        Run only the named action phase keys. Safety gates and Firewall checks
        always run.
    .PARAMETER Skip
        Skip the named action phase keys. Safety gates and Firewall checks
        cannot be skipped.
    .PARAMETER AllowRemoting
        Allow execution inside PSRemoting / PSSession contexts.
    .EXAMPLE
        Invoke-DisableDefender
    .EXAMPLE
        Invoke-DisableDefender -Force -NoRestorePoint
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$Force,
        [switch]$NoRestorePoint,
        [switch]$IncludeMDE,
        [switch]$AllowRemoting,
        [switch]$Silent,
        [string]$LogPath,
        [ValidateSet('Policies','MpPreference','Tasks','Services')]
        [string[]]$Only,
        [ValidateSet('Policies','MpPreference','Tasks','Services')]
        [string[]]$Skip,
        [scriptblock]$LogCallback
    )

    $phases = @(
        New-DefenderPhase -Name 'Policy keys' -Key 'Policies' -RequiresResult -Action { Set-DefenderPolicy }
        New-DefenderPhase -Name 'MpPreference' -Key 'MpPreference' -RequiresResult -Action { Set-MpRuntimePrefs }
        New-DefenderPhase -Name 'Scheduled tasks' -Key 'Tasks' -RequiresResult -Action { Disable-DefenderTasks }
        New-DefenderPhase -Name 'Services' -Key 'Services' -RequiresResult -Action { Disable-DefenderServices }
    )
    Assert-DefenderActionPhaseSelection -Phases $phases -Only $Only -Skip $Skip

    $shouldProcess = $PSCmdlet.ShouldProcess('Microsoft Defender', 'Disable')
    if (-not $shouldProcess -and -not $WhatIfPreference) { return }

    Set-RunOptions -Force:$Force -NoRestorePoint:$NoRestorePoint -IncludeMDE:$IncludeMDE -AllowRemoting:$AllowRemoting -Silent:$Silent -LogPath $LogPath -LogCallback $LogCallback
    Confirm-LocalSession -Mode Disable

    Start-RestoreManifest -Mode Disable
    try {
        $preflightPhases = @(
            New-DefenderPhase -Name 'Prerequisites' -Key 'Prerequisites' -Action { Confirm-Prereqs }
            New-DefenderPhase -Name 'Firewall preflight' -Key 'FirewallPreflight' -Action { Assert-FirewallSafety -Stage pre }
            New-DefenderPhase -Name 'Restore point' -Key 'RestorePoint' -RequiresResult -Action { New-SafetyRestorePoint }
        )
        $postflightPhases = @(
            New-DefenderPhase -Name 'Firewall postflight' -Key 'FirewallPostflight' -Action { Assert-FirewallSafety -Stage post }
        )
        $operationResult = Invoke-DefenderGuardedPhasePlan -Mode Disable -Phases $phases `
            -PreflightPhases $preflightPhases -PostflightPhases $postflightPhases `
            -Only $Only -Skip $Skip
        $hasMutationEvidence = @($operationResult.Phases | Where-Object {
            $null -ne $_.Result
        }).Count -gt 0
        if (-not $operationResult.Simulation -and $hasMutationEvidence) {
            Save-DefenderSurfaceBaseline -Mode Disable
        }
        Write-Log "Disable complete. Reboot recommended." OK
        return $operationResult
    } finally {
        Stop-RestoreManifest
    }
}
