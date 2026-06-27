function Invoke-RestoreDefender {
    <#
    .SYNOPSIS
        Undoes all changes made by Invoke-DisableDefender or Invoke-RemoveDefender.
    .DESCRIPTION
        Clears Defender policy keys, restores MpPreference defaults, re-enables
        scheduled tasks, restores service start types, restores registry ACLs,
        reprovisions SecHealthUI, and restores context menu entries.
        Firewall is verified intact before and after.
    .PARAMETER Only
        Run only the named phase keys.
    .PARAMETER Skip
        Skip the named phase keys.
    .PARAMETER AllowRemoting
        Allow execution inside PSRemoting / PSSession contexts.
    .EXAMPLE
        Invoke-RestoreDefender
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$Silent,
        [switch]$AllowRemoting,
        [string]$LogPath,
        [ValidateSet('FirewallPreflight','FirewallPostflight','ReplayManifest','Policies','MpPreference','Tasks','Services','AclRestore','Appx','ContextMenu')]
        [string[]]$Only,
        [ValidateSet('FirewallPreflight','FirewallPostflight','ReplayManifest','Policies','MpPreference','Tasks','Services','AclRestore','Appx','ContextMenu')]
        [string[]]$Skip,
        [scriptblock]$LogCallback
    )

    if (-not $PSCmdlet.ShouldProcess('Microsoft Defender', 'Restore')) { return }

    Set-RunOptions -Silent:$Silent -AllowRemoting:$AllowRemoting -LogPath $LogPath -LogCallback $LogCallback
    Confirm-LocalSession -Mode Restore

    $previousReplayMode = [bool]$script:RestoreManifestReplayMode
    $script:RestoreManifestReplayMode = $true
    try {
        $phases = @(
            New-DefenderPhase -Name 'Firewall preflight' -Key 'FirewallPreflight' -Action { Assert-FirewallSafety -Stage pre }
            New-DefenderPhase -Name 'Replay manifest' -Key 'ReplayManifest' -Action { Invoke-RestoreManifest | Out-Null }
            New-DefenderPhase -Name 'Policy cleanup' -Key 'Policies' -Action { Clear-DefenderPolicy }
            New-DefenderPhase -Name 'MpPreference cleanup' -Key 'MpPreference' -Action { Clear-MpRuntimePrefs }
            New-DefenderPhase -Name 'Scheduled task restore' -Key 'Tasks' -Action { Enable-DefenderTasks }
            New-DefenderPhase -Name 'Service restore' -Key 'Services' -Action { Restore-DefenderServices }
            New-DefenderPhase -Name 'Registry ACL restore' -Key 'AclRestore' -Action { Restore-RegKeyACLs }
            New-DefenderPhase -Name 'SecHealthUI restore' -Key 'Appx' -Action { Restore-SecHealthUI }
            New-DefenderPhase -Name 'Context menu restore' -Key 'ContextMenu' -Action { Restore-DefenderContextMenu }
            New-DefenderPhase -Name 'Firewall postflight' -Key 'FirewallPostflight' -Action { Assert-FirewallSafety -Stage post }
        )
        Invoke-DefenderPhasePlan -Mode Restore -Phases $phases -Only $Only -Skip $Skip
        Write-Log "Restore complete. Reboot recommended. If Defender does not come back: sfc /scannow then DISM /Online /Cleanup-Image /RestoreHealth." OK
    } finally {
        $script:RestoreManifestReplayMode = $previousReplayMode
    }
}
