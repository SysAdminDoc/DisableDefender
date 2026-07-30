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
    Assert-DefenderRuntimeDirectory -Path $dir

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
    Add-Content -LiteralPath (Get-RestoreManifestPath) -Value $json -ErrorAction Stop
    Write-Log "Recorded undo entry $($entry.Sequence): $Action $Target" DEBUG
}

function Read-RestoreManifestEntries {
    param([string]$Path)

    $path = if ($Path) { $Path } else { Get-RestoreManifestPath }
    if (-not (Test-Path -LiteralPath $path)) { return @() }

    $entries = New-Object System.Collections.ArrayList
    $lineNumber = 0
    foreach ($line in (Get-Content -LiteralPath $path -ErrorAction Stop)) {
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

function Get-RestoreRegistryValueState {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name
    )

    try {
        if (-not (Test-Path -LiteralPath $Path -ErrorAction Stop)) {
            return [PSCustomObject]@{
                Readable = $true
                Exists   = $false
                Kind     = $null
                Value    = $null
                Error    = $null
            }
        }
        $key = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($key.GetValueNames() -notcontains $Name) {
            return [PSCustomObject]@{
                Readable = $true
                Exists   = $false
                Kind     = $null
                Value    = $null
                Error    = $null
            }
        }
        return [PSCustomObject]@{
            Readable = $true
            Exists   = $true
            Kind     = $key.GetValueKind($Name).ToString()
            Value    = $key.GetValue(
                $Name,
                $null,
                [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            Error    = $null
        }
    } catch {
        return [PSCustomObject]@{
            Readable = $false
            Exists   = $null
            Kind     = $null
            Value    = $null
            Error    = $_.Exception.Message
        }
    }
}

function Register-RegistryValueUndo {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [string]$Phase = 'Registry'
    )

    if (-not (Test-RestoreManifestRecording)) { return }

    $state = Get-RestoreRegistryValueState -Path $Path -Name $Name
    if (-not $state.Readable) {
        $message = "Could not read original value at ${Path}\${Name}; mutation refused: $($state.Error)"
        Write-Log $message ERROR
        throw $message
    }
    if ($state.Exists) {
        $data = [ordered]@{
            Path  = $Path
            Name  = $Name
            Kind  = $state.Kind
            Value = $state.Value
        }
        Write-RestoreManifestEntry -Phase $Phase -Action 'RestoreRegistryValue' -Target "$Path\$Name" -Data $data
        return
    }

    Write-RestoreManifestEntry -Phase $Phase -Action 'RemoveRegistryValue' -Target "$Path\$Name" -Data ([ordered]@{
        Path = $Path
        Name = $Name
    })
}

function Export-RegistryTree {
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -ErrorAction Stop)) { return $null }

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
    foreach ($child in (Get-ChildItem -LiteralPath $Path -ErrorAction Stop)) {
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
        New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
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
        New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
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

function ConvertTo-DefenderCanonicalRegistryTree {
    param(
        [Parameter(Mandatory)]$Tree
    )

    $values = @($Tree.Values | Sort-Object -Property Name | ForEach-Object {
        [ordered]@{
            Name  = [string]$_.Name
            Kind  = [string]$_.Kind
            Value = $_.Value
        }
    })
    $children = @($Tree.Children | Where-Object { $null -ne $_ } |
        Sort-Object -Property Name | ForEach-Object {
            ConvertTo-DefenderCanonicalRegistryTree -Tree $_
        })
    return [ordered]@{
        Name     = [string]$Tree.Name
        Values   = $values
        Children = $children
    }
}

function Test-DefenderRegistryTreeEqual {
    param(
        [AllowNull()]$Expected,
        [AllowNull()]$Actual
    )

    if ($null -eq $Expected -or $null -eq $Actual) {
        return ($null -eq $Expected -and $null -eq $Actual)
    }
    $expectedJson = ConvertTo-DefenderCanonicalRegistryTree -Tree $Expected |
        ConvertTo-Json -Depth 20 -Compress
    $actualJson = ConvertTo-DefenderCanonicalRegistryTree -Tree $Actual |
        ConvertTo-Json -Depth 20 -Compress
    return ($expectedJson -ceq $actualJson)
}

function Invoke-DefenderRestoreServiceRuntime {
    param(
        [Parameter(Mandatory)][string]$Service
    )

    $before = Get-DefenderServiceRuntimeState -Service $Service
    if (-not $before.Readable -or -not $before.Exists) {
        return (New-DefenderSingleEffectResult -Name "RestoreServiceRuntime:$Service" `
            -Target "Service:${Service}:Runtime" -Attempted $false -Changed $false `
            -Verified $false -Evidence @{ Expected = 'Running'; Actual = $before.Status } `
            -Errors "Recorded service '$Service' is unavailable during restore.")
    }
    if ($before.Status -eq 'Running') {
        return (New-DefenderSingleEffectResult -Name "RestoreServiceRuntime:$Service" `
            -Target "Service:${Service}:Runtime" -Attempted $false -Changed $false `
            -Verified $true -Evidence @{ Expected = 'Running'; Actual = 'Running'; State = 'AlreadyCorrect' })
    }

    & sc.exe start $Service 2>&1 | Out-Null
    $exitCode = [int]$LASTEXITCODE
    Start-Sleep -Milliseconds 300
    $after = Get-DefenderServiceRuntimeState -Service $Service
    $verified = $after.Readable -and $after.Exists -and $after.Status -eq 'Running'
    return (New-DefenderSingleEffectResult -Name "RestoreServiceRuntime:$Service" `
        -Target "Service:${Service}:Runtime" -Attempted $true -Changed $verified `
        -Verified $verified `
        -Evidence @{ Expected = 'Running'; Actual = $after.Status; NativeExitCode = $exitCode } `
        -Errors $(if ($verified) { @() } else { @("Service start exited $exitCode and status is '$($after.Status)'.") }))
}

function Invoke-RestoreManifestEntry {
    param(
        [Parameter(Mandatory)]$Entry
    )

    $data = $Entry.Data
    switch ($Entry.Action) {
        'RemoveRegistryValue' {
            $before = Get-RestoreRegistryValueState -Path $data.Path -Name $data.Name
            if (-not $before.Readable) {
                return (New-DefenderSingleEffectResult -Name 'RestoreRegistryValue' -Target $Entry.Target `
                    -Attempted $false -Changed $false -Verified $false `
                    -Evidence @{ Expected = 'Absent'; Actual = 'Unreadable' } -Errors $before.Error)
            }
            if ($before.Exists) {
                Remove-ItemProperty -LiteralPath $data.Path -Name $data.Name -ErrorAction Stop
            }
            $after = Get-RestoreRegistryValueState -Path $data.Path -Name $data.Name
            $verified = $after.Readable -and -not $after.Exists
            return (New-DefenderSingleEffectResult -Name 'RestoreRegistryValue' -Target $Entry.Target `
                -Attempted $before.Exists -Changed ($before.Exists -and $verified) -Verified $verified `
                -Evidence @{ Expected = 'Absent'; Actual = $(if ($verified) { 'Absent' } else { 'PresentOrUnreadable' }) } `
                -Errors $(if ($verified) { @() } else { @('Registry value remained after baseline replay.') }))
        }
        'RestoreRegistryValue' {
            $before = Get-RestoreRegistryValueState -Path $data.Path -Name $data.Name
            if (-not $before.Readable) {
                return (New-DefenderSingleEffectResult -Name 'RestoreRegistryValue' -Target $Entry.Target `
                    -Attempted $false -Changed $false -Verified $false `
                    -Evidence @{ ExpectedKind = $data.Kind; Actual = 'Unreadable' } `
                    -Errors $before.Error)
            }
            $alreadyCorrect = $before.Exists -and $before.Kind -eq $data.Kind -and
                (Test-DefenderRegistryValue -State $before -Expected $data.Value)
            if (-not $alreadyCorrect) {
                Set-RegistryValueFromManifest -Path $data.Path -Name $data.Name `
                    -Value $data.Value -Kind $data.Kind
            }
            $after = Get-RestoreRegistryValueState -Path $data.Path -Name $data.Name
            $verified = $after.Readable -and $after.Exists -and
                $after.Kind -eq $data.Kind -and
                (Test-DefenderRegistryValue -State $after -Expected $data.Value)
            return (New-DefenderSingleEffectResult -Name 'RestoreRegistryValue' -Target $Entry.Target `
                -Attempted (-not $alreadyCorrect) `
                -Changed (-not $alreadyCorrect -and $verified) -Verified $verified `
                -Evidence @{
                    ExpectedKind  = $data.Kind
                    ActualKind    = $after.Kind
                    ExpectedValue = $data.Value
                    ActualValue   = $after.Value
                } -Errors $(if ($verified) { @() } else { @('Registry value differs from the recorded baseline.') }))
        }
        'RestoreRegistryTree' {
            try {
                $beforeTree = Export-RegistryTree -Path $data.Path
            } catch {
                return (New-DefenderSingleEffectResult -Name 'RestoreRegistryTree' -Target $Entry.Target `
                    -Attempted $false -Changed $false -Verified $false `
                    -Evidence @{ Expected = $data.Tree; Actual = 'Unreadable' } `
                    -Errors $_.Exception.Message)
            }
            $alreadyCorrect = Test-DefenderRegistryTreeEqual -Expected $data.Tree -Actual $beforeTree
            if (-not $alreadyCorrect) {
                if (Test-Path -LiteralPath $data.Path -ErrorAction Stop) {
                    Remove-Item -LiteralPath $data.Path -Recurse -Force -ErrorAction Stop
                }
                Import-RegistryTree -Path $data.Path -Tree $data.Tree
            }
            $afterTree = Export-RegistryTree -Path $data.Path
            $verified = Test-DefenderRegistryTreeEqual -Expected $data.Tree -Actual $afterTree
            return (New-DefenderSingleEffectResult -Name 'RestoreRegistryTree' -Target $Entry.Target `
                -Attempted (-not $alreadyCorrect) `
                -Changed (-not $alreadyCorrect -and $verified) -Verified $verified `
                -Evidence @{ Expected = $data.Tree; Actual = $afterTree } `
                -Errors $(if ($verified) { @() } else { @('Registry tree differs from the recorded baseline.') }))
        }
        'SetServiceStart' {
            $serviceResult = Set-ServiceStart -Service $data.Service -State $data.State
            $absentEffect = @($serviceResult.Effects | Where-Object {
                $_.Evidence -is [hashtable] -and $_.Evidence.Actual -eq 'Absent'
            })
            if ($absentEffect.Count -gt 0) {
                $absentEffect[0].Required = $true
                $absentEffect[0].Verified = $false
                $absentEffect[0].Errors = @("Recorded service '$($data.Service)' is absent during restore.")
                $serviceResult = Complete-DefenderActionResult -Result $serviceResult
            }
            return $serviceResult
        }
        'StartService' {
            return (Invoke-DefenderRestoreServiceRuntime -Service $data.Service)
        }
        'SetScheduledTaskState' {
            $taskMode = if ([bool]$data.Enabled) { 'Enable' } else { 'Disable' }
            $taskResult = Invoke-DefenderScheduledTaskPlan -Mode $taskMode -TaskPaths @($data.TaskPath)
            $absentEffect = @($taskResult.Effects | Where-Object {
                $_.Evidence -is [hashtable] -and $_.Evidence.Actual -eq 'Absent'
            })
            if ($absentEffect.Count -gt 0) {
                $absentEffect[0].Required = $true
                $absentEffect[0].Verified = $false
                $absentEffect[0].Errors = @("Recorded task '$($data.TaskPath)' is absent during restore.")
                $taskResult = Complete-DefenderActionResult -Result $taskResult
            }
            return $taskResult
        }
        'SetMpPreference' {
            try {
                $beforePrefs = Get-MpPreference -ErrorAction Stop
                $propertyAvailable = $beforePrefs.PSObject.Properties.Name -contains $data.Name
                if (-not $propertyAvailable) {
                    throw "Recorded MpPreference '$($data.Name)' is unavailable."
                }
                $beforeValue = $beforePrefs.($data.Name)
            } catch {
                return (New-DefenderSingleEffectResult -Name 'RestoreMpPreference' -Target $Entry.Target `
                    -Attempted $false -Changed $false -Verified $false `
                    -Evidence @{ Expected = $data.Value; Actual = 'Unavailable' } `
                    -Errors $_.Exception.Message)
            }
            $alreadyCorrect = Test-DefenderMpPreferenceValue `
                -Actual $beforeValue -Expected $data.Value
            if (-not $alreadyCorrect) {
                $splat = @{ ErrorAction = 'Stop' }
                $splat[$data.Name] = $data.Value
                Set-MpPreference @splat
            }
            $afterPrefs = Get-MpPreference -ErrorAction Stop
            $afterAvailable = $afterPrefs.PSObject.Properties.Name -contains $data.Name
            $actual = if ($afterAvailable) { $afterPrefs.($data.Name) } else { $null }
            $verified = $afterAvailable -and
                (Test-DefenderMpPreferenceValue -Actual $actual -Expected $data.Value)
            return (New-DefenderSingleEffectResult -Name 'RestoreMpPreference' -Target $Entry.Target `
                -Attempted (-not $alreadyCorrect) `
                -Changed (-not $alreadyCorrect -and $verified) -Verified $verified `
                -Evidence @{ Expected = $data.Value; Actual = $actual } `
                -Errors $(if ($verified) { @() } else { @('MpPreference differs from the recorded baseline.') }))
        }
        'RemoveMpPreferenceValue' {
            try {
                $beforePrefs = Get-MpPreference -ErrorAction Stop
                $propertyAvailable = $beforePrefs.PSObject.Properties.Name -contains $data.Parameter
                if (-not $propertyAvailable) {
                    throw "Recorded MpPreference '$($data.Parameter)' is unavailable."
                }
                $beforePresent = @($beforePrefs.($data.Parameter)) -contains $data.Value
            } catch {
                return (New-DefenderSingleEffectResult -Name 'RestoreMpPreferenceExclusion' `
                    -Target $Entry.Target -Attempted $false -Changed $false -Verified $false `
                    -Evidence @{ Expected = 'Absent'; Actual = 'Unavailable' } `
                    -Errors $_.Exception.Message)
            }
            if ($beforePresent) {
                $splat = @{ ErrorAction = 'Stop' }
                $splat[$data.Parameter] = @($data.Value)
                Remove-MpPreference @splat
            }
            $afterPrefs = Get-MpPreference -ErrorAction Stop
            $afterAvailable = $afterPrefs.PSObject.Properties.Name -contains $data.Parameter
            $present = $afterAvailable -and
                (@($afterPrefs.($data.Parameter)) -contains $data.Value)
            $verified = $afterAvailable -and -not $present
            return (New-DefenderSingleEffectResult -Name 'RestoreMpPreferenceExclusion' `
                -Target $Entry.Target -Attempted $beforePresent `
                -Changed ($beforePresent -and $verified) -Verified $verified `
                -Evidence @{ Expected = 'Absent'; Actual = $(if ($present) { 'Present' } else { 'Absent' }) } `
                -Errors $(if ($verified) { @() } else { @('MpPreference exclusion remains present.') }))
        }
        'RestoreSecHealthUI' {
            return (Restore-SecHealthUI -Baseline $data)
        }
        'DismRestoreHealth' {
            $restore = Invoke-DefenderDismRestoreHealth
            $after = Get-DefenderPlatformPackageState
            $verified = $after.Readable -and $after.Packages -contains $data.PackageName
            return (New-DefenderSingleEffectResult -Name 'RestoreDismPackage' -Target $Entry.Target `
                -Attempted $true -Changed $verified -Verified $verified `
                -Evidence @{
                    Expected        = 'Present'
                    Actual          = $(if ($verified) { 'Present' } else { 'AbsentOrUnknown' })
                    RestoreExitCode = $restore.ExitCode
                    QueryExitCode   = $after.ExitCode
                } -Errors $(if ($verified) { @() } else { @("DISM RestoreHealth exited $($restore.ExitCode), but package did not return.") }))
        }
        default {
            throw "Unknown restore manifest action '$($Entry.Action)' for $($Entry.Target)."
        }
    }
}

function Get-RestoreReplayStatePath {
    return (Join-Path $script:AppDir 'restore-replay-state.json')
}

function Save-RestoreReplayState {
    param(
        [Parameter(Mandatory)]$State
    )

    if ($WhatIfPreference) { return }
    $path = Get-RestoreReplayStatePath
    Assert-DefenderRuntimeDirectory -Path (Split-Path -Parent $path)
    $State.Updated = (Get-Date).ToString('o')
    $temporaryPath = "$path.tmp"
    $State | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $temporaryPath `
        -Encoding UTF8 -ErrorAction Stop
    Move-Item -LiteralPath $temporaryPath -Destination $path -Force -ErrorAction Stop
}

function Read-RestoreReplayState {
    $path = Get-RestoreReplayStatePath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return (Get-Content -Raw -LiteralPath $path -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
}

function Get-RestoreManifestReplayPlan {
    param(
        [ValidateSet('Newest','All','Active')]
        [string]$Selection = 'Newest'
    )

    $replayState = Read-RestoreReplayState
    $hasArchivedReplayManifest = $false
    if ($null -ne $replayState) {
        $hasArchivedReplayManifest = @($replayState.Manifests | Where-Object {
            $_.PSObject.Properties.Name -contains 'ArchivePath' -and
            -not [string]::IsNullOrWhiteSpace([string]$_.ArchivePath) -and
            (Test-Path -LiteralPath $_.ArchivePath)
        }).Count -gt 0
    }
    if ($null -ne $replayState -and
        (@('Finalizing','FinalizeFailed','Completed') -contains [string]$replayState.Status -or
         $hasArchivedReplayManifest)) {
        if ([string]$replayState.Selection -ne $Selection) {
            throw "Restore finalization was started with manifest selection '$($replayState.Selection)'. Retry with the same selection."
        }

        $resumedManifests = New-Object System.Collections.ArrayList
        foreach ($record in @($replayState.Manifests)) {
            $archivePath = if ($record.PSObject.Properties.Name -contains 'ArchivePath') {
                [string]$record.ArchivePath
            } else {
                $null
            }
            $currentPath = if (Test-Path -LiteralPath $record.Path) {
                [string]$record.Path
            } elseif ($archivePath -and (Test-Path -LiteralPath $archivePath)) {
                $archivePath
            } else {
                throw "Restore manifest is missing from both its active and recovery paths: $($record.Path)"
            }
            $actualDigest = Get-RestoreManifestDigest -Path $currentPath
            if ($actualDigest -ne [string]$record.Digest) {
                throw "Restore manifest bytes changed during finalization recovery: $currentPath"
            }
            $entries = @(Read-RestoreManifestEntries -Path $currentPath)
            if ($entries.Count -ne [int]$record.EntryCount) {
                throw "Restore manifest entry count changed during finalization recovery: $currentPath"
            }
            [void]$resumedManifests.Add([PSCustomObject]@{
                Path        = [string]$record.Path
                CurrentPath = $currentPath
                ArchivePath = $archivePath
                Name        = [string]$record.Name
                IsActive    = [bool]$record.IsActive
                Digest      = [string]$record.Digest
                RunIds      = @($record.RunIds)
                EntryCount  = [int]$record.EntryCount
                Entries     = $entries
            })
        }
        return [PSCustomObject]@{
            Selection = $Selection
            Candidates = $resumedManifests.Count
            Signature = [string]$replayState.PlanSignature
            Manifests = @($resumedManifests)
        }
    }

    $candidates = @(Get-RestoreManifestCandidates)
    $selected = @(Select-RestoreManifestCandidates -Candidates $candidates -Selection $Selection)
    Write-RestoreManifestSelectionWarning -Candidates $candidates -Selected $selected -Selection $Selection
    $manifests = New-Object System.Collections.ArrayList
    foreach ($manifest in $selected) {
        $entries = @(Read-RestoreManifestEntries -Path $manifest.Path)
        if ($entries.Count -eq 0) { continue }
        $digest = Get-RestoreManifestDigest -Path $manifest.Path
        $runIds = @(($entries | ForEach-Object RunId) | Sort-Object -Unique)
        [void]$manifests.Add([PSCustomObject]@{
            Path       = $manifest.Path
            CurrentPath = $manifest.Path
            ArchivePath = $null
            Name       = $manifest.Name
            IsActive   = [bool]$manifest.IsActive
            Digest     = $digest
            RunIds     = $runIds
            EntryCount = $entries.Count
            Entries    = $entries
        })
    }
    return [PSCustomObject]@{
        Selection = $Selection
        Candidates = $candidates.Count
        Signature = (@($manifests | ForEach-Object { "$($_.Path)|$($_.Digest)|$($_.EntryCount)" }) -join ';')
        Manifests = @($manifests)
    }
}

function New-RestoreReplayState {
    param(
        [Parameter(Mandatory)]$Plan
    )

    return [ordered]@{
        SchemaVersion = 1
        ReplayId      = [guid]::NewGuid().ToString()
        Selection     = $Plan.Selection
        PlanSignature = $Plan.Signature
        Status        = 'Replaying'
        Started       = (Get-Date).ToString('o')
        Updated       = (Get-Date).ToString('o')
        ReplayCompleted = $null
        CompletedKeys = @()
        NextEntryKey  = $null
        LastError     = $null
        FailedEntry   = $null
        Manifests     = @($Plan.Manifests | ForEach-Object {
            [ordered]@{
                Path       = $_.Path
                Name       = $_.Name
                IsActive   = $_.IsActive
                Digest     = $_.Digest
                RunIds     = @($_.RunIds)
                EntryCount = $_.EntryCount
                ArchivePath = $null
                Archived   = $false
            }
        })
    }
}

function Invoke-RestoreManifest {
    param(
        [ValidateSet('Newest','All','Active')]
        [string]$Selection = 'Newest'
    )

    $plan = Get-RestoreManifestReplayPlan -Selection $Selection
    if ($plan.Manifests.Count -eq 0) {
        Write-Log "No restore manifest entries found." WARN
        return $true
    }

    Write-Log ("Restore manifest selection: Selection={0} Candidates={1} Selected={2}" -f `
        $Selection, $plan.Candidates, $plan.Manifests.Count) INFO
    $state = Read-RestoreReplayState
    if ($null -ne $state) {
        if ($state.PlanSignature -ne $plan.Signature) {
            throw 'Existing restore replay state does not match the selected manifest bytes. Preserve both artifacts and resolve the mismatch before retrying.'
        }
        $state.Status = 'Replaying'
        $state.LastError = $null
        $state.FailedEntry = $null
        Write-Log "Resuming restore replay $($state.ReplayId) with $(@($state.CompletedKeys).Count) completed entry/entries." WARN
    } else {
        $state = New-RestoreReplayState -Plan $plan
    }
    Save-RestoreReplayState -State $state

    $script:RestoreManifestReplayMode = $true
    $script:RestoreManifestActive = $false
    try {
        foreach ($manifest in $plan.Manifests) {
            $runLabel = if ($manifest.RunIds.Count -eq 0) { 'none' } else { $manifest.RunIds -join ',' }
            Write-Log ("Restore manifest integrity: RunIds={0} Entries={1} SHA256={2} Path={3}" -f `
                $runLabel, $manifest.EntryCount, $manifest.Digest, $manifest.CurrentPath) INFO
            foreach ($entry in ($manifest.Entries | Sort-Object -Property Sequence -Descending)) {
                $entryKey = "$($manifest.Digest):$($entry.Sequence)"
                if (@($state.CompletedKeys) -contains $entryKey) {
                    Write-Log "Skipping already verified replay entry $entryKey." DEBUG
                    continue
                }
                $state.NextEntryKey = $entryKey
                Save-RestoreReplayState -State $state
                try {
                    $entryResult = Invoke-RestoreManifestEntry -Entry $entry
                    Assert-DefenderActionResult -Result $entryResult `
                        -Phase "Restore entry $($entry.Sequence) $($entry.Action)"
                    $state.CompletedKeys = @($state.CompletedKeys) + $entryKey
                    $state.NextEntryKey = $null
                    Save-RestoreReplayState -State $state
                    Write-Log "Replayed undo entry $($entry.Sequence): $($entry.Action) $($entry.Target)" DEBUG
                } catch {
                    $state.Status = 'Failed'
                    $state.NextEntryKey = $entryKey
                    $state.LastError = $_.Exception.Message
                    $state.FailedEntry = [ordered]@{
                        Key      = $entryKey
                        Sequence = $entry.Sequence
                        Action   = $entry.Action
                        Target   = $entry.Target
                    }
                    Save-RestoreReplayState -State $state
                    Write-Log "Restore manifest entry $($entry.Sequence) failed; resume point saved at ${entryKey}: $($_.Exception.Message)" WARN
                    return $false
                }
            }
        }
    } finally {
        $script:RestoreManifestReplayMode = $false
    }

    $state.Status = 'AwaitingVerification'
    $state.NextEntryKey = $null
    $state.ReplayCompleted = (Get-Date).ToString('o')
    Save-RestoreReplayState -State $state
    Write-Log 'Restore entries replayed and retained pending exact baseline verification.' INFO
    return $true
}

function Get-RestoreManifestExpectationKey {
    param(
        [Parameter(Mandatory)]$Entry
    )

    switch ($Entry.Action) {
        { $_ -in @('RemoveRegistryValue','RestoreRegistryValue') } {
            return "RegistryValue:$($Entry.Target)"
        }
        'RestoreRegistryTree' { return "RegistryTree:$($Entry.Target)" }
        'SetServiceStart' { return "ServiceStart:$($Entry.Data.Service)" }
        'StartService' { return "ServiceRuntime:$($Entry.Data.Service)" }
        'SetScheduledTaskState' { return "Task:$($Entry.Data.TaskPath)" }
        'SetMpPreference' { return "MpPreference:$($Entry.Data.Name)" }
        'RemoveMpPreferenceValue' {
            return "MpPreferenceValue:$($Entry.Data.Parameter):$($Entry.Data.Value)"
        }
        'RestoreSecHealthUI' { return 'SecHealthUI' }
        'DismRestoreHealth' { return "DismPackage:$($Entry.Data.PackageName)" }
        default { throw "Unsupported restore expectation action '$($Entry.Action)'." }
    }
}

function Get-RestoreManifestFinalExpectations {
    param(
        [Parameter(Mandatory)]$Plan
    )

    $expectations = [ordered]@{}
    foreach ($manifest in $Plan.Manifests) {
        foreach ($entry in ($manifest.Entries | Sort-Object -Property Sequence -Descending)) {
            $key = Get-RestoreManifestExpectationKey -Entry $entry
            $expectations[$key] = $entry
        }
    }
    return @($expectations.GetEnumerator() | ForEach-Object Value)
}

function Test-DefenderSecHealthUIBaseline {
    param(
        [Parameter(Mandatory)]$Baseline
    )

    $state = Get-DefenderSecHealthUIState
    $expectedInstalled = @($Baseline.InstalledPackages | ForEach-Object {
        Get-DefenderBaselinePackageProperty -Item $_ -Property 'PackageFullName'
    } | Where-Object { $_ })
    $expectedProvisioned = @($Baseline.ProvisionedPackages | ForEach-Object {
        Get-DefenderBaselinePackageProperty -Item $_ -Property 'PackageName'
    } | Where-Object { $_ })
    if ($Baseline.PSObject.Properties.Name -contains 'DeprovisionMarkers') {
        $expectedMarkers = @($Baseline.DeprovisionMarkers | ForEach-Object { [string]$_ })
    } elseif ($Baseline.PSObject.Properties.Name -contains 'DeprovisionMarkerExisted' -and
        [bool]$Baseline.DeprovisionMarkerExisted) {
        $expectedMarkers = @((Get-SecHealthUIDeprovisionPaths)[0])
    } else {
        $expectedMarkers = @()
    }
    $actualInstalled = @($state.InstalledPackages | ForEach-Object PackageFullName)
    $actualProvisioned = @($state.ProvisionedPackages | ForEach-Object PackageName)
    $actualMarkers = @($state.Markers | ForEach-Object { [string]$_ })
    $verified = $state.Readable -and
        (Test-DefenderStringSetEqual -Expected $expectedInstalled -Actual $actualInstalled) -and
        (Test-DefenderStringSetEqual -Expected $expectedProvisioned -Actual $actualProvisioned) -and
        (Test-DefenderStringSetEqual -Expected $expectedMarkers -Actual $actualMarkers)
    return (New-DefenderSingleEffectResult -Name 'VerifySecHealthUIBaseline' `
        -Target 'Microsoft.SecHealthUI' -Attempted $false -Changed $false -Verified $verified `
        -Evidence @{
            ExpectedInstalled   = $expectedInstalled
            ActualInstalled     = $actualInstalled
            ExpectedProvisioned = $expectedProvisioned
            ActualProvisioned   = $actualProvisioned
            ExpectedMarkers     = $expectedMarkers
            ActualMarkers       = $actualMarkers
        } -Errors $(if ($verified) { @() } else { @('SecHealthUI differs from the recorded baseline.') }))
}

function Test-RestoreManifestEntryBaseline {
    param(
        [Parameter(Mandatory)]$Entry
    )

    $data = $Entry.Data
    switch ($Entry.Action) {
        'RemoveRegistryValue' {
            $state = Get-RestoreRegistryValueState -Path $data.Path -Name $data.Name
            $verified = $state.Readable -and -not $state.Exists
            return (New-DefenderSingleEffectResult -Name 'VerifyRegistryBaseline' -Target $Entry.Target `
                -Attempted $false -Changed $false -Verified $verified `
                -Evidence @{ Expected = 'Absent'; Actual = $(if ($state.Exists) { 'Present' } else { 'Absent' }) } `
                -Errors $(if ($verified) { @() } else { @('Registry value differs from the recorded baseline.') }))
        }
        'RestoreRegistryValue' {
            $state = Get-RestoreRegistryValueState -Path $data.Path -Name $data.Name
            $verified = $state.Readable -and $state.Exists -and $state.Kind -eq $data.Kind -and
                (Test-DefenderRegistryValue -State $state -Expected $data.Value)
            return (New-DefenderSingleEffectResult -Name 'VerifyRegistryBaseline' -Target $Entry.Target `
                -Attempted $false -Changed $false -Verified $verified `
                -Evidence @{ ExpectedKind = $data.Kind; ActualKind = $state.Kind; ExpectedValue = $data.Value; ActualValue = $state.Value } `
                -Errors $(if ($verified) { @() } else { @('Registry value differs from the recorded baseline.') }))
        }
        'RestoreRegistryTree' {
            try { $actualTree = Export-RegistryTree -Path $data.Path } catch { $actualTree = $null }
            $verified = Test-DefenderRegistryTreeEqual -Expected $data.Tree -Actual $actualTree
            return (New-DefenderSingleEffectResult -Name 'VerifyRegistryTreeBaseline' -Target $Entry.Target `
                -Attempted $false -Changed $false -Verified $verified `
                -Evidence @{ Expected = $data.Tree; Actual = $actualTree } `
                -Errors $(if ($verified) { @() } else { @('Registry tree differs from the recorded baseline.') }))
        }
        'SetServiceStart' {
            $map = @{ Boot=0; System=1; Automatic=2; Manual=3; Disabled=4 }
            $state = Get-DefenderServiceStartState `
                -RegistryPath "HKLM:\SYSTEM\CurrentControlSet\Services\$($data.Service)"
            $verified = $state.Readable -and $state.Exists -and $state.Value -eq $map[[string]$data.State]
            return (New-DefenderSingleEffectResult -Name 'VerifyServiceStartBaseline' `
                -Target "Service:$($data.Service):Start" -Attempted $false -Changed $false `
                -Verified $verified -Evidence @{ Expected = $data.State; ActualValue = $state.Value } `
                -Errors $(if ($verified) { @() } else { @('Service start value differs from the recorded baseline.') }))
        }
        'StartService' {
            $state = Get-DefenderServiceRuntimeState -Service $data.Service
            $verified = $state.Readable -and $state.Exists -and $state.Status -eq 'Running'
            return (New-DefenderSingleEffectResult -Name 'VerifyServiceRuntimeBaseline' `
                -Target "Service:$($data.Service):Runtime" -Attempted $false -Changed $false `
                -Verified $verified -Evidence @{ Expected = 'Running'; Actual = $state.Status } `
                -Errors $(if ($verified) { @() } else { @('Service runtime differs from the recorded baseline.') }))
        }
        'SetScheduledTaskState' {
            $state = Get-DefenderScheduledTaskState -TaskPath $data.TaskPath
            $verified = $state.Readable -and $state.Exists -and
                $state.Enabled -eq [bool]$data.Enabled
            return (New-DefenderSingleEffectResult -Name 'VerifyTaskBaseline' -Target $data.TaskPath `
                -Attempted $false -Changed $false -Verified $verified `
                -Evidence @{ ExpectedEnabled = [bool]$data.Enabled; ActualEnabled = $state.Enabled } `
                -Errors $(if ($verified) { @() } else { @('Scheduled task differs from the recorded baseline.') }))
        }
        'SetMpPreference' {
            try {
                $preferences = Get-MpPreference -ErrorAction Stop
                $available = $preferences.PSObject.Properties.Name -contains $data.Name
                $actual = if ($available) { $preferences.($data.Name) } else { $null }
                $verified = $available -and
                    (Test-DefenderMpPreferenceValue -Actual $actual -Expected $data.Value)
            } catch {
                $actual = 'Unavailable'
                $verified = $false
            }
            return (New-DefenderSingleEffectResult -Name 'VerifyMpPreferenceBaseline' -Target $data.Name `
                -Attempted $false -Changed $false -Verified $verified `
                -Evidence @{ Expected = $data.Value; Actual = $actual } `
                -Errors $(if ($verified) { @() } else { @('MpPreference differs from the recorded baseline.') }))
        }
        'RemoveMpPreferenceValue' {
            try {
                $preferences = Get-MpPreference -ErrorAction Stop
                $available = $preferences.PSObject.Properties.Name -contains $data.Parameter
                $present = $available -and
                    (@($preferences.($data.Parameter)) -contains $data.Value)
                $verified = $available -and -not $present
            } catch {
                $present = $null
                $verified = $false
            }
            return (New-DefenderSingleEffectResult -Name 'VerifyMpPreferenceBaseline' -Target $Entry.Target `
                -Attempted $false -Changed $false -Verified $verified `
                -Evidence @{ Expected = 'Absent'; Actual = $(if ($present) { 'Present' } else { 'AbsentOrUnavailable' }) } `
                -Errors $(if ($verified) { @() } else { @('MpPreference exclusion differs from the recorded baseline.') }))
        }
        'RestoreSecHealthUI' {
            return (Test-DefenderSecHealthUIBaseline -Baseline $data)
        }
        'DismRestoreHealth' {
            $state = Get-DefenderPlatformPackageState
            $verified = $state.Readable -and $state.Packages -contains $data.PackageName
            return (New-DefenderSingleEffectResult -Name 'VerifyDismPackageBaseline' -Target $Entry.Target `
                -Attempted $false -Changed $false -Verified $verified `
                -Evidence @{ Expected = 'Present'; Actual = $(if ($verified) { 'Present' } else { 'AbsentOrUnavailable' }); QueryExitCode = $state.ExitCode } `
                -Errors $(if ($verified) { @() } else { @('DISM package differs from the recorded baseline.') }))
        }
        default {
            throw "Unsupported restore verification action '$($Entry.Action)'."
        }
    }
}

function Move-RestoreManifestToArchive {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    Move-Item -LiteralPath $Source -Destination $Destination -ErrorAction Stop
}

function Complete-RestoreManifestReplay {
    param(
        [Parameter(Mandatory)]$Plan
    )

    $result = New-DefenderActionResult -Name 'RestoreManifestFinalize'
    $state = Read-RestoreReplayState
    if ($null -eq $state -or $state.PlanSignature -ne $Plan.Signature) {
        return (New-DefenderSingleEffectResult -Name $result.Name -Target 'RestoreReplayState' `
            -Attempted $false -Changed $false -Verified $false `
            -Evidence @{ Expected = $Plan.Signature; Actual = $(if ($null -eq $state) { 'Absent' } else { $state.PlanSignature }) } `
            -Errors 'Restore replay state does not match the verified manifest plan.')
    }

    try {
        $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
        foreach ($record in @($state.Manifests)) {
            if ($record.PSObject.Properties.Name -notcontains 'ArchivePath') {
                $record | Add-Member -NotePropertyName ArchivePath -NotePropertyValue $null
            }
            if ($record.PSObject.Properties.Name -notcontains 'Archived') {
                $record | Add-Member -NotePropertyName Archived -NotePropertyValue $false
            }
            if ([string]::IsNullOrWhiteSpace([string]$record.ArchivePath)) {
                $directory = Split-Path -Parent $record.Path
                $archiveName = if ([bool]$record.IsActive) {
                    "restore-manifest.restored.${timestamp}.jsonl"
                } else {
                    "restore-manifest.restored.${timestamp}.$($record.Name)"
                }
                $record.ArchivePath = New-RestoreManifestSiblingPath `
                    -Directory $directory -Name $archiveName
            }
        }
        Save-RestoreReplayState -State $state

        # Validate the complete source set before moving any manifest.
        foreach ($record in @($state.Manifests)) {
            $currentPath = if (Test-Path -LiteralPath $record.Path) {
                [string]$record.Path
            } elseif (Test-Path -LiteralPath $record.ArchivePath) {
                [string]$record.ArchivePath
            } else {
                throw "Manifest disappeared before finalization: $($record.Path)"
            }
            $actualDigest = Get-RestoreManifestDigest -Path $currentPath
            if ($actualDigest -ne [string]$record.Digest) {
                throw "Manifest bytes changed before finalization: $currentPath"
            }
        }
    } catch {
        $state.Status = 'FinalizeFailed'
        $state.LastError = $_.Exception.Message
        Save-RestoreReplayState -State $state
        return (New-DefenderSingleEffectResult -Name $result.Name -Target 'RestoreManifestSet' `
            -Attempted $false -Changed $false -Verified $false `
            -Evidence @{ Expected = 'AllSourcesValidated'; Actual = 'ValidationFailed' } `
            -Errors $_.Exception.Message)
    }

    $state.Status = 'Finalizing'
    $state.LastError = $null
    Save-RestoreReplayState -State $state
    foreach ($record in @($state.Manifests)) {
        try {
            $sourcePath = [string]$record.Path
            $archivePath = [string]$record.ArchivePath
            $alreadyArchived = -not (Test-Path -LiteralPath $sourcePath) -and
                (Test-Path -LiteralPath $archivePath)
            if (-not $alreadyArchived) {
                Move-RestoreManifestToArchive -Source $sourcePath -Destination $archivePath
            }
            $archiveDigest = if (Test-Path -LiteralPath $archivePath) {
                Get-RestoreManifestDigest -Path $archivePath
            } else {
                'missing'
            }
            $verified = -not (Test-Path -LiteralPath $sourcePath) -and
                $archiveDigest -eq [string]$record.Digest
            if (-not $verified) {
                throw "Manifest archive move could not be verified: $sourcePath"
            }
            $record.Archived = $true
            Save-RestoreReplayState -State $state
            Add-DefenderEffect -Result $result -Target $sourcePath `
                -Attempted (-not $alreadyArchived) -Changed (-not $alreadyArchived) -Verified $true `
                -Evidence @{
                    Expected = 'ArchivedAfterVerification'
                    Actual   = $archivePath
                    Digest   = $archiveDigest
                    State    = $(if ($alreadyArchived) { 'RecoveredAfterInterruption' } else { 'Archived' })
                }
            Write-Log ("Archived verified restore manifest to {0} (RunIds={1}; Entries={2}; SHA256={3})" -f `
                $archivePath, ($record.RunIds -join ','), $record.EntryCount, $archiveDigest) INFO
        } catch {
            $state.Status = 'FinalizeFailed'
            $state.LastError = $_.Exception.Message
            Save-RestoreReplayState -State $state
            Add-DefenderEffect -Result $result -Target $record.Path -Attempted $true `
                -Changed $false -Verified $false `
                -Evidence @{ Expected = 'ArchivedAfterVerification'; Actual = 'Failed' } `
                -Errors $_.Exception.Message
            break
        }
    }

    $completed = Complete-DefenderActionResult -Result $result
    if (-not $completed.Succeeded) { return $completed }

    try {
        $state.Status = 'Completed'
        $state.LastError = $null
        Save-RestoreReplayState -State $state
        $statePath = Get-RestoreReplayStatePath
        Remove-Item -LiteralPath $statePath -Force -ErrorAction Stop
    } catch {
        Add-DefenderEffect -Result $result -Target (Get-RestoreReplayStatePath) `
            -Attempted $true -Changed $false -Verified $false `
            -Evidence @{ Expected = 'RemovedAfterArchive'; Actual = 'PresentOrUnknown' } `
            -Errors $_.Exception.Message
    }
    return (Complete-DefenderActionResult -Result $result)
}

function Test-RestoreManifestBaseline {
    param(
        [ValidateSet('Newest','All','Active')]
        [string]$Selection = 'Newest'
    )

    $result = New-DefenderActionResult -Name 'RecordedBaselineVerification'
    $state = Read-RestoreReplayState
    if ($null -eq $state -or $state.Status -ne 'AwaitingVerification') {
        return (New-DefenderSingleEffectResult -Name $result.Name -Target 'RestoreReplayState' `
            -Attempted $false -Changed $false -Verified $false `
            -Evidence @{ Expected = 'AwaitingVerification'; Actual = $(if ($null -eq $state) { 'Absent' } else { $state.Status }) } `
            -Errors 'Restore replay is not ready for exact baseline verification.')
    }
    $plan = Get-RestoreManifestReplayPlan -Selection $Selection
    if ($plan.Signature -ne $state.PlanSignature) {
        return (New-DefenderSingleEffectResult -Name $result.Name -Target 'RestoreReplayState' `
            -Attempted $false -Changed $false -Verified $false `
            -Evidence @{ Expected = $state.PlanSignature; Actual = $plan.Signature } `
            -Errors 'Selected manifest bytes changed before exact baseline verification.')
    }

    foreach ($entry in (Get-RestoreManifestFinalExpectations -Plan $plan)) {
        $childResult = Test-RestoreManifestEntryBaseline -Entry $entry
        Merge-DefenderActionResult -Result $result -ChildResult $childResult
    }
    $completed = Complete-DefenderActionResult -Result $result
    if (-not $completed.Succeeded) {
        $state.Status = 'VerificationFailed'
        $state.LastError = 'Exact recorded baseline verification failed.'
        Save-RestoreReplayState -State $state
        return $completed
    }

    $finalizeResult = Complete-RestoreManifestReplay -Plan $plan
    Merge-DefenderActionResult -Result $result -ChildResult $finalizeResult
    return (Complete-DefenderActionResult -Result $result)
}

function Invoke-DefenderRestoreManifestPlan {
    param(
        [ValidateSet('Newest','All','Active')]
        [string]$Selection = 'Newest'
    )

    $result = New-DefenderActionResult -Name 'RestoreManifestReplay' -Simulation:$WhatIfPreference
    $candidateCount = @(Get-RestoreManifestCandidates).Count
    if ($WhatIfPreference) {
        Add-DefenderEffect -Result $result -Target 'RestoreManifestReplay' -Required $false `
            -Attempted $false -Changed $false -Verified $false `
            -Evidence @{ Selection = $Selection; CandidateCount = $candidateCount; State = 'Simulation' }
        return (Complete-DefenderActionResult -Result $result)
    }

    try {
        $succeeded = [bool](Invoke-RestoreManifest -Selection $Selection)
        Add-DefenderEffect -Result $result -Target 'RestoreManifestReplay' `
            -Required ($candidateCount -gt 0) -Attempted ($candidateCount -gt 0) `
            -Changed ($candidateCount -gt 0 -and $succeeded) -Verified $succeeded `
            -Evidence @{ Selection = $Selection; CandidateCount = $candidateCount; ReplayCompleted = $succeeded } `
            -Errors $(if ($succeeded) { @() } else { @('One or more restore manifest entries failed to replay.') })
    } catch {
        Add-DefenderEffect -Result $result -Target 'RestoreManifestReplay' `
            -Required ($candidateCount -gt 0) -Attempted ($candidateCount -gt 0) `
            -Changed $false -Verified $false `
            -Evidence @{ Selection = $Selection; CandidateCount = $candidateCount; ReplayCompleted = $false } `
            -Errors $_.Exception.Message
    }
    return (Complete-DefenderActionResult -Result $result)
}
