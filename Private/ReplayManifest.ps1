# ---------------------------------------------------------------------------
# Replay restore manifest
# Records undo entries as JSONL and replays them in reverse order during Restore.
# ---------------------------------------------------------------------------

function Get-RestoreManifestPath {
    if (-not $script:RestoreManifestPath) {
        $script:RestoreManifestPath = Join-Path $script:AppDir 'restore-manifest.jsonl'
    }
    return $script:RestoreManifestPath
}

function Test-RestoreManifestRecording {
    if ($WhatIfPreference) { return $false }
    if ($script:RestoreManifestReplayMode) { return $false }
    return [bool]$script:RestoreManifestActive
}

function Start-RestoreManifest {
    param(
        [Parameter(Mandatory)][ValidateSet('Disable','Remove')][string]$Mode
    )

    if ($WhatIfPreference) {
        Write-Log "WhatIf: restore manifest recording skipped." INFO
        return
    }

    $path = Get-RestoreManifestPath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if (Test-Path -LiteralPath $path) {
        $existing = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        if ($existing -and $existing.Length -gt 0) {
            $archive = Join-Path $dir ("restore-manifest.{0}.jsonl" -f (Get-Date -Format 'yyyyMMddHHmmss'))
            Move-Item -LiteralPath $path -Destination $archive -Force
            Write-Log "Archived previous restore manifest to $archive" WARN
        }
    }

    New-Item -ItemType File -Path $path -Force | Out-Null
    $script:RestoreManifestActive = $true
    $script:RestoreManifestRunId = [guid]::NewGuid().ToString()
    $script:RestoreManifestSequence = 0
    $script:RestoreManifestMode = $Mode
    Write-Log "Restore manifest recording started: $path" INFO
}

function Stop-RestoreManifest {
    if ($script:RestoreManifestActive) {
        Write-Log "Restore manifest recording stopped." DEBUG
    }
    $script:RestoreManifestActive = $false
}

function Write-RestoreManifestEntry {
    param(
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)]$Data
    )

    if (-not (Test-RestoreManifestRecording)) { return }

    $script:RestoreManifestSequence++
    $entry = [ordered]@{
        SchemaVersion = 1
        RunId         = $script:RestoreManifestRunId
        Sequence      = $script:RestoreManifestSequence
        Timestamp     = (Get-Date).ToString('o')
        Mode          = $script:RestoreManifestMode
        Phase         = $Phase
        Action        = $Action
        Target        = $Target
        Data          = $Data
    }
    $json = $entry | ConvertTo-Json -Depth 12 -Compress
    Add-Content -LiteralPath (Get-RestoreManifestPath) -Value $json
    Write-Log "Recorded undo entry $($entry.Sequence): $Action $Target" DEBUG
}

function Read-RestoreManifestEntries {
    $path = Get-RestoreManifestPath
    if (-not (Test-Path -LiteralPath $path)) { return @() }

    $entries = New-Object System.Collections.ArrayList
    foreach ($line in (Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            [void]$entries.Add(($line | ConvertFrom-Json))
        } catch {
            Write-Log "Skipping invalid restore manifest line: $($_.Exception.Message)" WARN
        }
    }
    return @($entries)
}

function Register-RegistryValueUndo {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [string]$Phase = 'Registry'
    )

    if (-not (Test-RestoreManifestRecording)) { return }

    try {
        if (Test-Path -LiteralPath $Path) {
            $key = Get-Item -LiteralPath $Path -ErrorAction Stop
            if ($key.GetValueNames() -contains $Name) {
                $data = [ordered]@{
                    Path  = $Path
                    Name  = $Name
                    Kind  = $key.GetValueKind($Name).ToString()
                    Value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                }
                Write-RestoreManifestEntry -Phase $Phase -Action 'RestoreRegistryValue' -Target "$Path\$Name" -Data $data
                return
            }
        }
    } catch {}

    Write-RestoreManifestEntry -Phase $Phase -Action 'RemoveRegistryValue' -Target "$Path\$Name" -Data ([ordered]@{
        Path = $Path
        Name = $Name
    })
}

function Export-RegistryTree {
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $null }

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    $values = New-Object System.Collections.ArrayList
    foreach ($name in $item.GetValueNames()) {
        [void]$values.Add([ordered]@{
            Name  = $name
            Kind  = $item.GetValueKind($name).ToString()
            Value = $item.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        })
    }

    $children = New-Object System.Collections.ArrayList
    foreach ($child in (Get-ChildItem -LiteralPath $Path -ErrorAction SilentlyContinue)) {
        $childPath = Join-Path $Path $child.PSChildName
        [void]$children.Add((Export-RegistryTree -Path $childPath))
    }

    return [ordered]@{
        Name     = Split-Path $Path -Leaf
        Values   = @($values)
        Children = @($children)
    }
}

