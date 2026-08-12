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
    Assert-DefenderRuntimeDirectory -Path (Split-Path -Parent $path)
    Assert-DefenderArtifactSchemaVersion -Name PhaseState `
        -InputObject $State | Out-Null
    $State.Updated = (Get-Date).ToString('o')
    Write-DefenderJsonArtifactAtomic -Name PhaseState -Path $path `
        -InputObject $State -Depth 12 | Out-Null
}

function Read-DefenderPhaseState {
    $path = Get-DefenderPhaseStatePath
    if (-not (Test-Path -LiteralPath $path)) { return $null }

    return (Read-DefenderJsonArtifact -Name PhaseState -Path $path)
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
        [Parameter(Mandatory)][scriptblock]$Action,
        [switch]$RequiresResult
    )

    if ([string]::IsNullOrWhiteSpace($Key)) {
        $Key = $Name
    }

    return [PSCustomObject]@{
        Name   = $Name
        Key    = $Key
        Action = $Action
        RequiresResult = [bool]$RequiresResult
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

function Assert-DefenderCancellationBoundary {
    param([Parameter(Mandatory)][string]$Boundary)

    if ($null -eq $script:CancellationCallback) { return }
    $requested = $false
    try { $requested = [bool](& $script:CancellationCallback) } catch {}
    if (-not $requested) { return }

    $message = "Operation cancellation requested; stopping at the $Boundary boundary after the current phase completed."
    Write-Log $message WARN
    throw [System.OperationCanceledException]::new($message)
}

function Assert-DefenderActionPhaseSelection {
    param(
        [Parameter(Mandatory)][object[]]$Phases,
        [string[]]$Only,
        [string[]]$Skip
    )

    $onlySet = New-DefenderPhaseFilterSet -Values $Only
    $skipSet = New-DefenderPhaseFilterSet -Values $Skip
    $selected = @($Phases | Where-Object {
        -not (Get-DefenderPhaseSkipReason -Phase $_ -OnlySet $onlySet -SkipSet $skipSet)
    })
    if ($selected.Count -eq 0) {
        throw 'Phase filters selected no runnable action phases.'
    }
}

function Invoke-DefenderUnfilteredPhase {
    param(
        [Parameter(Mandatory)]$Phase
    )

    Write-Log "Starting mandatory phase: $($Phase.Name)" INFO
    $actionOutput = @(& $Phase.Action)
    $actionResult = @($actionOutput | Where-Object {
        Test-DefenderActionResult -Value $_
    } | Select-Object -Last 1)
    if ($Phase.RequiresResult) {
        if ($actionResult.Count -eq 0) {
            throw "Mandatory phase '$($Phase.Name)' did not return a valid effect result."
        }
        Assert-DefenderActionResult -Result $actionResult[0] -Phase $Phase.Name
    }
    Write-Log "Completed mandatory phase: $($Phase.Name)" OK
}

function Invoke-DefenderGuardedPhasePlan {
    param(
        [Parameter(Mandatory)][ValidateSet('Disable','Remove','Restore')][string]$Mode,
        [Parameter(Mandatory)][object[]]$Phases,
        [object[]]$PreflightPhases = @(),
        [object[]]$PostflightPhases = @(),
        [string[]]$Only,
        [string[]]$Skip
    )

    # Validate filters before any preflight side effect such as a restore point.
    Assert-DefenderActionPhaseSelection -Phases $Phases -Only $Only -Skip $Skip

    $primaryFailure = $null
    $postflightFailure = $null
    $preflightCompleted = $false
    $operationResult = $null
    try {
        Assert-DefenderCancellationBoundary -Boundary 'preflight'
        foreach ($phase in @($PreflightPhases)) {
            Invoke-DefenderUnfilteredPhase -Phase $phase
        }
        $preflightCompleted = $true
        $operationResult = Invoke-DefenderPhasePlan -Mode $Mode -Phases $Phases `
            -Only $Only -Skip $Skip
    } catch {
        $primaryFailure = $_
    }

    if ($preflightCompleted) {
        try {
            foreach ($phase in @($PostflightPhases)) {
                Invoke-DefenderUnfilteredPhase -Phase $phase
            }
        } catch {
            $postflightFailure = $_
        }
    }

    if ($null -ne $primaryFailure) {
        if ($null -ne $postflightFailure) {
            Write-Log "Mandatory postflight also failed: $($postflightFailure.Exception.Message)" ERROR
        }
        throw $primaryFailure
    }
    if ($null -ne $postflightFailure) {
        throw $postflightFailure
    }
    return $operationResult
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
        SchemaVersion = Get-DefenderArtifactSchemaVersion -Name PhaseState
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
        try {
            Assert-DefenderCancellationBoundary -Boundary "phase '$($phase.Name)'"
        } catch [System.OperationCanceledException] {
            $state.Status = 'Cancelled'
            $state.CancelledAt = (Get-Date).ToString('o')
            $state.Error = $_.Exception.Message
            Save-DefenderPhaseState -State $state
            throw
        }
        $phaseState = [ordered]@{
            Name      = $phase.Name
            Key       = $phase.Key
            Status    = 'Running'
            Started   = (Get-Date).ToString('o')
            Completed = $null
            Error     = $null
            Result    = $null
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
            $actionOutput = @(& $phase.Action)
            $actionResult = @($actionOutput | Where-Object {
                Test-DefenderActionResult -Value $_
            } | Select-Object -Last 1)
            if ($actionResult.Count -gt 0) {
                $phaseState.Result = $actionResult[0]
            }
            if ($phase.RequiresResult) {
                if ($actionResult.Count -eq 0) {
                    throw "Phase '$($phase.Name)' did not return a valid effect result."
                }
                Assert-DefenderActionResult -Result $actionResult[0] -Phase $phase.Name
            }
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
    $operationResult = New-DefenderOperationResult -Mode $Mode -RunId $state.RunId -Started $state.Started `
        -Completed $state.Completed -PhaseStatePath $state.PhaseStatePath -Phases @($phaseStates) `
        -Simulation:$WhatIfPreference
    $state.Result = $operationResult
    Save-DefenderPhaseState -State $state
    return $operationResult
}
