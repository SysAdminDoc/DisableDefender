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
        [switch]$Silent,
        [string]$LogPath,
        [scriptblock]$LogCallback
    )

    if (-not $PSCmdlet.ShouldProcess('Microsoft Defender', 'Remove')) { return }

    Set-RunOptions -Force:$Force -NoRestorePoint:$NoRestorePoint -IncludeMDE:$IncludeMDE -Silent:$Silent -LogPath $LogPath -LogCallback $LogCallback

    Start-RestoreManifest -Mode Remove
    try {
        $phases = @(
            New-DefenderPhase -Name 'Prerequisites' -Action { Confirm-Prereqs }
            New-DefenderPhase -Name 'Firewall preflight' -Action { Assert-FirewallSafety -Stage pre }
            New-DefenderPhase -Name 'Safe Mode gate' -Action {
                if (-not $script:InSafeMode -and -not $script:ForceMode) {
                    Write-Log "Remove mode works best in Safe Mode. Reboot into Safe Mode and rerun, or pass -Force." WARN
                    throw 'Remove mode requires Safe Mode or -Force.'
                }
            }
            New-DefenderPhase -Name 'Restore point' -Action { New-SafetyRestorePoint }
            New-DefenderPhase -Name 'Policy keys' -Action { Set-DefenderPolicy }
            New-DefenderPhase -Name 'MpPreference' -Action { Set-MpRuntimePrefs }
            New-DefenderPhase -Name 'Scheduled tasks' -Action { Disable-DefenderTasks }
            New-DefenderPhase -Name 'Services' -Action { Disable-DefenderServices }
            New-DefenderPhase -Name 'SafeBoot' -Action { Remove-SafeBootWinDefend }
            New-DefenderPhase -Name 'SecHealthUI' -Action { Remove-SecHealthUI }
            New-DefenderPhase -Name 'DISM packages' -Action { Remove-DefenderPlatformPackages }
            New-DefenderPhase -Name 'Context menu' -Action { Remove-DefenderContextMenu }
            New-DefenderPhase -Name 'Firewall postflight' -Action { Assert-FirewallSafety -Stage post }
        )
        Invoke-DefenderPhasePlan -Mode Remove -Phases $phases
        Write-Log "Remove complete. Reboot required." OK
    } finally {
        Stop-RestoreManifest
    }
}
