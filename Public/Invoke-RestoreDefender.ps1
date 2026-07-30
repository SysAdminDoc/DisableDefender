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
                'powershell -ExecutionPolicy Bypass -File .\DisableDefender.ps1 -Mode Restore -RepairWithoutManifest -Only Services -NoReboot'
            )
        }
        'Appx' {
            return @(
                'sfc /scannow',
                'DISM /Online /Cleanup-Image /RestoreHealth',
                'powershell -ExecutionPolicy Bypass -File .\DisableDefender.ps1 -Mode Restore -RepairWithoutManifest -Only Appx -NoReboot'
            )
        }
        'MpPreference' {
            return @('powershell -ExecutionPolicy Bypass -File .\DisableDefender.ps1 -Mode Restore -RepairWithoutManifest -Only MpPreference -NoReboot')
        }
        'Task' {
            return @(
                "schtasks.exe /Change /TN `"$($Item.Name)`" /Enable",
                'powershell -ExecutionPolicy Bypass -File .\DisableDefender.ps1 -Mode Restore -RepairWithoutManifest -Only Tasks -NoReboot'
            )
        }
        'Policy' {
            return @('powershell -ExecutionPolicy Bypass -File .\DisableDefender.ps1 -Mode Restore -RepairWithoutManifest -Only Policies -NoReboot')
        }
        default {
            return @(
                'powershell -ExecutionPolicy Bypass -File .\DisableDefender.ps1 -Mode Restore -RepairWithoutManifest -NoReboot',
                'DISM /Online /Cleanup-Image /RestoreHealth'
            )
        }
    }
}

function Invoke-RestoreVerification {
    $result = New-DefenderActionResult -Name 'RestoreHealthVerification'
    $health = Get-DefenderHealth -Target Restore
    $summary = $health.Summary
    $failed = @($health.Items | Where-Object { $_.Status -ne 'OK' })
    $level = if ($failed.Count -eq 0) { 'OK' } else { 'WARN' }
    Write-Log ("Restore verification: OK={0} Drift={1} Unknown={2} Total={3}" -f $summary.OK, $summary.Drift, $summary.Unknown, $summary.Total) $level

    foreach ($item in $health.Items) {
        $verified = $item.Status -eq 'OK'
        Add-DefenderEffect -Result $result -Target "$($item.Category):$($item.Name)" `
            -Attempted $false -Changed $false -Verified $verified `
            -Evidence @{
                Expected = $item.Expected
                Actual   = $item.Actual
                Status   = $item.Status
                Detail   = $item.Detail
            } -Errors $(if ($verified) { @() } else { @("Expected '$($item.Expected)', actual '$($item.Actual)'.") })
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

    $completed = Complete-DefenderActionResult -Result $result
    $completed | Add-Member -NotePropertyName Health -NotePropertyValue $health
    $completed | Add-Member -NotePropertyName RepairCommands -NotePropertyValue @($repairCommands)
    return $completed
}

function Invoke-RestoreDefender {
    <#
    .SYNOPSIS
        Undoes all changes made by Invoke-DisableDefender or Invoke-RemoveDefender.
    .DESCRIPTION
        Replays a selected undo manifest and verifies the exact recorded registry,
        preference, task, service, Security Health, SafeBoot, and context-menu
        baseline before archiving that manifest. If no manifest exists,
        -RepairWithoutManifest explicitly selects a separate fixed-default repair
        preset. Firewall is verified intact before and after.
    .PARAMETER Only
        Run only the named fixed-default repair action phases. This parameter
        is not supported for recorded-baseline restore.
    .PARAMETER Skip
        Skip named fixed-default repair action phases. Firewall checks cannot
        be skipped.
    .PARAMETER ManifestSelection
        Select which restore manifest chain to replay: newest non-empty manifest, all non-empty manifests newest-first, or only the active manifest.
    .PARAMETER RepairWithoutManifest
        Explicitly run the fixed-default repair preset when no restore manifest exists.
        This is not an exact baseline restore.
    .PARAMETER AllowRemoting
        Allow execution inside PSRemoting / PSSession contexts.
    .EXAMPLE
        Invoke-RestoreDefender
    .EXAMPLE
        Invoke-RestoreDefender -RepairWithoutManifest
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$Silent,
        [switch]$AllowRemoting,
        [string]$LogPath,
        [ValidateSet('Policies','MpPreference','Tasks','Services','AclRestore','Appx','ContextMenu','Verification')]
        [string[]]$Only,
        [ValidateSet('Policies','MpPreference','Tasks','Services','AclRestore','Appx','ContextMenu','Verification')]
        [string[]]$Skip,
        [ValidateSet('Newest','All','Active')]
        [string]$ManifestSelection = 'Newest',
        [switch]$RepairWithoutManifest,
        [scriptblock]$LogCallback
    )

    $shouldProcess = $PSCmdlet.ShouldProcess('Microsoft Defender', 'Restore')
    if (-not $shouldProcess -and -not $WhatIfPreference) { return }

    Set-RunOptions -Silent:$Silent -AllowRemoting:$AllowRemoting -LogPath $LogPath -LogCallback $LogCallback
    Confirm-LocalSession -Mode Restore

    $previousReplayMode = [bool]$script:RestoreManifestReplayMode
    $script:RestoreManifestReplayMode = $true
    try {
        $manifestPlan = Get-RestoreManifestReplayPlan -Selection $ManifestSelection
        $hasManifest = $manifestPlan.Manifests.Count -gt 0
        if ($hasManifest -and $RepairWithoutManifest) {
            throw '-RepairWithoutManifest is only valid when the selected restore manifest does not exist.'
        }
        if (-not $hasManifest -and -not $RepairWithoutManifest) {
            throw 'No restore manifest is available for exact baseline restoration. Use -RepairWithoutManifest only to run the explicit fixed-default repair preset.'
        }

        if ($hasManifest) {
            if (@($Only | Where-Object { $_ }).Count -gt 0 -or
                @($Skip | Where-Object { $_ }).Count -gt 0) {
                throw 'Phase filters are not supported for transactional recorded-baseline restore.'
            }
            $selectedAclRunIds = @($manifestPlan.Manifests | ForEach-Object {
                @($_.RunIds)
            } | Sort-Object -Unique)
            $phases = @(
                New-DefenderPhase -Name 'Replay recorded baseline' -Key 'ReplayManifest' -RequiresResult -Action { Invoke-DefenderRestoreManifestPlan -Selection $ManifestSelection }
                New-DefenderPhase -Name 'Registry ACL restore' -Key 'AclRestore' -RequiresResult -Action { Restore-RegKeyACLs -RunId $selectedAclRunIds }
                New-DefenderPhase -Name 'Recorded baseline verification' -Key 'Verification' -RequiresResult -Action { Test-RestoreManifestBaseline -Selection $ManifestSelection }
            )
            $preflightPhases = @(
                New-DefenderPhase -Name 'Firewall preflight' -Key 'FirewallPreflight' -Action { Assert-FirewallSafety -Stage pre }
            )
            $postflightPhases = @(
                New-DefenderPhase -Name 'Firewall postflight' -Key 'FirewallPostflight' -Action { Assert-FirewallSafety -Stage post }
            )
            $operationResult = Invoke-DefenderGuardedPhasePlan -Mode Restore -Phases $phases `
                -PreflightPhases $preflightPhases -PostflightPhases $postflightPhases
            $operationResult | Add-Member -NotePropertyName RestoreStrategy `
                -NotePropertyValue 'RecordedBaseline' -Force
            Write-Log 'Exact recorded baseline restored and verified. Reboot recommended.' OK
        } else {
            Write-Log 'No manifest selected; running explicit fixed-default repair preset.' WARN
            $phases = @(
                New-DefenderPhase -Name 'Policy cleanup' -Key 'Policies' -RequiresResult -Action { Clear-DefenderPolicy }
                New-DefenderPhase -Name 'MpPreference cleanup' -Key 'MpPreference' -RequiresResult -Action { Clear-MpRuntimePrefs }
                New-DefenderPhase -Name 'Scheduled task restore' -Key 'Tasks' -RequiresResult -Action { Enable-DefenderTasks }
                New-DefenderPhase -Name 'Service restore' -Key 'Services' -RequiresResult -Action { Restore-DefenderServices }
                New-DefenderPhase -Name 'Registry ACL restore' -Key 'AclRestore' -RequiresResult -Action { Restore-RegKeyACLs }
                New-DefenderPhase -Name 'SecHealthUI restore' -Key 'Appx' -RequiresResult -Action { Restore-SecHealthUI }
                New-DefenderPhase -Name 'Context menu restore' -Key 'ContextMenu' -RequiresResult -Action { Restore-DefenderContextMenu }
                New-DefenderPhase -Name 'Repair verification' -Key 'Verification' -RequiresResult -Action { Invoke-RestoreVerification }
            )
            $preflightPhases = @(
                New-DefenderPhase -Name 'Firewall preflight' -Key 'FirewallPreflight' -Action { Assert-FirewallSafety -Stage pre }
            )
            $postflightPhases = @(
                New-DefenderPhase -Name 'Firewall postflight' -Key 'FirewallPostflight' -Action { Assert-FirewallSafety -Stage post }
            )
            $operationResult = Invoke-DefenderGuardedPhasePlan -Mode Restore -Phases $phases `
                -PreflightPhases $preflightPhases -PostflightPhases $postflightPhases `
                -Only $Only -Skip $Skip
            $operationResult | Add-Member -NotePropertyName RestoreStrategy `
                -NotePropertyValue 'FixedDefaultRepair' -Force
            Write-Log 'Fixed-default repair complete. Reboot recommended. If Defender does not return, run sfc /scannow and DISM /Online /Cleanup-Image /RestoreHealth.' OK
        }
        return $operationResult
    } finally {
        $script:RestoreManifestReplayMode = $previousReplayMode
    }
}
