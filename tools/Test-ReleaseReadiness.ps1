#Requires -Version 5.1
<#
    Strict local release gate for DisableDefender.
    Tests and analyzes the source, validates the exact release artifact, and
    reproduces its ZIP hash from a fresh detached checkout.
#>
[CmdletBinding()]
param(
    [switch]$SkipAnalyzer,
    [switch]$SkipCoverage,
    [switch]$SkipCleanBuild
)

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$passed = 0
$failed = 0
$warnings = 0

function Write-Check {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]
        [ValidateSet('Pass', 'Fail', 'Warn', 'Info')]
        [string]$Result,
        [string]$Detail
    )

    $icon = switch ($Result) {
        'Pass' { '[PASS]'; $script:passed++ }
        'Fail' { '[FAIL]'; $script:failed++ }
        'Warn' { '[WARN]'; $script:warnings++ }
        'Info' { '[INFO]' }
    }
    $color = switch ($Result) {
        'Pass' { 'Green' }
        'Fail' { 'Red' }
        'Warn' { 'Yellow' }
        'Info' { 'Cyan' }
    }
    $line = "$icon $Name"
    if ($Detail) { $line += " -- $Detail" }
    Write-Host $line -ForegroundColor $color
}

function Get-ReleaseStreamSha256 {
    param([Parameter(Mandatory)][IO.Stream]$Stream)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return [BitConverter]::ToString(
            $sha256.ComputeHash($Stream)).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha256.Dispose()
    }
}

function Get-ReleaseFileSha256 {
    param([Parameter(Mandatory)][string]$Path)

    $stream = [IO.File]::OpenRead($Path)
    try {
        return Get-ReleaseStreamSha256 -Stream $stream
    } finally {
        $stream.Dispose()
    }
}

function Get-ReleaseTextVersion {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Label
    )

    $content = Get-Content -Raw -LiteralPath $Path -ErrorAction Stop
    $match = [regex]::Match($content, $Pattern)
    if (-not $match.Success) {
        throw "$Label version marker was not found in $Path."
    }
    return [string]$match.Groups['Version'].Value
}

function Get-ReleaseVersionMap {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)]$Manifest
    )

    $versions = [ordered]@{
        Manifest = [string]$Manifest.Version
        Variables = Get-ReleaseTextVersion `
            -Path (Join-Path $RepositoryRoot 'Private\Variables.ps1') `
            -Pattern "(?m)^\`$script:Version\s*=\s*'(?<Version>[0-9.]+)'" `
            -Label 'Private variables'
        'CLI header' = Get-ReleaseTextVersion `
            -Path (Join-Path $RepositoryRoot 'DisableDefender.ps1') `
            -Pattern 'DisableDefender v(?<Version>[0-9.]+)' `
            -Label 'CLI header'
        'GUI header' = Get-ReleaseTextVersion `
            -Path (Join-Path $RepositoryRoot 'DisableDefender.GUI.ps1') `
            -Pattern 'DisableDefender GUI v(?<Version>[0-9.]+)' `
            -Label 'GUI header'
        'GUI XAML' = Get-ReleaseTextVersion `
            -Path (Join-Path $RepositoryRoot 'DisableDefender.GUI.ps1') `
            -Pattern 'x:Name="versionText"\s+Text="v(?<Version>[0-9.]+)"' `
            -Label 'GUI XAML'
        'README badge' = Get-ReleaseTextVersion `
            -Path (Join-Path $RepositoryRoot 'README.md') `
            -Pattern 'version-(?<Version>[0-9.]+)-blue' `
            -Label 'README badge'
        CHANGELOG = Get-ReleaseTextVersion `
            -Path (Join-Path $RepositoryRoot 'CHANGELOG.md') `
            -Pattern '(?m)^## v(?<Version>[0-9.]+) - [0-9]{4}-[0-9]{2}-[0-9]{2}\r?$' `
            -Label 'CHANGELOG'
    }
    $releaseNotes = [string]$Manifest.PrivateData.PSData.ReleaseNotes
    $releaseNotesMatch = [regex]::Match(
        $releaseNotes,
        '^v(?<Version>[0-9.]+):')
    if (-not $releaseNotesMatch.Success) {
        throw 'Module ReleaseNotes do not begin with a version marker.'
    }
    $versions.ReleaseNotes =
        [string]$releaseNotesMatch.Groups['Version'].Value
    return $versions
}

