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
        Run only the named phase keys.
    .PARAMETER Skip
        Skip the named phase keys.
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
        [ValidateSet('Prerequisites','FirewallPreflight','FirewallPostflight','RestorePoint','Policies','MpPreference','Tasks','Services','SafeBoot','Appx','DISM','ContextMenu')]
        [string[]]$Only,
        [ValidateSet('Prerequisites','FirewallPreflight','FirewallPostflight','RestorePoint','Policies','MpPreference','Tasks','Services','SafeBoot','Appx','DISM','ContextMenu')]
        [string[]]$Skip,
        [scriptblock]$LogCallback
    )

    if (-not $PSCmdlet.ShouldProcess('Microsoft Defender', 'Remove')) { return }

    Set-RunOptions -Force:$Force -NoRestorePoint:$NoRestorePoint -IncludeMDE:$IncludeMDE -AllowRemoting:$AllowRemoting -Silent:$Silent -LogPath $LogPath -LogCallback $LogCallback
    Confirm-LocalSession -Mode Remove

    Start-RestoreManifest -Mode Remove
    try {
        $phases = @(
            New-DefenderPhase -Name 'Prerequisites' -Key 'Prerequisites' -Action { Confirm-Prereqs }
            New-DefenderPhase -Name 'Firewall preflight' -Key 'FirewallPreflight' -Action { Assert-FirewallSafety -Stage pre }
            New-DefenderPhase -Name 'Safe Mode gate' -Key 'SafeModeGate' -Action {
                if (-not $script:InSafeMode -and -not $script:ForceMode) {
                    Write-Log "Remove mode works best in Safe Mode. Reboot into Safe Mode and rerun, or pass -Force." WARN
                    throw 'Remove mode requires Safe Mode or -Force.'
                }
            }
            New-DefenderPhase -Name 'Known-bad override gate' -Key 'KnownBadGate' -Action { Confirm-RemoveKnownBadOverrides }
            New-DefenderPhase -Name 'Restore point' -Key 'RestorePoint' -Action { New-SafetyRestorePoint }
            New-DefenderPhase -Name 'Policy keys' -Key 'Policies' -Action { Set-DefenderPolicy }
            New-DefenderPhase -Name 'MpPreference' -Key 'MpPreference' -Action { Set-MpRuntimePrefs }
            New-DefenderPhase -Name 'Scheduled tasks' -Key 'Tasks' -Action { Disable-DefenderTasks }
            New-DefenderPhase -Name 'Services' -Key 'Services' -Action { Disable-DefenderServices }
            New-DefenderPhase -Name 'SafeBoot' -Key 'SafeBoot' -Action { Remove-SafeBootWinDefend }
            New-DefenderPhase -Name 'SecHealthUI' -Key 'Appx' -Action { Remove-SecHealthUI }
            New-DefenderPhase -Name 'DISM packages' -Key 'DISM' -Action { Remove-DefenderPlatformPackages }
            New-DefenderPhase -Name 'Context menu' -Key 'ContextMenu' -Action { Remove-DefenderContextMenu }
            New-DefenderPhase -Name 'Firewall postflight' -Key 'FirewallPostflight' -Action { Assert-FirewallSafety -Stage post }
        )
        Invoke-DefenderPhasePlan -Mode Remove -Phases $phases -Only $Only -Skip $Skip
        Save-DefenderSurfaceBaseline -Mode Remove
        Write-Log "Remove complete. Reboot required." OK
    } finally {
        Stop-RestoreManifest
    }
}
