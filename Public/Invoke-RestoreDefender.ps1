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
        Assert-FirewallSafety -Stage pre
        Invoke-RestoreManifest | Out-Null
        Clear-DefenderPolicy
        Clear-MpRuntimePrefs
        Enable-DefenderTasks
        Restore-DefenderServices
        Restore-RegKeyACLs
        Restore-SecHealthUI
        Restore-DefenderContextMenu
        Assert-FirewallSafety -Stage post
        Write-Log "Restore complete. Reboot recommended. If Defender does not come back: sfc /scannow then DISM /Online /Cleanup-Image /RestoreHealth." OK
    } finally {
        $script:RestoreManifestReplayMode = $previousReplayMode
    }
}
