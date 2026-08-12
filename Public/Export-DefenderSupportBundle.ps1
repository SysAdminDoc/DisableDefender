function Get-DefenderSupportBundlePrivacySchema {
    param(
        [switch]$IncludeSensitiveDiagnostics
    )

    $defaultAllowlist = @(
        'DisableDefender.log'
        'DisableDefender.jsonl'
        'phase-state.json'
        'surface-baseline.json'
    )
    $sensitiveAllowlist = @(
        'transcript.log'
        'tripwire.jsonl'
    )
    $excludedPatterns = @(
        'restore-manifest.jsonl'
        'acl-backup*'
        '*.clixml'
        '*.evtx'
        '*.dmp'
        '*.pfx'
        '*.cer'
    )
    if (-not $IncludeSensitiveDiagnostics) {
        $excludedPatterns += $sensitiveAllowlist
    }

    return [ordered]@{
        SchemaVersion = Get-DefenderArtifactSchemaVersion -Name SupportBundlePrivacy
        Policy = 'LocalSupportAllowlistV1'
        UploadPolicy = 'Never; local filesystem only.'
        AllowedRuntimeFiles = @($defaultAllowlist)
        SensitiveOptInRuntimeFiles = @($sensitiveAllowlist)
        ExcludedPatterns = @($excludedPatterns)
        RedactionRules = @(
            'Credential-like values are replaced with [REDACTED:SECRET].'
            'User, computer, domain, and account values are replaced with [REDACTED:IDENTITY].'
            'Drive-qualified and UNC paths are replaced with [REDACTED:PATH].'
            'Only the explicitly listed runtime files are considered for collection.'
        )
        IncludeSensitiveDiagnostics = [bool]$IncludeSensitiveDiagnostics
    }
}

function Resolve-DefenderSupportBundleOutputDirectory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Create
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath)) {
        if (-not $Create) { return $fullPath }
        New-Item -ItemType Directory -Path $fullPath -ErrorAction Stop | Out-Null
    }

    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    if (-not $item.PSIsContainer) {
        throw "Support bundle output path is not a directory: $fullPath"
    }
    if (([int]$item.Attributes -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Support bundle output directory is a reparse point: $fullPath"
    }
    return $item.FullName
}

