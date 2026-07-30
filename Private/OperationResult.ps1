# ---------------------------------------------------------------------------
# Shared effect and operation result contracts
# ---------------------------------------------------------------------------

function New-DefenderActionResult {
    param(
        [Parameter(Mandatory)][string]$Name,
        [switch]$Simulation
    )

    $result = [PSCustomObject][ordered]@{
        SchemaVersion = 1
        Name          = $Name
        Simulation    = [bool]$Simulation
        Attempted     = 0
        Changed       = 0
        Verified      = 0
        Evidence      = @()
        Errors        = @()
        Effects       = [System.Collections.ArrayList]::new()
        Succeeded     = $false
        Completed     = $null
    }
    $result.PSObject.TypeNames.Insert(0, 'DisableDefender.ActionResult')
    return $result
}

function Add-DefenderEffect {
    param(
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$Target,
        [bool]$Attempted,
        [bool]$Changed,
        [bool]$Verified,
        [AllowNull()]$Evidence,
        [string[]]$Errors,
        [bool]$Required = $true
    )

    if (-not (Test-DefenderActionResult -Value $Result)) {
        throw 'Effect result target is not a DisableDefender action result.'
    }

    $effect = [PSCustomObject][ordered]@{
        Target    = $Target
        Required  = $Required
        Attempted = $Attempted
        Changed   = $Changed
        Verified  = $Verified
        Evidence  = $Evidence
        Errors    = @($Errors | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    $effect.PSObject.TypeNames.Insert(0, 'DisableDefender.EffectResult')
    [void]$Result.Effects.Add($effect)
}

function Merge-DefenderActionResult {
    param(
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)]$ChildResult
    )

    if (-not (Test-DefenderActionResult -Value $Result) -or
        -not (Test-DefenderActionResult -Value $ChildResult)) {
        throw 'Cannot merge an invalid DisableDefender action result.'
    }

    foreach ($effect in @($ChildResult.Effects)) {
        Add-DefenderEffect -Result $Result -Target $effect.Target -Required $effect.Required `
            -Attempted $effect.Attempted -Changed $effect.Changed -Verified $effect.Verified `
            -Evidence $effect.Evidence -Errors $effect.Errors
    }
}

function New-DefenderSingleEffectResult {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Target,
        [bool]$Attempted,
        [bool]$Changed,
        [bool]$Verified,
        [AllowNull()]$Evidence,
        [string[]]$Errors,
        [bool]$Required = $true,
        [switch]$Simulation
    )

    $result = New-DefenderActionResult -Name $Name -Simulation:$Simulation
    Add-DefenderEffect -Result $result -Target $Target -Attempted $Attempted `
        -Changed $Changed -Verified $Verified -Evidence $Evidence -Errors $Errors `
        -Required $Required
    return (Complete-DefenderActionResult -Result $result)
}

function Complete-DefenderActionResult {
    param(
        [Parameter(Mandatory)]$Result
    )

    if (-not (Test-DefenderActionResult -Value $Result)) {
        throw 'Cannot complete an invalid DisableDefender action result.'
    }

    $effects = @($Result.Effects)
    $Result.Attempted = @($effects | Where-Object Attempted).Count
    $Result.Changed = @($effects | Where-Object Changed).Count
    $Result.Verified = @($effects | Where-Object Verified).Count
    $Result.Evidence = @($effects | ForEach-Object {
        if ($null -ne $_.Evidence) { $_.Evidence }
    })
    $Result.Errors = @($effects | ForEach-Object { @($_.Errors) })
    $requiredFailures = @($effects | Where-Object {
        $_.Required -and (-not $_.Verified -or @($_.Errors).Count -gt 0)
    })
    $Result.Succeeded = ($requiredFailures.Count -eq 0)
    $Result.Completed = (Get-Date).ToString('o')
    return $Result
}

function Test-DefenderActionResult {
    param(
        [Parameter(Mandatory)][AllowNull()]$Value
    )

    if ($null -eq $Value) { return $false }
    $requiredProperties = @(
        'SchemaVersion', 'Name', 'Attempted', 'Changed', 'Verified',
        'Evidence', 'Errors', 'Effects', 'Succeeded'
    )
    foreach ($property in $requiredProperties) {
        if ($Value.PSObject.Properties.Name -notcontains $property) {
            return $false
        }
    }
    return $true
}

function Assert-DefenderActionResult {
    param(
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$Phase
    )

    if (-not (Test-DefenderActionResult -Value $Result)) {
        throw "Phase '$Phase' did not return a valid effect result."
    }
    if (-not $Result.Succeeded) {
        $failedTargets = @($Result.Effects | Where-Object {
            $_.Required -and (-not $_.Verified -or @($_.Errors).Count -gt 0)
        } | ForEach-Object Target)
        $suffix = if ($failedTargets.Count -gt 0) { ": $($failedTargets -join ', ')" } else { '' }
        throw "Phase '$Phase' failed effect verification$suffix"
    }
}

function New-DefenderOperationResult {
    param(
        [Parameter(Mandatory)][ValidateSet('Disable','Remove','Restore')][string]$Mode,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Started,
        [Parameter(Mandatory)][string]$Completed,
        [Parameter(Mandatory)][string]$PhaseStatePath,
        [Parameter(Mandatory)][object[]]$Phases,
        [switch]$Simulation
    )

    $actionResults = @($Phases | ForEach-Object {
        if ($null -ne $_.Result -and (Test-DefenderActionResult -Value $_.Result)) {
            $_.Result
        }
    })
    $operation = [PSCustomObject][ordered]@{
        SchemaVersion  = 1
        Ok             = $true
        Succeeded      = $true
        Mode           = $Mode
        RunId          = $RunId
        Simulation     = [bool]$Simulation
        Started        = $Started
        Completed      = $Completed
        PhaseStatePath = $PhaseStatePath
        Attempted      = [int](($actionResults | Measure-Object -Property Attempted -Sum).Sum)
        Changed        = [int](($actionResults | Measure-Object -Property Changed -Sum).Sum)
        Verified       = [int](($actionResults | Measure-Object -Property Verified -Sum).Sum)
        Evidence       = @($actionResults | ForEach-Object { @($_.Evidence) })
        Errors         = @($actionResults | ForEach-Object { @($_.Errors) })
        Phases         = @($Phases)
    }
    $operation.PSObject.TypeNames.Insert(0, 'DisableDefender.OperationResult')
    return $operation
}
