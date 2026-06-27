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
        [switch]$Silent,
        [string]$LogPath,
        [scriptblock]$LogCallback
    )

    if (-not $PSCmdlet.ShouldProcess('Microsoft Defender', 'Disable')) { return }

    Set-RunOptions -Force:$Force -NoRestorePoint:$NoRestorePoint -IncludeMDE:$IncludeMDE -Silent:$Silent -LogPath $LogPath -LogCallback $LogCallback

    Start-RestoreManifest -Mode Disable
    try {
        $phases = @(
            New-DefenderPhase -Name 'Prerequisites' -Action { Confirm-Prereqs }
            New-DefenderPhase -Name 'Firewall preflight' -Action { Assert-FirewallSafety -Stage pre }
            New-DefenderPhase -Name 'Restore point' -Action { New-SafetyRestorePoint }
            New-DefenderPhase -Name 'Policy keys' -Action { Set-DefenderPolicy }
            New-DefenderPhase -Name 'MpPreference' -Action { Set-MpRuntimePrefs }
            New-DefenderPhase -Name 'Scheduled tasks' -Action { Disable-DefenderTasks }
            New-DefenderPhase -Name 'Services' -Action { Disable-DefenderServices }
            New-DefenderPhase -Name 'Firewall postflight' -Action { Assert-FirewallSafety -Stage post }
        )
        Invoke-DefenderPhasePlan -Mode Disable -Phases $phases
        Write-Log "Disable complete. Reboot recommended." OK
    } finally {
        Stop-RestoreManifest
    }
}
