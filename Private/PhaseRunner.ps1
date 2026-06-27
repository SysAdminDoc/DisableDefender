# ---------------------------------------------------------------------------
# Atomic phase runner
# Records phase boundaries to a runtime state file and logs recovery choices.
# ---------------------------------------------------------------------------

function Get-DefenderPhaseStatePath {
    if (-not $script:PhaseStatePath) {
        $script:PhaseStatePath = Join-Path $script:AppDir 'phase-state.json'
    }
    return $script:PhaseStatePath
}

function Save-DefenderPhaseState {
    param(
        [Parameter(Mandatory)]$State
    )

    if ($WhatIfPreference) { return }

    $path = Get-DefenderPhaseStatePath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $State.Updated = (Get-Date).ToString('o')
    $State | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding UTF8
}

function Get-DefenderPartialState {
    try {
        $status = Get-DefenderStatus
        $partial = [ordered]@{}
        foreach ($key in $status.Keys) {
            $partial[$key] = $status[$key]
        }
        return $partial
    } catch {
        return [ordered]@{
            Error = $_.Exception.Message
        }
    }
}

function New-DefenderPhase {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Key,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    if ([string]::IsNullOrWhiteSpace($Key)) {
        $Key = $Name
    }

    return [PSCustomObject]@{
        Name   = $Name
        Key    = $Key
        Action = $Action
    }
}

function ConvertTo-DefenderPhaseToken {
    param(
        [Parameter(Mandatory)][string]$Value
    )

    return (($Value -replace '[^A-Za-z0-9]', '').ToLowerInvariant())
}

function New-DefenderPhaseFilterSet {
    param(
        [string[]]$Values
    )

    $set = @{}
    foreach ($value in @($Values)) {
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $set[(ConvertTo-DefenderPhaseToken -Value $value)] = $true
    }
    return $set
}

function Get-DefenderPhaseSkipReason {
    param(
        [Parameter(Mandatory)]$Phase,
        [hashtable]$OnlySet,
        [hashtable]$SkipSet
    )

    $tokens = @(
        (ConvertTo-DefenderPhaseToken -Value $Phase.Name),
        (ConvertTo-DefenderPhaseToken -Value $Phase.Key)
    ) | Select-Object -Unique

    if ($OnlySet.Count -gt 0) {
        $matchedOnly = $false
        foreach ($token in $tokens) {
            if ($OnlySet.ContainsKey($token)) {
                $matchedOnly = $true
                break
            }
        }
        if (-not $matchedOnly) { return 'Only' }
    }

    foreach ($token in $tokens) {
        if ($SkipSet.ContainsKey($token)) { return 'Skip' }
    }

    return $null
}

function Assert-DefenderFirewallBoundary {
    param(
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][ValidateSet('before','after')][string]$Boundary
    )

    Assert-FirewallSafety -Stage "${Boundary}:$Phase"
}

function Invoke-DefenderPhasePlan {
    param(
        [Parameter(Mandatory)][ValidateSet('Disable','Remove','Restore')][string]$Mode,
        [Parameter(Mandatory)][object[]]$Phases,
        [string[]]$Only,
        [string[]]$Skip
    )

    $onlySet = New-DefenderPhaseFilterSet -Values $Only
    $skipSet = New-DefenderPhaseFilterSet -Values $Skip
    if ($onlySet.Count -gt 0) {
        Write-Log "Phase filter active: Only=$($Only -join ',')" INFO
    }
    if ($skipSet.Count -gt 0) {
        Write-Log "Phase filter active: Skip=$($Skip -join ',')" INFO
    }

    $state = [ordered]@{
        SchemaVersion = 1
        RunId         = [guid]::NewGuid().ToString()
        Mode          = $Mode
        Status        = 'Running'
        Started       = (Get-Date).ToString('o')
        Updated       = (Get-Date).ToString('o')
        PhaseStatePath = (Get-DefenderPhaseStatePath)
        Only          = @($Only)
        Skip          = @($Skip)
        Phases        = @()
    }
    $phaseStates = New-Object System.Collections.ArrayList
    $runCount = 0
    Save-DefenderPhaseState -State $state

    foreach ($phase in $Phases) {
        $phaseState = [ordered]@{
            Name      = $phase.Name
            Key       = $phase.Key
            Status    = 'Running'
            Started   = (Get-Date).ToString('o')
            Completed = $null
            Error     = $null
        }
        [void]$phaseStates.Add($phaseState)
        $state.Phases = @($phaseStates)
        Save-DefenderPhaseState -State $state

        $skipReason = Get-DefenderPhaseSkipReason -Phase $phase -OnlySet $onlySet -SkipSet $skipSet
        if ($skipReason) {
            $phaseState.Status = 'Skipped'
            $phaseState.Completed = (Get-Date).ToString('o')
            $phaseState.SkipReason = $skipReason
            $state.Phases = @($phaseStates)
            Save-DefenderPhaseState -State $state
            Write-Log "Skipped phase: $($phase.Name) ($skipReason filter)" DEBUG
            continue
        }

        $runCount++
        Write-Log "Starting phase: $($phase.Name)" INFO

        try {
            Assert-DefenderFirewallBoundary -Phase $phase.Key -Boundary before
            & $phase.Action
            Assert-DefenderFirewallBoundary -Phase $phase.Key -Boundary after
            $phaseState.Status = 'Completed'
            $phaseState.Completed = (Get-Date).ToString('o')
            $state.Phases = @($phaseStates)
            Save-DefenderPhaseState -State $state
            Write-Log "Completed phase: $($phase.Name)" OK
        } catch {
            $phaseState.Status = 'Failed'
            $phaseState.Completed = (Get-Date).ToString('o')
            $phaseState.Error = $_.Exception.Message
            $state.Status = 'Failed'
            $state.FailedPhase = $phase.Name
            $state.PartialState = Get-DefenderPartialState
            $state.Phases = @($phaseStates)
            Save-DefenderPhaseState -State $state

            $path = Get-DefenderPhaseStatePath
            Write-Log "Phase failed: $($phase.Name): $($_.Exception.Message)" ERROR
            Write-Log "Partial state written to $path" WARN
            Write-Log "Recovery choices: rerun $Mode to resume idempotent phases, or run Restore to roll back from the replay manifest." WARN
            throw
        }
    }

    if ($runCount -eq 0) {
        $state.Status = 'Failed'
        $state.Error = 'Phase filters selected no runnable phases.'
        Save-DefenderPhaseState -State $state
        throw 'Phase filters selected no runnable phases.'
    }

    $state.Status = 'Completed'
    $state.Completed = (Get-Date).ToString('o')
    $state.Phases = @($phaseStates)
    Save-DefenderPhaseState -State $state
}
