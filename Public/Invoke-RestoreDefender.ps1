function ConvertTo-ServiceConfigStartToken {
    param([AllowNull()][string]$StartType)

    switch ($StartType) {
        'Boot'      { return 'boot' }
        'System'    { return 'system' }
        'Automatic' { return 'auto' }
        'Manual'    { return 'demand' }
        'Disabled'  { return 'disabled' }
        default     { return 'demand' }
    }
}

function Get-RestoreRepairCommands {
    param(
        [Parameter(Mandatory)]$Item
    )

    switch ($Item.Category) {
        'Service' {
            $startToken = ConvertTo-ServiceConfigStartToken -StartType $Item.Expected
            return @(
                "sc.exe config $($Item.Name) start= $startToken",
                'powershell -ExecutionPolicy Bypass -File .\DisableDefender.ps1 -Mode Restore -Only Services -NoReboot'
            )
        }
        'Appx' {
            return @(
                'sfc /scannow',
                'DISM /Online /Cleanup-Image /RestoreHealth',
                'powershell -ExecutionPolicy Bypass -File .\DisableDefender.ps1 -Mode Restore -Only Appx -NoReboot'
            )
        }
        'MpPreference' {
            return @('powershell -ExecutionPolicy Bypass -File .\DisableDefender.ps1 -Mode Restore -Only MpPreference -NoReboot')
        }
        'Task' {
            return @(
                "schtasks.exe /Change /TN `"$($Item.Name)`" /Enable",
                'powershell -ExecutionPolicy Bypass -File .\DisableDefender.ps1 -Mode Restore -Only Tasks -NoReboot'
            )
        }
        'Policy' {
            return @('powershell -ExecutionPolicy Bypass -File .\DisableDefender.ps1 -Mode Restore -Only Policies -NoReboot')
        }
        default {
            return @(
                'powershell -ExecutionPolicy Bypass -File .\DisableDefender.ps1 -Mode Restore -NoReboot',
                'DISM /Online /Cleanup-Image /RestoreHealth'
            )
        }
    }
}

function Invoke-RestoreVerification {
    $health = Get-DefenderHealth -Target Restore
    $summary = $health.Summary
    $failed = @($health.Items | Where-Object { $_.Status -ne 'OK' })
    $level = if ($failed.Count -eq 0) { 'OK' } else { 'WARN' }
    Write-Log ("Restore verification: OK={0} Drift={1} Unknown={2} Total={3}" -f $summary.OK, $summary.Drift, $summary.Unknown, $summary.Total) $level

    if ($failed.Count -eq 0) {
        return $health
    }

    $repairCommands = New-Object System.Collections.ArrayList
    foreach ($item in $failed) {
        Write-Log ("Restore verification issue: [{0}] {1} expected {2}, actual {3}" -f $item.Category, $item.Name, $item.Expected, $item.Actual) WARN
        foreach ($command in (Get-RestoreRepairCommands -Item $item)) {
            if ($repairCommands -notcontains $command) {
                [void]$repairCommands.Add($command)
            }
        }
    }

    foreach ($command in $repairCommands) {
        Write-Log "Repair command: $command" WARN
    }

    if ($script:SilentMode) {
        throw "Restore verification failed with $($failed.Count) drift/unknown item(s). See repair commands in the log."
    }

    return $health
}

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
    .PARAMETER ManifestSelection
        Select which restore manifest chain to replay: newest non-empty manifest, all non-empty manifests newest-first, or only the active manifest.
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
        [ValidateSet('Newest','All','Active')]
        [string]$ManifestSelection = 'Newest',
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
            New-DefenderPhase -Name 'Replay manifest' -Key 'ReplayManifest' -Action { Invoke-RestoreManifest -Selection $ManifestSelection | Out-Null }
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
        Invoke-RestoreVerification | Out-Null
        Write-Log "Restore complete. Reboot recommended. If Defender does not come back: sfc /scannow then DISM /Online /Cleanup-Image /RestoreHealth." OK
    } finally {
        $script:RestoreManifestReplayMode = $previousReplayMode
    }
}