function Get-ReleaseExpectedEntries {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string[]]$ReleasePaths
    )

    $entries = New-Object 'System.Collections.Generic.List[string]'
    foreach ($releasePath in $ReleasePaths) {
        $source = Join-Path $RepositoryRoot $releasePath
        if (-not (Test-Path -LiteralPath $source)) {
            throw "Configured release input is missing: $source"
        }
        $item = Get-Item -LiteralPath $source -Force -ErrorAction Stop
        if ($item.PSIsContainer) {
            foreach ($file in @(
                Get-ChildItem -LiteralPath $source -Recurse -Force -File)) {
                $relative = $file.FullName.Substring(
                    $RepositoryRoot.TrimEnd('\').Length + 1).Replace('\', '/')
                $entries.Add($relative)
            }
        } else {
            $entries.Add(([string]$releasePath).Replace('\', '/'))
        }
    }
    $entries.Sort([StringComparer]::Ordinal)
    return @($entries)
}

function Read-ReleaseZipEntryText {
    param([Parameter(Mandatory)]$Entry)

    $stream = $Entry.Open()
    $reader = New-Object IO.StreamReader(
        $stream,
        (New-Object Text.UTF8Encoding($false)),
        $true)
    try {
        return $reader.ReadToEnd()
    } finally {
        $reader.Dispose()
    }
}

function Assert-ReleaseArtifact {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$DistDirectory,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)]$ReleaseConfig,
        [Parameter(Mandatory)][string]$ExpectedCommit
    )

    if (-not (Test-Path -LiteralPath $DistDirectory -PathType Container)) {
        throw "Release output directory is missing: $DistDirectory"
    }
    $zipName = "DisableDefender-v$Version.zip"
    $hashName = "$zipName.sha256"
    $metadataName = "DisableDefender-v$Version.release.json"
    $expectedNames = @($zipName, $hashName, $metadataName)
    $artifactFiles = @(
        Get-ChildItem -LiteralPath $DistDirectory -File -ErrorAction Stop |
            Where-Object {
                $_.Name -match (
                    '^DisableDefender-v[0-9]+\.[0-9]+\.[0-9]+\.' +
                    '(zip|zip\.sha256|release\.json)$')
            })
    $unexpected = @(
        $artifactFiles | Where-Object { $expectedNames -notcontains $_.Name })
    if ($unexpected.Count -gt 0) {
        throw (
            'Stale or wrong-version release artifacts are present: ' +
            (($unexpected.Name | Sort-Object) -join ', '))
    }

    $zipPath = Join-Path $DistDirectory $zipName
    $hashPath = Join-Path $DistDirectory $hashName
    $metadataPath = Join-Path $DistDirectory $metadataName
    foreach ($requiredPath in @($zipPath, $hashPath, $metadataPath)) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "Required release artifact is missing: $requiredPath"
        }
    }

    $zipHash = Get-ReleaseFileSha256 -Path $zipPath
    $hashManifest = (
        Get-Content -Raw -LiteralPath $hashPath -ErrorAction Stop).Trim()
    $expectedHashLine = "$zipHash  $zipName"
    if ($hashManifest -cne $expectedHashLine) {
        throw 'Release hash manifest does not match the exact ZIP bytes.'
    }

    $metadata = Get-Content -Raw -LiteralPath $metadataPath |
        ConvertFrom-Json -ErrorAction Stop
    if ([int]$metadata.SchemaVersion -ne
        [int]$ReleaseConfig.ReleaseMetadataSchemaVersion) {
        throw "Release metadata has unsupported schema $($metadata.SchemaVersion)."
    }
    if ([string]$metadata.Version -cne $Version -or
        [string]$metadata.Sha256 -cne $zipHash) {
        throw 'Release metadata version or SHA256 does not match the ZIP.'
    }
    if ([string]$metadata.SourceCommit -cne $ExpectedCommit -or
        [string]$metadata.SourceTreeStatus -cne 'Clean') {
        throw 'Release metadata does not identify the clean expected commit.'
    }
    if ([string]$metadata.SignatureStatus -cne 'Unsigned' -or
        @($metadata.SignedFiles).Count -ne 0) {
        throw 'Release metadata does not describe an entirely unsigned build.'
    }
    $expectedZipPath = [IO.Path]::GetFullPath($zipPath)
    $expectedHashPath = [IO.Path]::GetFullPath($hashPath)
    if (-not $expectedZipPath.Equals(
            [IO.Path]::GetFullPath([string]$metadata.ZipPath),
            [StringComparison]::OrdinalIgnoreCase) -or
        -not $expectedHashPath.Equals(
            [IO.Path]::GetFullPath([string]$metadata.HashManifestPath),
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Release metadata artifact paths do not match the output.'
    }
    try {
        [void][DateTimeOffset]::Parse(
            [string]$metadata.BuiltAt,
            [Globalization.CultureInfo]::InvariantCulture)
        $metadataArchiveTimestamp = [DateTimeOffset]::Parse(
            [string]$metadata.ArchiveTimestampUtc,
            [Globalization.CultureInfo]::InvariantCulture)
        $configuredArchiveTimestamp = [DateTimeOffset]::Parse(
            [string]$ReleaseConfig.ArchiveTimestampUtc,
            [Globalization.CultureInfo]::InvariantCulture)
    } catch {
        throw "Release metadata timestamp is invalid: $($_.Exception.Message)"
    }
    if ($metadataArchiveTimestamp -ne $configuredArchiveTimestamp) {
        throw 'Release metadata archive timestamp does not match the gate.'
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $actualEntries = @(
            $archive.Entries |
                Where-Object { -not $_.FullName.EndsWith('/') } |
                ForEach-Object { $_.FullName } |
                Sort-Object)
        $expectedEntries = @(
            Get-ReleaseExpectedEntries -RepositoryRoot $RepositoryRoot `
                -ReleasePaths @($ReleaseConfig.ReleasePaths))
        $entryDifferences = @(
            Compare-Object -ReferenceObject $expectedEntries `
                -DifferenceObject $actualEntries -CaseSensitive)
        if ($entryDifferences.Count -gt 0) {
            throw (
                'Release archive inventory differs from configured source: ' +
                (($entryDifferences | ForEach-Object {
                    "$($_.SideIndicator)$($_.InputObject)"
                }) -join ', '))
        }

        $configuredTimestamp = [DateTimeOffset]::Parse(
            [string]$ReleaseConfig.ArchiveTimestampUtc,
            [Globalization.CultureInfo]::InvariantCulture)
        foreach ($entry in @(
            $archive.Entries |
                Where-Object { -not $_.FullName.EndsWith('/') })) {
            if ($entry.LastWriteTime -ne $configuredTimestamp) {
                throw "ZIP entry timestamp drifted: $($entry.FullName)"
            }
            $relativePath = $entry.FullName.Replace(
                [char]'/',
                [char][IO.Path]::DirectorySeparatorChar)
            $sourcePath = Join-Path $RepositoryRoot $relativePath
            $entryStream = $entry.Open()
            try {
                $entryHash = Get-ReleaseStreamSha256 -Stream $entryStream
            } finally {
                $entryStream.Dispose()
            }
            $sourceHash = Get-ReleaseFileSha256 -Path $sourcePath
            if ($entryHash -cne $sourceHash) {
                throw "ZIP entry content is stale or altered: $($entry.FullName)"
            }
        }

        $entryMap = @{}
        foreach ($entry in $archive.Entries) {
            $entryMap[$entry.FullName] = $entry
        }
        $archiveVersions = [ordered]@{
            Manifest = [regex]::Match(
                (Read-ReleaseZipEntryText -Entry $entryMap['DisableDefender.psd1']),
                "(?m)^\s*ModuleVersion\s*=\s*'(?<Version>[0-9.]+)'"
            ).Groups['Version'].Value
            'CLI header' = [regex]::Match(
                (Read-ReleaseZipEntryText -Entry $entryMap['DisableDefender.ps1']),
                'DisableDefender v(?<Version>[0-9.]+)'
            ).Groups['Version'].Value
            'GUI header' = [regex]::Match(
                (Read-ReleaseZipEntryText -Entry $entryMap['DisableDefender.GUI.ps1']),
                'DisableDefender GUI v(?<Version>[0-9.]+)'
            ).Groups['Version'].Value
            'README badge' = [regex]::Match(
                (Read-ReleaseZipEntryText -Entry $entryMap['README.md']),
                'version-(?<Version>[0-9.]+)-blue'
            ).Groups['Version'].Value
            CHANGELOG = [regex]::Match(
                (Read-ReleaseZipEntryText -Entry $entryMap['CHANGELOG.md']),
                '(?m)^## v(?<Version>[0-9.]+) -'
            ).Groups['Version'].Value
        }
        foreach ($versionEntry in $archiveVersions.GetEnumerator()) {
            if ([string]$versionEntry.Value -cne $Version) {
                throw (
                    "Archive $($versionEntry.Key) version is " +
                    "'$($versionEntry.Value)', expected '$Version'.")
            }
        }
        foreach ($entry in @(
            $archive.Entries |
                Where-Object { $_.FullName -match '\.ps(m|d)?1$' })) {
            if ((Read-ReleaseZipEntryText -Entry $entry) -match
                '(?m)^# SIG # Begin signature block$') {
                throw "Signed script found in unsigned archive: $($entry.FullName)"
            }
        }
    } finally {
        $archive.Dispose()
    }

    return [PSCustomObject]@{
        ZipPath   = $zipPath
        ZipHash   = $zipHash
        FileCount = $actualEntries.Count
        Size      = (Get-Item -LiteralPath $zipPath).Length
    }
}

