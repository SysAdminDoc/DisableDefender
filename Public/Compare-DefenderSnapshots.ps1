function Save-DefenderSnapshot {
    <#
    .SYNOPSIS
        Saves a timestamped snapshot of the current Defender state.
    .PARAMETER OutputPath
        Path for the JSON snapshot file. Defaults to a timestamped file in
        the runtime directory.
    .EXAMPLE
        Save-DefenderSnapshot
    .EXAMPLE
        Save-DefenderSnapshot -OutputPath C:\Snapshots\before.json
    #>
    [CmdletBinding()]
    param(
        [string]$OutputPath
    )

    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss')
        $OutputPath = Join-Path $script:AppDir "snapshot-$stamp.json"
    }

    $snapshot = [ordered]@{
        SchemaVersion = Get-DefenderArtifactSchemaVersion -Name DefenderSnapshot
        Timestamp     = (Get-Date).ToString('o')
        Version       = $script:Version
    }

    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $snapshot.WindowsBuild = [ordered]@{
            Caption     = $os.Caption
            Version     = $os.Version
            BuildNumber = $os.BuildNumber
        }
    } catch {
        $snapshot.WindowsBuild = $null
    }

    try {
        $health = Get-DefenderHealth -Target Disable
        $snapshot.Health = [ordered]@{
            Target  = $health.Target
            Summary = $health.Summary
        }
        $snapshot.HealthItems = @($health.Items | ForEach-Object {
            [ordered]@{
                Category = $_.Category
                Name     = $_.Name
                Expected = $_.Expected
                Actual   = $_.Actual
                Status   = $_.Status
            }
        })
    } catch {
        $snapshot.Health = $null
        $snapshot.HealthItems = @()
    }

    try {
        $status = Get-DefenderStatus
        $snapshot.Status = $status
    } catch {
        $snapshot.Status = $null
    }

    Write-DefenderJsonArtifactAtomic -Name DefenderSnapshot `
        -Path $OutputPath -InputObject $snapshot -Depth 8 | Out-Null
    Write-Log "Snapshot saved: $OutputPath" OK

    return [PSCustomObject]@{
        SnapshotPath = $OutputPath
        Timestamp    = $snapshot.Timestamp
        ItemCount    = $snapshot.HealthItems.Count
    }
}

function Read-DefenderSnapshotArtifact {
    param([Parameter(Mandatory)][string]$Path)

    $snapshot = Read-DefenderJsonArtifact -Name DefenderSnapshot -Path $Path
    if ($null -eq $snapshot.HealthItems) {
        throw "Defender snapshot is missing HealthItems: $Path"
    }
    return $snapshot
}

function Compare-DefenderSnapshots {
    <#
    .SYNOPSIS
        Compares two Defender state snapshots and shows what changed.
    .PARAMETER BaselinePath
        Path to the earlier snapshot JSON file.
    .PARAMETER CurrentPath
        Path to the later snapshot JSON file. If omitted, takes a live snapshot.
    .PARAMETER Json
        Emit JSON output instead of console table.
    .EXAMPLE
        Compare-DefenderSnapshots -BaselinePath C:\snapshot-before.json
    .EXAMPLE
        Compare-DefenderSnapshots -BaselinePath before.json -CurrentPath after.json
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BaselinePath,
        [string]$CurrentPath,
        [switch]$Json
    )

    if (-not (Test-Path -LiteralPath $BaselinePath)) {
        throw "Baseline snapshot not found: $BaselinePath"
    }
    $baseline = Read-DefenderSnapshotArtifact -Path $BaselinePath

    $current = $null
    if ($CurrentPath) {
        if (-not (Test-Path -LiteralPath $CurrentPath)) {
            throw "Current snapshot not found: $CurrentPath"
        }
        $current = Read-DefenderSnapshotArtifact -Path $CurrentPath
    } else {
        $tempPath = Join-Path $env:TEMP "dd-snapshot-compare-$([guid]::NewGuid().ToString('N')).json"
        try {
            Save-DefenderSnapshot -OutputPath $tempPath | Out-Null
            $current = Read-DefenderSnapshotArtifact -Path $tempPath
        } finally {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }

    $baselineItems = @{}
    foreach ($item in $baseline.HealthItems) {
        $key = "$($item.Category)|$($item.Name)"
        $baselineItems[$key] = $item
    }

    $currentItems = @{}
    foreach ($item in $current.HealthItems) {
        $key = "$($item.Category)|$($item.Name)"
        $currentItems[$key] = $item
    }

    $allKeys = @($baselineItems.Keys + $currentItems.Keys) | Sort-Object -Unique
    $diffs = New-Object System.Collections.ArrayList

    foreach ($key in $allKeys) {
        $b = $baselineItems[$key]
        $c = $currentItems[$key]

        if ($b -and $c) {
            if ([string]$b.Actual -ne [string]$c.Actual -or [string]$b.Status -ne [string]$c.Status) {
                [void]$diffs.Add([PSCustomObject][ordered]@{
                    Change   = 'Changed'
                    Category = $c.Category
                    Name     = $c.Name
                    Before   = $b.Actual
                    After    = $c.Actual
                    OldStatus = $b.Status
                    NewStatus = $c.Status
                })
            }
        } elseif ($b -and -not $c) {
            [void]$diffs.Add([PSCustomObject][ordered]@{
                Change   = 'Removed'
                Category = $b.Category
                Name     = $b.Name
                Before   = $b.Actual
                After    = ''
                OldStatus = $b.Status
                NewStatus = ''
            })
        } elseif (-not $b -and $c) {
            [void]$diffs.Add([PSCustomObject][ordered]@{
                Change   = 'Added'
                Category = $c.Category
                Name     = $c.Name
                Before   = ''
                After    = $c.Actual
                OldStatus = ''
                NewStatus = $c.Status
            })
        }
    }

    $result = [ordered]@{
        BaselineTimestamp = $baseline.Timestamp
        CurrentTimestamp  = $current.Timestamp
        BaselineVersion  = $baseline.Version
        CurrentVersion   = $current.Version
        TotalBaseline    = $baseline.HealthItems.Count
        TotalCurrent     = $current.HealthItems.Count
        ChangedCount     = $diffs.Count
        Diffs            = @($diffs)
    }

    if ($Json) {
        return $result | ConvertTo-Json -Depth 8
    }

    Write-Log "Snapshot diff: $($diffs.Count) change(s) between $($baseline.Timestamp) and $($current.Timestamp)" INFO
    return $result
}
