# ---------------------------------------------------------------------------
# Machine-readable safety tripwires
# ---------------------------------------------------------------------------

function Write-SafetyTripwire {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Disable','Remove','Restore','Health','Status')][string]$Mode,
        [Parameter(Mandatory)][string]$Reason,
        [Parameter(Mandatory)][bool]$Blocked,
        [hashtable]$Details
    )

    $entry = [ordered]@{
        SchemaVersion = Get-DefenderArtifactSchemaVersion -Name SafetyTripwireEntry
        Timestamp = (Get-Date).ToString('o')
        Name      = $Name
        Mode      = $Mode
        Blocked   = $Blocked
        Force     = [bool]$script:ForceMode
        Reason    = $Reason
        Details   = $Details
    }
    $json = $entry | ConvertTo-Json -Depth 8 -Compress
    $path = Join-Path $script:AppDir 'tripwire.jsonl'
    Assert-DefenderRuntimeDirectory -Path (Split-Path -Parent $path)
    try { Add-Content -LiteralPath $path -Value $json -ErrorAction Stop } catch {}
    Write-Log "TRIPWIRE $json" WARN
}

function Get-RemoveKnownBadConditions {
    $conditions = New-Object System.Collections.ArrayList
    try {
        $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        if ($computer.PartOfDomain) {
            [void]$conditions.Add([ordered]@{
                Name    = 'DomainJoined'
                Reason  = 'Remove mode on a domain-joined machine can break managed endpoint policy, compliance, and recovery controls.'
                Details = @{
                    Domain = [string]$computer.Domain
                }
            })
        }
    } catch {
        Write-Log "Could not evaluate domain-joined safety gate: $($_.Exception.Message)" WARN
    }
    return @($conditions)
}

function Confirm-RemoveKnownBadOverrides {
    $conditions = @(Get-RemoveKnownBadConditions)
    if ($conditions.Count -eq 0) { return }

    foreach ($condition in $conditions) {
        Write-SafetyTripwire -Name $condition.Name -Mode Remove -Reason $condition.Reason -Blocked:(-not $script:ForceMode) -Details $condition.Details
    }

    if (-not $script:ForceMode) {
        $names = ($conditions | ForEach-Object { $_.Name }) -join ', '
        throw "Remove refused because known-bad condition(s) are present: $names. Use -Force to override."
    }
}

function Test-PSRemotingSession {
    if ($Host.Name -eq 'ServerRemoteHost') { return $true }
    if (Get-Variable -Name PSSenderInfo -ErrorAction SilentlyContinue) { return $true }
    return $false
}

function Confirm-LocalSession {
    param(
        [Parameter(Mandatory)][ValidateSet('Disable','Remove','Restore')][string]$Mode
    )

    if (-not (Test-PSRemotingSession)) { return }

    Write-SafetyTripwire -Name 'PSRemotingSession' -Mode $Mode -Reason 'Running this tool through PSRemoting or a PSSession can strand security and recovery changes away from the interactive workstation context.' -Blocked:(-not $script:AllowRemotingMode) -Details @{
        HostName = $Host.Name
    }

    if (-not $script:AllowRemotingMode) {
        throw "PSRemoting/PSSession execution refused for $Mode. Use -AllowRemoting to override."
    }
}