function Get-GitCommand {
    $gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($null -eq $gitCommand) {
        $gitCommand = Get-Command git -ErrorAction SilentlyContinue
    }
    return $gitCommand
}

$releaseConfigPath = Join-Path $PSScriptRoot 'ReleaseGate.psd1'
try {
    if (-not (Test-Path -LiteralPath $releaseConfigPath -PathType Leaf)) {
        throw "Release gate configuration is missing: $releaseConfigPath"
    }
    $releaseConfig = Import-PowerShellDataFile -LiteralPath $releaseConfigPath
    if ([int]$releaseConfig.SchemaVersion -ne 1) {
        throw "Unsupported release gate schema $($releaseConfig.SchemaVersion)."
    }
    if ([version]$releaseConfig.PesterVersion -lt [version]'5.0' -or
        [version]$releaseConfig.PesterVersion -ge [version]'6.0') {
        throw 'The supported Pester line must remain pinned to major version 5.'
    }
    if ([version]$releaseConfig.PSScriptAnalyzerVersion -lt [version]'1.0') {
        throw 'PSScriptAnalyzer must be pinned to a positive version.'
    }
    if ([double]$releaseConfig.MinimumCommandCoveragePercent -le 0 -or
        [double]$releaseConfig.MinimumCommandCoveragePercent -gt 100) {
        throw 'The command-coverage ratchet must be between 0 and 100.'
    }
    if ([int]$releaseConfig.MinimumPassedTests -lt 1) {
        throw 'The passed-test ratchet must be positive.'
    }
    Write-Check 'Release gate schema' 'Pass' (
        "v$($releaseConfig.SchemaVersion); Pester " +
        "$($releaseConfig.PesterVersion); coverage " +
        "$($releaseConfig.MinimumCommandCoveragePercent)%")
} catch {
    Write-Check 'Release gate schema' 'Fail' $_.Exception.Message
    Write-Host ''
    Write-Host 'Release gate configuration is unusable.' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host ('=' * 72) -ForegroundColor DarkCyan
Write-Host ' DisableDefender Strict Release Gate' -ForegroundColor Cyan
Write-Host ('=' * 72) -ForegroundColor DarkCyan
Write-Host ''

$manifest = $null
$module = $null
$releaseVersion = $null
$expectedCommit = $null

try {
    $manifestPath = Join-Path $repoRoot 'DisableDefender.psd1'
    $manifest = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop
    $releaseVersion = [string]$manifest.Version
    Write-Check 'Module manifest' 'Pass' "v$releaseVersion"
} catch {
    Write-Check 'Module manifest' 'Fail' $_.Exception.Message
}

if ($null -ne $manifest) {
    try {
        Import-Module -Name $manifestPath -Force -ErrorAction Stop
        $module = Get-Module -Name DisableDefender
        Write-Check 'Module import' 'Pass' (
            "$($module.ExportedFunctions.Count) exported functions")
    } catch {
        Write-Check 'Module import' 'Fail' $_.Exception.Message
    }
}

if ($null -ne $manifest) {
    try {
        $versions = Get-ReleaseVersionMap `
            -RepositoryRoot $repoRoot -Manifest $manifest
        $uniqueVersions = @($versions.Values | Sort-Object -Unique)
        if ($versions.Count -ne 8 -or $uniqueVersions.Count -ne 1 -or
            [string]$uniqueVersions[0] -cne $releaseVersion) {
            $detail = ($versions.GetEnumerator() | ForEach-Object {
                "$($_.Key)=$($_.Value)"
            }) -join ', '
            throw "Version mismatch: $detail"
        }
        Write-Check 'Source version consistency' 'Pass' (
            "$releaseVersion across $($versions.Count) locations")
    } catch {
        Write-Check 'Source version consistency' 'Fail' $_.Exception.Message
    }

    try {
        $editions = @($manifest.CompatiblePSEditions | ForEach-Object { [string]$_ })
        $expectedEditions = @('Desktop', 'Core')
        if (@(Compare-Object $expectedEditions $editions).Count -gt 0) {
            throw "CompatiblePSEditions must be Desktop and Core; found $($editions -join ', ')."
        }
        Write-Check 'PowerShell edition compatibility' 'Pass' ($editions -join ', ')
    } catch {
        Write-Check 'PowerShell edition compatibility' 'Fail' $_.Exception.Message
    }
}

if ($null -ne $module) {
    try {
        $fixturePath = Join-Path $repoRoot 'Tests\Fixtures\artifact-schemas.json'
        $fixtures = Get-Content -Raw -LiteralPath $fixturePath |
            ConvertFrom-Json -ErrorAction Stop
        if ([int]$fixtures.FixtureVersion -ne 1) {
            throw "Unsupported artifact fixture schema $($fixtures.FixtureVersion)."
        }
        $catalog = @(& $module { Get-DefenderArtifactSchemaCatalog })
        $fixtureNames = @($fixtures.Current.Name | Sort-Object)
        $catalogNames = @($catalog.Name | Sort-Object)
        if (@(Compare-Object $fixtureNames $catalogNames).Count -gt 0) {
            throw 'Current artifact fixtures do not match the schema catalog.'
        }
        foreach ($fixture in @($fixtures.Current)) {
            $schema = $catalog | Where-Object { $_.Name -eq $fixture.Name }
            if ([int]$fixture.SchemaVersion -ne [int]$schema.CurrentVersion) {
                throw "Current fixture version drifted for $($fixture.Name)."
            }
        }
        foreach ($fixture in @($fixtures.Legacy)) {
            $schema = $catalog | Where-Object { $_.Name -eq $fixture.Name }
            if (@($schema.LegacyFormats) -notcontains [string]$fixture.Format) {
                throw "Legacy fixture is not registered for $($fixture.Name)."
            }
        }
        foreach ($fixture in @($fixtures.Future)) {
            $schema = $catalog | Where-Object { $_.Name -eq $fixture.Name }
            if ([int]$fixture.SchemaVersion -le [int]$schema.CurrentVersion) {
                throw "Future fixture is not future for $($fixture.Name)."
            }
        }
        $releaseMetadataSchema = $catalog |
            Where-Object { $_.Name -eq 'ReleaseMetadata' }
        if ([int]$releaseConfig.ReleaseMetadataSchemaVersion -ne
            [int]$releaseMetadataSchema.CurrentVersion) {
            throw 'Release metadata schema drifted from the module catalog.'
        }
        Write-Check 'Artifact schema fixtures' 'Pass' (
            "$($catalog.Count) current; $(@($fixtures.Legacy).Count) legacy; " +
            "$(@($fixtures.Future).Count) future")
    } catch {
        Write-Check 'Artifact schema fixtures' 'Fail' $_.Exception.Message
    }
}

$pesterModule = Get-Module -Name Pester -ListAvailable |
    Where-Object {
        $_.Version -eq [version]$releaseConfig.PesterVersion
    } |
    Select-Object -First 1
if ($null -eq $pesterModule) {
    Write-Check 'Pester dependency' 'Fail' (
        "Required exact version $($releaseConfig.PesterVersion) is not installed.")
} else {
    Write-Check 'Pester dependency' 'Pass' (
        "$($pesterModule.Version) at $($pesterModule.ModuleBase)")
    $coverageOutput = Join-Path ([IO.Path]::GetTempPath()) (
        'DisableDefender-coverage-{0:N}.xml' -f [guid]::NewGuid())
    try {
        Import-Module -Name $pesterModule.Path -Force -ErrorAction Stop
        $pesterConfig = New-PesterConfiguration
        $pesterConfig.Run.Path = Join-Path $repoRoot 'Tests'
        $pesterConfig.Run.PassThru = $true
        $pesterConfig.Output.Verbosity = 'None'
        if (-not $SkipCoverage) {
            $pesterConfig.CodeCoverage.Enabled = $true
            $pesterConfig.CodeCoverage.Path = @(
                (Join-Path $repoRoot 'Public\*.ps1'),
                (Join-Path $repoRoot 'Private\*.ps1')
            )
            $pesterConfig.CodeCoverage.OutputFormat = 'JaCoCo'
            $pesterConfig.CodeCoverage.OutputPath = $coverageOutput
        }

        $results = Invoke-Pester -Configuration $pesterConfig
        if ($results.FailedCount -gt 0 -or
            $results.PassedCount -lt [int]$releaseConfig.MinimumPassedTests) {
            throw (
                "$($results.PassedCount) passed, $($results.FailedCount) failed; " +
                "minimum passed is $($releaseConfig.MinimumPassedTests).")
        }
        Write-Check 'Pester tests' 'Pass' (
            "$($results.PassedCount) passed, 0 failed")

        if ($SkipCoverage) {
            Write-Check 'Code coverage' 'Info' (
                'Skipped explicitly; this run is not full release qualification.')
        } elseif ($null -eq $results.CodeCoverage -or
            $results.CodeCoverage.CommandsAnalyzedCount -lt 1) {
            Write-Check 'Code coverage' 'Fail' 'No command coverage was produced.'
        } else {
            $coverage = $results.CodeCoverage
            $coveragePercent = [math]::Round(
                ($coverage.CommandsExecutedCount /
                    $coverage.CommandsAnalyzedCount) * 100,
                1)
            if ($coveragePercent -lt
                [double]$releaseConfig.MinimumCommandCoveragePercent) {
                Write-Check 'Code coverage' 'Fail' (
                    "${coveragePercent}% is below the " +
                    "$($releaseConfig.MinimumCommandCoveragePercent)% ratchet.")
            } else {
                Write-Check 'Code coverage' 'Pass' (
                    "${coveragePercent}% " +
                    "($($coverage.CommandsExecutedCount)/" +
                    "$($coverage.CommandsAnalyzedCount) commands)")
            }
        }
    } catch {
        Write-Check 'Pester tests' 'Fail' $_.Exception.Message
    } finally {
        [IO.File]::Delete($coverageOutput)
    }
}

if ($SkipAnalyzer) {
    Write-Check 'ScriptAnalyzer' 'Info' (
        'Skipped explicitly; this run is not full release qualification.')
} else {
    $analyzerModule = Get-Module -Name PSScriptAnalyzer -ListAvailable |
        Where-Object {
            $_.Version -eq [version]$releaseConfig.PSScriptAnalyzerVersion
        } |
        Select-Object -First 1
    if ($null -eq $analyzerModule) {
        Write-Check 'ScriptAnalyzer dependency' 'Fail' (
            "Required exact version " +
            "$($releaseConfig.PSScriptAnalyzerVersion) is not installed.")
    } else {
        Write-Check 'ScriptAnalyzer dependency' 'Pass' (
            "$($analyzerModule.Version) at $($analyzerModule.ModuleBase)")
        try {
            Import-Module -Name $analyzerModule.Path -Force -ErrorAction Stop
            $settingsPath = Join-Path $repoRoot 'PSScriptAnalyzerSettings.psd1'
            $findings = @(
                Invoke-ScriptAnalyzer -Path $repoRoot -Recurse `
                    -Settings $settingsPath -ErrorAction Stop)
            if ($findings.Count -gt 0) {
                throw (
                    "$($findings.Count) finding(s): " +
                    (($findings | Select-Object -First 5 | ForEach-Object {
                        "$($_.ScriptName):$($_.Line):$($_.RuleName)"
                    }) -join ', '))
            }
            Write-Check 'ScriptAnalyzer' 'Pass' 'No findings'
        } catch {
            Write-Check 'ScriptAnalyzer' 'Fail' $_.Exception.Message
        }
    }
}