function Register-RegistryTreeUndo {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Phase = 'Registry'
    )

    if (-not (Test-RestoreManifestRecording)) { return }
    $tree = Export-RegistryTree -Path $Path
    if ($null -eq $tree) { return }

    Write-RestoreManifestEntry -Phase $Phase -Action 'RestoreRegistryTree' -Target $Path -Data ([ordered]@{
        Path = $Path
        Tree = $tree
    })
}

function Set-RegistryValueFromManifest {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$Kind
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }

    $registryKind = [Microsoft.Win32.RegistryValueKind]::$Kind
    $key = Get-Item -LiteralPath $Path -ErrorAction Stop
    $key.SetValue($Name, $Value, $registryKind)
}

function Import-RegistryTree {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Tree
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }

    foreach ($value in @($Tree.Values)) {
        Set-RegistryValueFromManifest -Path $Path -Name $value.Name -Value $value.Value -Kind $value.Kind
    }

    foreach ($child in @($Tree.Children)) {
        if ($null -eq $child) { continue }
        $childPath = Join-Path $Path $child.Name
        Import-RegistryTree -Path $childPath -Tree $child
    }
}

function Invoke-RestoreManifestEntry {
    param(
        [Parameter(Mandatory)]$Entry
    )

    $data = $Entry.Data
    switch ($Entry.Action) {
        'RemoveRegistryValue' {
            if (Test-Path -LiteralPath $data.Path) {
                Remove-ItemProperty -LiteralPath $data.Path -Name $data.Name -ErrorAction SilentlyContinue
            }
        }
        'RestoreRegistryValue' {
            Set-RegistryValueFromManifest -Path $data.Path -Name $data.Name -Value $data.Value -Kind $data.Kind
        }
        'RestoreRegistryTree' {
            Import-RegistryTree -Path $data.Path -Tree $data.Tree
        }
        'SetServiceStart' {
            Set-ServiceStart -Service $data.Service -State $data.State | Out-Null
        }
        'StartService' {
            sc.exe start $data.Service 2>&1 | Out-Null
        }
        'SetScheduledTaskState' {
            $tn = Split-Path $data.TaskPath -Leaf
            $tp = Split-Path $data.TaskPath -Parent
            if ([bool]$data.Enabled) {
                Enable-ScheduledTask -TaskName $tn -TaskPath "$tp\" -ErrorAction SilentlyContinue | Out-Null
            } else {
                Disable-ScheduledTask -TaskName $tn -TaskPath "$tp\" -ErrorAction SilentlyContinue | Out-Null
            }
        }
        'SetMpPreference' {
            $splat = @{ ErrorAction = 'SilentlyContinue' }
            $splat[$data.Name] = $data.Value
            Set-MpPreference @splat
        }
        'RemoveMpPreferenceValue' {
            $splat = @{ ErrorAction = 'SilentlyContinue' }
            $splat[$data.Parameter] = @($data.Value)
            Remove-MpPreference @splat
        }
        'RestoreSecHealthUI' {
            Restore-SecHealthUI
        }
        'DismRestoreHealth' {
            Write-Log "Replay cannot reinstall removed Defender packages without a Windows component source. Run DISM /Online /Cleanup-Image /RestoreHealth if package $($data.PackageName) does not return." WARN
        }
        default {
            Write-Log "Unknown restore manifest action '$($Entry.Action)' for $($Entry.Target)" WARN
        }
    }
}

function Invoke-RestoreManifest {
    $entries = @(Read-RestoreManifestEntries)
    if ($entries.Count -eq 0) {
        Write-Log "No restore manifest entries found; falling back to deterministic restore steps." WARN
        return $true
    }

    Write-Log "Replaying $($entries.Count) restore manifest entries in reverse order..." INFO
    $failures = 0
    $script:RestoreManifestReplayMode = $true
    $script:RestoreManifestActive = $false
    try {
        foreach ($entry in ($entries | Sort-Object -Property Sequence -Descending)) {
            try {
                Invoke-RestoreManifestEntry -Entry $entry
                Write-Log "Replayed undo entry $($entry.Sequence): $($entry.Action) $($entry.Target)" DEBUG
            } catch {
                $failures++
                Write-Log "Restore manifest entry $($entry.Sequence) failed: $($_.Exception.Message)" WARN
            }
        }
    } finally {
        $script:RestoreManifestReplayMode = $false
    }

    if ($failures -eq 0) {
        $path = Get-RestoreManifestPath
        if (Test-Path -LiteralPath $path) {
            $archive = Join-Path (Split-Path -Parent $path) ("restore-manifest.restored.{0}.jsonl" -f (Get-Date -Format 'yyyyMMddHHmmss'))
            Move-Item -LiteralPath $path -Destination $archive -Force
            Write-Log "Archived replayed restore manifest to $archive" INFO
        }
        return $true
    }

    Write-Log "$failures restore manifest entries failed; manifest left in place for inspection." WARN
    return $false
}
