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

function New-RestoreManifestSiblingPath {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Name
    )

    $candidate = Join-Path $Directory $Name
    if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }

    $stem = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    $extension = [System.IO.Path]::GetExtension($Name)
    for ($i = 1; $i -lt 1000; $i++) {
        $candidate = Join-Path $Directory ("{0}.{1}{2}" -f $stem, $i, $extension)
        if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
    }

    throw "Unable to create a unique restore manifest archive path in $Directory."
}

function Test-RestoreManifestArchiveName {
    param([Parameter(Mandatory)][string]$Name)
    return ($Name -match '^restore-manifest\.\d{14}(?:\.\d+)?\.jsonl$')
}

function Get-RestoreManifestCandidates {
    $path = Get-RestoreManifestPath
    $dir = Split-Path -Parent $path
    $items = New-Object System.Collections.ArrayList

    if (Test-Path -LiteralPath $path) {
        $active = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        if ($active -and $active.Length -gt 0) {
            [void]$items.Add([pscustomobject]@{
                Path             = $active.FullName
                Name             = $active.Name
                IsActive         = $true
                LastWriteTimeUtc = $active.LastWriteTimeUtc
            })
        }
    }

    if (Test-Path -LiteralPath $dir) {
        foreach ($archive in (Get-ChildItem -LiteralPath $dir -Filter 'restore-manifest.*.jsonl' -File -ErrorAction SilentlyContinue)) {
            if (-not (Test-RestoreManifestArchiveName -Name $archive.Name)) { continue }
            if ($archive.Length -le 0) { continue }
            [void]$items.Add([pscustomobject]@{
                Path             = $archive.FullName
                Name             = $archive.Name
                IsActive         = $false
                LastWriteTimeUtc = $archive.LastWriteTimeUtc
            })
        }
    }

    return @($items | Sort-Object `
        @{ Expression = { $_.LastWriteTimeUtc }; Descending = $true },
        @{ Expression = { $_.Name }; Descending = $true })
}

function Select-RestoreManifestCandidates {
    param(
        [Parameter(Mandatory)][object[]]$Candidates,
        [Parameter(Mandatory)][ValidateSet('Newest','All','Active')][string]$Selection
    )

    switch ($Selection) {
        'All'    { return @($Candidates) }
        'Active' { return @($Candidates | Where-Object { $_.IsActive }) }
        default  { return @($Candidates | Select-Object -First 1) }
    }
}

function Write-RestoreManifestSelectionWarning {
    param(
        [Parameter(Mandatory)][object[]]$Candidates,
        [Parameter(Mandatory)][object[]]$Selected,
        [Parameter(Mandatory)][ValidateSet('Newest','All','Active')][string]$Selection
    )

    $archives = @($Candidates | Where-Object { -not $_.IsActive })
    if ($archives.Count -eq 0 -or $Selection -eq 'All') { return }

    $selectedPaths = @($Selected | ForEach-Object { $_.Path })
    $skippedArchives = @($archives | Where-Object { $selectedPaths -notcontains $_.Path })
    if ($skippedArchives.Count -gt 0) {
        Write-Log ("{0} archived restore manifest(s) were not selected. Run Restore with -ManifestSelection All to replay every undo chain." -f $skippedArchives.Count) WARN
    }
}

function Test-RestoreManifestRecording {
    if ($WhatIfPreference) { return $false }
    if ($script:RestoreManifestReplayMode) { return $false }
    return [bool]$script:RestoreManifestActive
}

function Get-RestoreManifestActionSchema {
    return @{
        RemoveRegistryValue    = @('Path','Name')
        RestoreRegistryValue   = @('Path','Name','Kind','Value')
        RestoreRegistryTree    = @('Path','Tree')
        SetServiceStart        = @('Service','State')
        StartService           = @('Service')
        SetScheduledTaskState  = @('TaskPath','Enabled')
        SetMpPreference        = @('Name','Value')
        RemoveMpPreferenceValue = @('Parameter','Value')
        RestoreSecHealthUI     = @()
        DismRestoreHealth      = @('PackageName')
    }
}

function Test-RestoreManifestProperty {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $InputObject) { return $false }
    return @($InputObject.PSObject.Properties.Name) -contains $Name
}

function Assert-RestoreManifestEntry {
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][int]$LineNumber
    )

    foreach ($property in @('SchemaVersion','RunId','Sequence','Timestamp','Mode','Phase','Action','Target','Data')) {
        if (-not (Test-RestoreManifestProperty -InputObject $Entry -Name $property)) {
            throw "Restore manifest line $LineNumber is missing $property."
        }
    }

    if ([int]$Entry.SchemaVersion -ne 1) {
        throw "Restore manifest line $LineNumber has unsupported schema version $($Entry.SchemaVersion)."
    }

    try { [void][guid]$Entry.RunId } catch {
        throw "Restore manifest line $LineNumber has invalid RunId '$($Entry.RunId)'."
    }

    $sequence = 0
    if (-not [int]::TryParse([string]$Entry.Sequence, [ref]$sequence) -or $sequence -lt 1) {
        throw "Restore manifest line $LineNumber has invalid Sequence '$($Entry.Sequence)'."
    }

    $timestamp = [datetime]::MinValue
    if (-not [datetime]::TryParse(
            [string]$Entry.Timestamp,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$timestamp)) {
        throw "Restore manifest line $LineNumber has invalid Timestamp '$($Entry.Timestamp)'."
    }

    if (@('Disable','Remove') -notcontains [string]$Entry.Mode) {
        throw "Restore manifest line $LineNumber has invalid Mode '$($Entry.Mode)'."
    }

    foreach ($property in @('Phase','Action','Target')) {
        if ([string]::IsNullOrWhiteSpace([string]$Entry.$property)) {
            throw "Restore manifest line $LineNumber has empty $property."
        }
    }

    $schema = Get-RestoreManifestActionSchema
    if (-not $schema.ContainsKey([string]$Entry.Action)) {
        throw "Restore manifest line $LineNumber uses unexpected action '$($Entry.Action)'."
    }

    foreach ($property in @($schema[[string]$Entry.Action])) {
        if (-not (Test-RestoreManifestProperty -InputObject $Entry.Data -Name $property)) {
            throw "Restore manifest line $LineNumber action '$($Entry.Action)' is missing Data.$property."
        }
    }

    if ($Entry.Action -eq 'SetServiceStart' -and @('Boot','System','Automatic','Manual','Disabled') -notcontains [string]$Entry.Data.State) {
        throw "Restore manifest line $LineNumber has invalid service State '$($Entry.Data.State)'."
    }

    if ($Entry.Action -eq 'RestoreRegistryValue') {
        try { [void][Enum]::Parse([Microsoft.Win32.RegistryValueKind], [string]$Entry.Data.Kind, $true) } catch {
            throw "Restore manifest line $LineNumber has invalid registry Kind '$($Entry.Data.Kind)'."
        }
    }

    return $true
}

function Get-RestoreManifestDigest {
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $stream = $null
    $sha256 = $null
    try {
        $stream = [System.IO.File]::OpenRead((Resolve-Path -LiteralPath $Path).Path)
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $hash = $sha256.ComputeHash($stream)
        return [BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()
    } catch {
        Write-Log "Unable to compute restore manifest digest: $($_.Exception.Message)" WARN
        return 'unavailable'
    } finally {
        if ($stream) { $stream.Dispose() }
        if ($sha256) { $sha256.Dispose() }
    }
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
            $archive = New-RestoreManifestSiblingPath -Directory $dir -Name ("restore-manifest.{0}.jsonl" -f (Get-Date -Format 'yyyyMMddHHmmss'))
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
    param([string]$Path)

    $path = if ($Path) { $Path } else { Get-RestoreManifestPath }
    if (-not (Test-Path -LiteralPath $path)) { return @() }

    $entries = New-Object System.Collections.ArrayList
    $lineNumber = 0
    foreach ($line in (Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $entry = $line | ConvertFrom-Json
            Assert-RestoreManifestEntry -Entry $entry -LineNumber $lineNumber | Out-Null
            [void]$entries.Add($entry)
        } catch {
            Write-Log "Refusing restore manifest line ${lineNumber}: $($_.Exception.Message)" ERROR
            throw
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
    param(
        [ValidateSet('Newest','All','Active')]
        [string]$Selection = 'Newest'
    )

    $candidates = @(Get-RestoreManifestCandidates)
    $selectedManifests = @(Select-RestoreManifestCandidates -Candidates $candidates -Selection $Selection)
    Write-RestoreManifestSelectionWarning -Candidates $candidates -Selected $selectedManifests -Selection $Selection

    if ($selectedManifests.Count -eq 0) {
        Write-Log "No restore manifest entries found; falling back to deterministic restore steps." WARN
        return $true
    }

    Write-Log ("Restore manifest selection: Selection={0} Candidates={1} Selected={2}" -f $Selection, $candidates.Count, $selectedManifests.Count) INFO
    $failures = 0
    $totalEntries = 0
    $replayedManifests = New-Object System.Collections.ArrayList
    $script:RestoreManifestReplayMode = $true
    $script:RestoreManifestActive = $false
    try {
        foreach ($manifest in $selectedManifests) {
            $entries = @(Read-RestoreManifestEntries -Path $manifest.Path)
            if ($entries.Count -eq 0) {
                Write-Log "Selected restore manifest contains no replayable entries: $($manifest.Path)" WARN
                continue
            }

            $digest = Get-RestoreManifestDigest -Path $manifest.Path
            $runIds = @(($entries | ForEach-Object { $_.RunId }) | Sort-Object -Unique)
            $runLabel = if ($runIds.Count -eq 0) { 'none' } else { $runIds -join ',' }
            Write-Log ("Restore manifest integrity: RunIds={0} Entries={1} SHA256={2} Path={3}" -f $runLabel, $entries.Count, $digest, $manifest.Path) INFO
            Write-Log "Replaying $($entries.Count) restore manifest entries in reverse order..." INFO
            $totalEntries += $entries.Count
            [void]$replayedManifests.Add([pscustomobject]@{
                Path    = $manifest.Path
                Name    = $manifest.Name
                Active  = $manifest.IsActive
                RunIds  = $runLabel
                Entries = $entries.Count
                Digest  = $digest
            })

            foreach ($entry in ($entries | Sort-Object -Property Sequence -Descending)) {
                try {
                    Invoke-RestoreManifestEntry -Entry $entry
                    Write-Log "Replayed undo entry $($entry.Sequence): $($entry.Action) $($entry.Target)" DEBUG
                } catch {
                    $failures++
                    Write-Log "Restore manifest entry $($entry.Sequence) failed: $($_.Exception.Message)" WARN
                }
            }
        }
    } finally {
        $script:RestoreManifestReplayMode = $false
    }

    if ($totalEntries -eq 0) {
        Write-Log "No restore manifest entries found; falling back to deterministic restore steps." WARN
        return $true
    }

    if ($failures -eq 0) {
        foreach ($manifest in $replayedManifests) {
            if (Test-Path -LiteralPath $manifest.Path) {
                $dir = Split-Path -Parent $manifest.Path
                $archiveName = if ($manifest.Active) {
                    "restore-manifest.restored.{0}.jsonl" -f (Get-Date -Format 'yyyyMMddHHmmss')
                } else {
                    "restore-manifest.restored.{0}.{1}" -f (Get-Date -Format 'yyyyMMddHHmmss'), $manifest.Name
                }
                $archive = New-RestoreManifestSiblingPath -Directory $dir -Name $archiveName
                Move-Item -LiteralPath $manifest.Path -Destination $archive -Force
                Write-Log ("Archived replayed restore manifest to {0} (RunIds={1}; Entries={2}; SHA256={3})" -f $archive, $manifest.RunIds, $manifest.Entries, $manifest.Digest) INFO
            }
        }
        return $true
    }

    Write-Log "$failures restore manifest entries failed; manifest left in place for inspection." WARN
    return $false
}