try {
    $parseErrors = @()
    foreach ($file in @(
        Get-ChildItem -LiteralPath $repoRoot -Recurse -File |
            Where-Object {
                $_.Extension -in @('.ps1', '.psm1', '.psd1') -and
                $_.FullName -notmatch '[\\/](dist)[\\/]'
            })) {
        $fileErrors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $file.FullName,
            [ref]$null,
            [ref]$fileErrors)
        foreach ($parseError in @($fileErrors)) {
            $parseErrors += (
                "$($file.Name):$($parseError.Extent.StartLineNumber):" +
                "$($parseError.Message)")
        }
    }
    if ($parseErrors.Count -gt 0) {
        throw ($parseErrors -join '; ')
    }
    Write-Check 'PowerShell parse' 'Pass' 'All source scripts parsed'
} catch {
    Write-Check 'PowerShell parse' 'Fail' $_.Exception.Message
}

$gitCommand = Get-GitCommand
if ($null -eq $gitCommand) {
    Write-Check 'Git source identity' 'Fail' 'git is not installed.'
} else {
    try {
        $commitOutput = @(
            & $gitCommand.Source -C $repoRoot rev-parse --verify HEAD 2>$null)
        if ($LASTEXITCODE -ne 0 -or $commitOutput.Count -ne 1 -or
            [string]$commitOutput[0] -notmatch '^[0-9a-fA-F]{40}$') {
            throw 'HEAD is not a resolvable Git commit.'
        }
        $expectedCommit = ([string]$commitOutput[0]).ToLowerInvariant()
        $statusArguments = @(
            '-C', $repoRoot, 'status', '--porcelain=v1',
            '--untracked-files=all', '--'
        ) + @($releaseConfig.ReleasePaths)
        $releaseStatus = @(
            & $gitCommand.Source @statusArguments 2>$null)
        if ($LASTEXITCODE -ne 0) {
            throw 'Could not inspect release-source cleanliness.'
        }
        if ($releaseStatus.Count -gt 0) {
            throw (
                'Release inputs differ from HEAD: ' +
                (($releaseStatus | ForEach-Object { ([string]$_).Trim() }) -join ', '))
        }
        Write-Check 'Git source identity' 'Pass' (
            "$($expectedCommit.Substring(0, 12)); release inputs clean")
    } catch {
        Write-Check 'Git source identity' 'Fail' $_.Exception.Message
    }
}

