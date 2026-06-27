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
        [Parameter(Mandatory)][scriptblock]$Action
    )

    return [PSCustomObject]@{
        Name   = $Name
        Action = $Action
    }
}

function Invoke-DefenderPhasePlan {
    param(
        [Parameter(Mandatory)][ValidateSet('Disable','Remove','Restore')][string]$Mode,
        [Parameter(Mandatory)][object[]]$Phases
    )

    $state = [ordered]@{
        SchemaVersion = 1
        RunId         = [guid]::NewGuid().ToString()
        Mode          = $Mode
        Status        = 'Running'
        Started       = (Get-Date).ToString('o')
        Updated       = (Get-Date).ToString('o')
        PhaseStatePath = (Get-DefenderPhaseStatePath)
        Phases        = @()
    }
    $phaseStates = New-Object System.Collections.ArrayList
    Save-DefenderPhaseState -State $state

    foreach ($phase in $Phases) {
        $phaseState = [ordered]@{
            Name      = $phase.Name
            Status    = 'Running'
            Started   = (Get-Date).ToString('o')
            Completed = $null
            Error     = $null
        }
        [void]$phaseStates.Add($phaseState)
        $state.Phases = @($phaseStates)
        Save-DefenderPhaseState -State $state
        Write-Log "Starting phase: $($phase.Name)" INFO

        try {
            & $phase.Action
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

    $state.Status = 'Completed'
    $state.Completed = (Get-Date).ToString('o')
    $state.Phases = @($phaseStates)
    Save-DefenderPhaseState -State $state
}
