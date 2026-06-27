function Invoke-RestoreDefender {
    <#
    .SYNOPSIS
        Undoes all changes made by Invoke-DisableDefender or Invoke-RemoveDefender.
    .DESCRIPTION
        Clears Defender policy keys, restores MpPreference defaults, re-enables
        scheduled tasks, restores service start types, restores registry ACLs,
        reprovisions SecHealthUI, and restores context menu entries.
        Firewall is verified intact before and after.
    .EXAMPLE
        Invoke-RestoreDefender
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$Silent,
        [string]$LogPath,
        [scriptblock]$LogCallback
    )

    if (-not $PSCmdlet.ShouldProcess('Microsoft Defender', 'Restore')) { return }

    Set-RunOptions -Silent:$Silent -LogPath $LogPath -LogCallback $LogCallback

    $previousReplayMode = [bool]$script:RestoreManifestReplayMode
    $script:RestoreManifestReplayMode = $true
    try {
        $phases = @(
            New-DefenderPhase -Name 'Firewall preflight' -Action { Assert-FirewallSafety -Stage pre }
            New-DefenderPhase -Name 'Replay manifest' -Action { Invoke-RestoreManifest | Out-Null }
            New-DefenderPhase -Name 'Policy cleanup' -Action { Clear-DefenderPolicy }
            New-DefenderPhase -Name 'MpPreference cleanup' -Action { Clear-MpRuntimePrefs }
            New-DefenderPhase -Name 'Scheduled task restore' -Action { Enable-DefenderTasks }
            New-DefenderPhase -Name 'Service restore' -Action { Restore-DefenderServices }
            New-DefenderPhase -Name 'Registry ACL restore' -Action { Restore-RegKeyACLs }
            New-DefenderPhase -Name 'SecHealthUI restore' -Action { Restore-SecHealthUI }
            New-DefenderPhase -Name 'Context menu restore' -Action { Restore-DefenderContextMenu }
            New-DefenderPhase -Name 'Firewall postflight' -Action { Assert-FirewallSafety -Stage post }
        )
        Invoke-DefenderPhasePlan -Mode Restore -Phases $phases
        Write-Log "Restore complete. Reboot recommended. If Defender does not come back: sfc /scannow then DISM /Online /Cleanup-Image /RestoreHealth." OK
    } finally {
        $script:RestoreManifestReplayMode = $previousReplayMode
    }
}