$artifact = $null
if ($null -ne $releaseVersion -and $null -ne $expectedCommit) {
    try {
        $artifact = Assert-ReleaseArtifact `
            -RepositoryRoot $repoRoot `
            -DistDirectory (Join-Path $repoRoot 'dist') `
            -Version $releaseVersion `
            -ReleaseConfig $releaseConfig `
            -ExpectedCommit $expectedCommit
        Write-Check 'Release artifact' 'Pass' (
            "$([IO.Path]::GetFileName($artifact.ZipPath)); " +
            "$($artifact.FileCount) files; SHA256 $($artifact.ZipHash)")
    } catch {
        Write-Check 'Release artifact' 'Fail' $_.Exception.Message
    }
}

if ($SkipCleanBuild) {
    Write-Check 'Detached-checkout reproduction' 'Info' (
        'Skipped explicitly; this run is not full release qualification.')
} elseif ($null -eq $gitCommand -or $null -eq $expectedCommit -or
    $null -eq $artifact) {
    Write-Check 'Detached-checkout reproduction' 'Fail' (
        'Source identity and the primary artifact must pass first.')
} else {
    $cleanPath = Join-Path ([IO.Path]::GetTempPath()) (
        'DisableDefender-release-check-{0:N}' -f [guid]::NewGuid())
    $worktreeAdded = $false
    $cleanBuildError = $null
    try {
        & $gitCommand.Source -C $repoRoot worktree add --detach `
            $cleanPath $expectedCommit | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'Could not create the detached release checkout.'
        }
        $worktreeAdded = $true
        $cleanBuilder = Join-Path $cleanPath `
            'tools\New-DisableDefenderRelease.ps1'
        $cleanDist = Join-Path $cleanPath 'dist'
        $cleanMetadata = & $cleanBuilder `
            -Version $releaseVersion `
            -OutputDirectory $cleanDist `
            -SkipSigning
        if ([string]$cleanMetadata.SourceTreeStatus -cne 'Clean' -or
            [string]$cleanMetadata.SourceCommit -cne $expectedCommit) {
            throw 'Detached builder did not report a clean expected commit.'
        }
        $cleanArtifact = Assert-ReleaseArtifact `
            -RepositoryRoot $cleanPath `
            -DistDirectory $cleanDist `
            -Version $releaseVersion `
            -ReleaseConfig $releaseConfig `
            -ExpectedCommit $expectedCommit
        if ([string]$cleanArtifact.ZipHash -cne
            [string]$artifact.ZipHash) {
            throw (
                'Detached checkout produced a different ZIP hash: ' +
                "$($cleanArtifact.ZipHash) vs $($artifact.ZipHash)")
        }
    } catch {
        $cleanBuildError = $_.Exception.Message
    } finally {
        if ($worktreeAdded) {
            & $gitCommand.Source -C $repoRoot worktree remove --force `
                $cleanPath 2>$null
            if ($LASTEXITCODE -ne 0 -and
                [string]::IsNullOrWhiteSpace($cleanBuildError)) {
                $cleanBuildError =
                    "Could not remove detached worktree: $cleanPath"
            }
            & $gitCommand.Source -C $repoRoot worktree prune 2>$null
        }
    }
    if ([string]::IsNullOrWhiteSpace($cleanBuildError)) {
        Write-Check 'Detached-checkout reproduction' 'Pass' (
            "exact SHA256 $($artifact.ZipHash)")
    } else {
        Write-Check 'Detached-checkout reproduction' 'Fail' $cleanBuildError
    }
}

Write-Host ''
Write-Host ('=' * 72) -ForegroundColor DarkCyan
$summaryColor = if ($failed -gt 0) {
    'Red'
} elseif ($warnings -gt 0) {
    'Yellow'
} else {
    'Green'
}
Write-Host (
    " Results: $passed passed, $failed failed, $warnings warnings"
) -ForegroundColor $summaryColor
Write-Host ('=' * 72) -ForegroundColor DarkCyan
Write-Host ''

if ($failed -gt 0) { exit 1 }
exit 0