function New-DefenderSupportBundleStaging {
    $tempRoot = if ([string]::IsNullOrWhiteSpace($env:TEMP)) {
        [System.IO.Path]::GetTempPath()
    } else {
        $env:TEMP
    }
    $tempRoot = [System.IO.Path]::GetFullPath($tempRoot).TrimEnd('\')
    $tempItem = Get-Item -LiteralPath $tempRoot -Force -ErrorAction Stop
    if (-not $tempItem.PSIsContainer) {
        throw "Support bundle temporary root is not a directory: $tempRoot"
    }
    if (([int]$tempItem.Attributes -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Support bundle temporary root is a reparse point: $tempRoot"
    }

    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        $bundleId = [guid]::NewGuid().ToString('N')
        $candidate = Join-Path $tempRoot "DisableDefender-support-$bundleId"
        if (-not (Test-DefenderStrictPathDescendant -Parent $tempRoot -Child $candidate)) {
            throw "Support bundle staging path escaped the temporary root: $candidate"
        }

        try {
            New-Item -ItemType Directory -Path $candidate -ErrorAction Stop | Out-Null
        } catch {
            if (Test-Path -LiteralPath $candidate) { continue }
            throw
        }

        try {
            $item = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
            if (-not $item.PSIsContainer) {
                throw "Support bundle staging path is not a directory: $candidate"
            }
            if (([int]$item.Attributes -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Support bundle staging directory is a reparse point: $candidate"
            }
            return [PSCustomObject]@{
                BundleId = $bundleId
                Path = $item.FullName
                ParentPath = $tempRoot
                CreationTimeUtc = $item.CreationTimeUtc
            }
        } catch {
            try { [System.IO.Directory]::Delete($candidate, $false) } catch {}
            throw
        }
    }

    throw 'Unable to allocate a unique support bundle staging directory.'
}

function Remove-DefenderSupportBundleStaging {
    param(
        [Parameter(Mandatory)]$Staging
    )

    $path = [System.IO.Path]::GetFullPath([string]$Staging.Path)
    $parent = [System.IO.Path]::GetFullPath([string]$Staging.ParentPath).TrimEnd('\')
    if (-not (Test-DefenderStrictPathDescendant -Parent $parent -Child $path)) {
        throw "Refusing to remove support bundle staging outside its temporary root: $path"
    }
    if (-not (Test-Path -LiteralPath $path)) { return }

    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer) {
        throw "Refusing to remove a non-directory support bundle staging path: $path"
    }
    if (([int]$item.Attributes -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to remove a reparse-point support bundle staging path: $path"
    }
    if ($item.CreationTimeUtc -ne ([datetime]$Staging.CreationTimeUtc)) {
        throw "Refusing to remove a replaced support bundle staging directory: $path"
    }

    [System.IO.Directory]::Delete($path, $true)
}

function ConvertTo-DefenderSupportBundleRedactedText {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )

    $result = $Text
    $count = 0
    $rules = @(
        [PSCustomObject]@{
            Name = 'SecretValue'
            Pattern = '(?i)("?(?:password|secret|token|apikey|api_key|credential)"?\s*:\s*")[^"]*(")'
            Replacement = '$1[REDACTED:SECRET]$2'
        }
        [PSCustomObject]@{
            Name = 'SecretAssignment'
            Pattern = '(?i)\b(?:password|secret|token|apikey|api_key|credential)\s*[:=]\s*(?:"[^"]*"|\S+)'
            Replacement = '[REDACTED:SECRET]'
        }
        [PSCustomObject]@{
            Name = 'IdentityValue'
            Pattern = '(?i)("?(?:username|user_name|computername|computer_name|domain|machinename|machine_name|account)"?\s*:\s*")[^"]*(")'
            Replacement = '$1[REDACTED:IDENTITY]$2'
        }
        [PSCustomObject]@{
            Name = 'IdentityAssignment'
            Pattern = '(?i)\b(?:username|user_name|computername|computer_name|domain|machinename|machine_name|account)\s*[:=]\s*[^\s,;]+'
            Replacement = '[REDACTED:IDENTITY]'
        }
        [PSCustomObject]@{
            Name = 'DriveOrUncPath'
            Pattern = '(?i)(?<![A-Za-z0-9])(?:[A-Z]:\\|\\\\)\S+'
            Replacement = '[REDACTED:PATH]'
        }
        [PSCustomObject]@{
            Name = 'DomainIdentity'
            Pattern = '(?i)\b[A-Za-z0-9][A-Za-z0-9._-]{0,63}\\[A-Za-z0-9._$-]{1,64}\b'
            Replacement = '[REDACTED:IDENTITY]'
        }
    )

    foreach ($rule in $rules) {
        $ruleMatches = [regex]::Matches($result, $rule.Pattern)
        $count += $ruleMatches.Count
        if ($ruleMatches.Count -gt 0) {
            $result = [regex]::Replace($result, $rule.Pattern, $rule.Replacement)
        }
    }

    return [PSCustomObject]@{
        Text = $result
        RedactionCount = $count
    }
}

function Get-DefenderSupportBundleRuntimeText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(1, 16777216)][int]$MaximumBytes = 16777216
    )

    $runtimeRoot = [System.IO.Path]::GetFullPath($script:AppDir)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    Assert-DefenderRuntimePathComponents -RuntimeRoot $runtimeRoot -Path $fullPath

    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    if ($item.PSIsContainer) {
        throw "Support bundle runtime artifact is a directory: $fullPath"
    }
    if (([int]$item.Attributes -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Support bundle runtime artifact is a reparse point: $fullPath"
    }

    if (Test-DefenderDefaultRuntimeDirectory -Path $runtimeRoot) {
        $lease = $null
        try {
            $lease = Open-DefenderPrivilegedRuntimeFile -Path $fullPath `
                -MaximumBytes $MaximumBytes
            return [PSCustomObject]@{
                Text = ConvertFrom-DefenderRuntimeFileBytes -Bytes $lease.Bytes
                Length = $lease.Length
            }
        } finally {
            if ($null -ne $lease) { $lease.Dispose() }
        }
    }

    if ($item.Length -gt $MaximumBytes) {
        throw "Support bundle runtime artifact exceeds the $MaximumBytes byte limit: $fullPath"
    }
    $bytes = [System.IO.File]::ReadAllBytes($fullPath)
    $after = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    if ($after.Length -ne $bytes.Length -or
        ([int]$after.Attributes -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Support bundle runtime artifact changed while being read: $fullPath"
    }
    return [PSCustomObject]@{
        Text = ConvertFrom-DefenderRuntimeFileBytes -Bytes $bytes
        Length = $bytes.Length
    }
}

function Add-DefenderSupportBundleRuntimeFile {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    try {
        $source = Get-DefenderSupportBundleRuntimeText -Path $SourcePath
        $redacted = ConvertTo-DefenderSupportBundleRedactedText -Text $source.Text
        [System.IO.File]::WriteAllText(
            $DestinationPath,
            $redacted.Text,
            (New-Object System.Text.UTF8Encoding($false)))
        return [PSCustomObject]@{
            Included = $true
            RedactionCount = $redacted.RedactionCount
            Error = $null
        }
    } catch {
        return [PSCustomObject]@{
            Included = $false
            RedactionCount = 0
            Error = 'Artifact could not be collected safely.'
        }
    }
}

function Write-DefenderSupportBundleJsonArtifact {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$InputObject,
        [ValidateRange(2, 32)][int]$Depth = 12
    )

    $json = $InputObject | ConvertTo-Json -Depth $Depth
    $redacted = ConvertTo-DefenderSupportBundleRedactedText -Text $json
    $safeDocument = $redacted.Text | ConvertFrom-Json -ErrorAction Stop
    Write-DefenderJsonArtifactAtomic -Name $Name -Path $Path `
        -InputObject $safeDocument -Depth $Depth | Out-Null
    return [int]$redacted.RedactionCount
}

function Resolve-DefenderSupportBundleHealthTarget {
    param(
        [string]$RequestedTarget,
        [Parameter(Mandatory)][string]$RuntimeDirectory
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedTarget)) {
        return [PSCustomObject]@{
            Target = $RequestedTarget
            Source = 'Explicit'
        }
    }

    $phaseStatePath = Join-Path $RuntimeDirectory 'phase-state.json'
    $phaseStateExists = $false
    try {
        $phaseStateExists = Test-Path -LiteralPath $phaseStatePath -ErrorAction Stop
    } catch {}
    if ($phaseStateExists) {
        try {
            $content = Get-DefenderSupportBundleRuntimeText -Path $phaseStatePath
            $state = $content.Text | ConvertFrom-Json -ErrorAction Stop
            $mode = [string]$state.Mode
            if ($mode -in @('Disable','Remove','Restore')) {
                return [PSCustomObject]@{
                    Target = $mode
                    Source = 'PhaseState'
                }
            }
        } catch {}
    }

    return [PSCustomObject]@{
        Target = 'Disable'
        Source = 'Default'
    }
}

function Export-DefenderSupportBundle {
    <#
    .SYNOPSIS
        Exports an explicit-target, privacy-redacted diagnostic zip locally.
    .DESCRIPTION
        Collects a versioned allowlist of health, component, phase, log, and
        optional event data into a unique temporary staging directory. The
        target is taken from -HealthTarget or the latest phase-state Mode.
        Transcript and tripwire files require -IncludeSensitiveDiagnostics.
        No upload or other network operation is performed.
    .PARAMETER OutputDirectory
        Directory where the zip is written. Defaults to the current directory.
    .PARAMETER HealthTarget
        Expected health target: Disable, Remove, or Restore. If omitted, the
        latest phase-state Mode is used; when no valid state exists, Disable is
        recorded as the explicit fallback.
    .PARAMETER IncludeEventLog
        Include the last 100 Microsoft-Windows-Windows Defender/Operational
        event-log entries after the standard redaction rules are applied.
    .PARAMETER IncludeSensitiveDiagnostics
        Opt in to redacted transcript.log and tripwire.jsonl collection.
    .PARAMETER Preview
        Return the local allowlist, target source, output path, and upload
        policy without collecting data or creating a zip.
    .EXAMPLE
        Export-DefenderSupportBundle -HealthTarget Remove
    .EXAMPLE
        Export-DefenderSupportBundle -OutputDirectory C:\Support `
            -HealthTarget Remove -IncludeEventLog -Preview
    #>
    [CmdletBinding()]
    param(
        [string]$OutputDirectory = '.',
        [Alias('Target')]
        [ValidateSet('Disable','Remove','Restore')]
        [string]$HealthTarget,
        [switch]$IncludeEventLog,
        [switch]$IncludeSensitiveDiagnostics,
        [switch]$Preview
    )

    $runtimeDir = [System.IO.Path]::GetFullPath($script:AppDir)
    $targetInfo = Resolve-DefenderSupportBundleHealthTarget `
        -RequestedTarget $HealthTarget -RuntimeDirectory $runtimeDir
    $privacy = Get-DefenderSupportBundlePrivacySchema `
        -IncludeSensitiveDiagnostics:$IncludeSensitiveDiagnostics
    $resolvedOutput = Resolve-DefenderSupportBundleOutputDirectory `
        -Path $OutputDirectory -Create:(-not $Preview)

    if ($Preview) {
        return [PSCustomObject]@{
            Preview = $true
            Version = $script:Version
            HealthTarget = $targetInfo.Target
            HealthTargetSource = $targetInfo.Source
            OutputDirectory = $resolvedOutput
            OutputPathPattern = Join-Path $resolvedOutput 'DisableDefender-support-<timestamp>-<unique-id>.zip'
            IncludeEventLog = [bool]$IncludeEventLog
            IncludeSensitiveDiagnostics = [bool]$IncludeSensitiveDiagnostics
            PrivacySchemaVersion = $privacy.SchemaVersion
            AllowedRuntimeFiles = @($privacy.AllowedRuntimeFiles)
            SensitiveOptInRuntimeFiles = @($privacy.SensitiveOptInRuntimeFiles)
            ExcludedPatterns = @($privacy.ExcludedPatterns)
            UploadPolicy = $privacy.UploadPolicy
        }
    }

    $staging = New-DefenderSupportBundleStaging
    try {
        $bundleDir = $staging.Path
        $generatedAt = (Get-Date).ToString('o')
        $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss')
        $includedFiles = New-Object System.Collections.ArrayList
        $collectionErrors = New-Object System.Collections.ArrayList
        $redactionTotal = 0

        $summary = [ordered]@{
            SchemaVersion = Get-DefenderArtifactSchemaVersion -Name SupportBundleSummary
            GeneratedAt = $generatedAt
            Version = $script:Version
            BundleId = $staging.BundleId
            HealthTarget = $targetInfo.Target
            HealthTargetSource = $targetInfo.Source
            UploadPolicy = $privacy.UploadPolicy
            PrivacySchemaVersion = $privacy.SchemaVersion
        }

        try {
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            $summary.WindowsBuild = [ordered]@{
                Caption = $os.Caption
                Version = $os.Version
                BuildNumber = $os.BuildNumber
            }
            try {
                $displayVer = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'DisplayVersion' -ErrorAction Stop).DisplayVersion
                $summary.WindowsBuild.DisplayVersion = $displayVer
            } catch {}
        } catch {
            $summary.WindowsBuild = 'unavailable'
        }

        $summary.LanguageMode = [string]$ExecutionContext.SessionState.LanguageMode
        try {
            $summary.IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        } catch {
            $summary.IsAdmin = $false
        }
        try {
            $summary.SafeMode = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).BootupState -like '*Fail-safe*'
        } catch {
            $summary.SafeMode = $null
        }

        $healthWritten = $false
        try {
            $health = Get-DefenderHealth -Target $targetInfo.Target
            $summary.Health = [ordered]@{
                Target = $health.Target
                Summary = $health.Summary
            }
            $healthDocument = [ordered]@{
                SchemaVersion = Get-DefenderArtifactSchemaVersion -Name SupportBundleHealth
                GeneratedAt = (Get-Date).ToString('o')
                Data = $health
            }
            $redactionTotal += Write-DefenderSupportBundleJsonArtifact `
                -Name SupportBundleHealth -Path (Join-Path $bundleDir 'health.json') `
                -InputObject $healthDocument -Depth 10
            $healthWritten = $true
        } catch {
            $summary.Health = 'unavailable'
            [void]$collectionErrors.Add('health.json')
            Write-Log 'Support bundle: health collection failed.' WARN
        }

        $componentsWritten = $false
        try {
            $components = @(Get-DefenderComponentStatus)
            $summary.ComponentCount = $components.Count
            $componentDocument = [ordered]@{
                SchemaVersion = Get-DefenderArtifactSchemaVersion -Name SupportBundleComponents
                GeneratedAt = (Get-Date).ToString('o')
                Data = @($components)
            }
            $redactionTotal += Write-DefenderSupportBundleJsonArtifact `
                -Name SupportBundleComponents -Path (Join-Path $bundleDir 'components.json') `
                -InputObject $componentDocument -Depth 6
            $componentsWritten = $true
        } catch {
            $summary.ComponentCount = 0
            [void]$collectionErrors.Add('components.json')
            Write-Log 'Support bundle: component collection failed.' WARN
        }

        if (Test-Path -LiteralPath $runtimeDir) {
            $runtimeArtifacts = @(
                [PSCustomObject]@{ FileName = "$script:AppName.log"; Sensitive = $false }
                [PSCustomObject]@{ FileName = "$script:AppName.jsonl"; Sensitive = $false }
                [PSCustomObject]@{ FileName = 'phase-state.json'; Sensitive = $false }
                [PSCustomObject]@{ FileName = 'surface-baseline.json'; Sensitive = $false }
                [PSCustomObject]@{ FileName = 'transcript.log'; Sensitive = $true }
                [PSCustomObject]@{ FileName = 'tripwire.jsonl'; Sensitive = $true }
            )
            foreach ($artifact in $runtimeArtifacts) {
                if ($artifact.Sensitive -and -not $IncludeSensitiveDiagnostics) {
                    $privacy['ExcludedPatterns'] = @($privacy['ExcludedPatterns']) + @($artifact.FileName)
                    continue
                }
                $sourcePath = Join-Path $runtimeDir $artifact.FileName
                $sourceExists = $false
                try {
                    $sourceExists = Test-Path -LiteralPath $sourcePath -ErrorAction Stop
                } catch {}
                if (-not $sourceExists) { continue }
                $destinationPath = Join-Path $bundleDir $artifact.FileName
                $copyResult = Add-DefenderSupportBundleRuntimeFile `
                    -SourcePath $sourcePath -DestinationPath $destinationPath
                if ($copyResult.Included) {
                    [void]$includedFiles.Add($artifact.FileName)
                    $redactionTotal += [int]$copyResult.RedactionCount
                } else {
                    [void]$collectionErrors.Add($artifact.FileName)
                }
            }
        }

        if ($IncludeEventLog) {
            try {
                $events = Get-WinEvent -LogName 'Microsoft-Windows-Windows Defender/Operational' `
                    -MaxEvents 100 -ErrorAction Stop
                $redactedEvents = @($events | ForEach-Object {
                    $message = ConvertTo-DefenderSupportBundleRedactedText `
                        -Text ([string]$_.Message)
                    $redactionTotal += [int]$message.RedactionCount
                    [ordered]@{
                        TimeCreated = $_.TimeCreated.ToString('o')
                        Id = $_.Id
                        Level = $_.LevelDisplayName
                        Message = $message.Text
                    }
                })
                $eventDocument = [ordered]@{
                    SchemaVersion = Get-DefenderArtifactSchemaVersion -Name SupportBundleEvents
                    GeneratedAt = (Get-Date).ToString('o')
                    Data = @($redactedEvents)
                }
                $redactionTotal += Write-DefenderSupportBundleJsonArtifact `
                    -Name SupportBundleEvents -Path (Join-Path $bundleDir 'defender-events.json') `
                    -InputObject $eventDocument -Depth 6
                $summary.EventLogEntries = $redactedEvents.Count
            } catch {
                $summary.EventLogEntries = 'unavailable'
                [void]$collectionErrors.Add('defender-events.json')
            }
        }

        $generatedFiles = @('summary.json', 'privacy.json')
        if ($healthWritten) { $generatedFiles += 'health.json' }
        if ($componentsWritten) { $generatedFiles += 'components.json' }
        if ($IncludeEventLog -and (Test-Path -LiteralPath (Join-Path $bundleDir 'defender-events.json'))) {
            $generatedFiles += 'defender-events.json'
        }
        $privacy['IncludedFiles'] = @(
            @($includedFiles) + @($generatedFiles) |
                Select-Object -Unique
        )
        $privacy['CollectionErrors'] = @($collectionErrors)
        $privacy['RedactionsApplied'] = $redactionTotal
        $summary.Privacy = [ordered]@{
            SchemaVersion = $privacy.SchemaVersion
            IncludedFiles = @($privacy.IncludedFiles)
            ExcludedPatterns = @($privacy.ExcludedPatterns)
            RedactionsApplied = $redactionTotal
            CollectionErrors = @($collectionErrors)
        }

        Write-DefenderJsonArtifactAtomic -Name SupportBundleSummary `
            -Path (Join-Path $bundleDir 'summary.json') `
            -InputObject $summary -Depth 8 | Out-Null
        Write-DefenderJsonArtifactAtomic -Name SupportBundlePrivacy `
            -Path (Join-Path $bundleDir 'privacy.json') `
            -InputObject $privacy -Depth 8 | Out-Null

        $zipName = "DisableDefender-support-$stamp-$($staging.BundleId).zip"
        $zipPath = Join-Path $resolvedOutput $zipName
        if (Test-Path -LiteralPath $zipPath) {
            throw "Support bundle output already exists; refusing to overwrite: $zipPath"
        }

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::CreateFromDirectory(
            $bundleDir,
            $zipPath,
            [System.IO.Compression.CompressionLevel]::Optimal,
            $false)

        Write-Log "Support bundle exported locally: $zipPath" OK

        return [PSCustomObject]@{
            ZipPath = $zipPath
            Generated = $stamp
            BundleId = $staging.BundleId
            Version = $script:Version
            HealthTarget = $targetInfo.Target
            HealthTargetSource = $targetInfo.Source
            PrivacySchemaVersion = $privacy.SchemaVersion
            UploadPolicy = $privacy.UploadPolicy
        }
    } finally {
        try {
            Remove-DefenderSupportBundleStaging -Staging $staging
        } catch {
            Write-Log 'Support bundle staging cleanup was refused or failed; inspect the unique temporary directory.' WARN
        }
    }
}
