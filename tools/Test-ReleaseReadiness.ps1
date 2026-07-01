#Requires -Version 5.1
<#
    Local release-readiness checker for DisableDefender.
    Runs manifest validation, Pester with code coverage, ScriptAnalyzer,
    GUI/XAML parse check, version consistency, and artifact inspection.
    No GitHub Actions required.
#>
[CmdletBinding()]
param(
    [switch]$SkipAnalyzer,
    [switch]$SkipCoverage
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$passed = 0
$failed = 0
$warnings = 0

function Write-Check {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Pass','Fail','Warn','Info')][string]$Result,
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

Write-Host ''
Write-Host ('=' * 72) -ForegroundColor DarkCyan
Write-Host ' DisableDefender Release Readiness Check' -ForegroundColor Cyan
Write-Host ('=' * 72) -ForegroundColor DarkCyan
Write-Host ''

# --- 1. Module manifest ---
$manifestPath = Join-Path $repoRoot 'DisableDefender.psd1'
try {
    $manifest = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop
    Write-Check 'Module manifest' 'Pass' "v$($manifest.Version)"
} catch {
    Write-Check 'Module manifest' 'Fail' $_.Exception.Message
}

# --- 2. Module import ---
try {
    Import-Module -Name $manifestPath -Force -ErrorAction Stop
    $mod = Get-Module -Name DisableDefender
    Write-Check 'Module import' 'Pass' "$($mod.ExportedFunctions.Count) exported functions"
} catch {
    Write-Check 'Module import' 'Fail' $_.Exception.Message
}

# --- 3. Version consistency ---
$versions = [ordered]@{}
$versions['Manifest'] = [string]$manifest.Version
try {
    $variablesPath = Join-Path $repoRoot 'Private\Variables.ps1'
    $variablesContent = Get-Content -LiteralPath $variablesPath -Raw
    if ($variablesContent -match "\`$script:Version\s*=\s*'([^']+)'") {
        $versions['Variables.ps1'] = $Matches[1]
    }
} catch {}
try {
    $cliContent = Get-Content -LiteralPath (Join-Path $repoRoot 'DisableDefender.ps1') -Raw
    if ($cliContent -match 'DisableDefender v([0-9.]+)') {
        $versions['CLI header'] = $Matches[1]
    }
} catch {}
try {
    $readmeContent = Get-Content -LiteralPath (Join-Path $repoRoot 'README.md') -Raw
    if ($readmeContent -match 'version-([0-9.]+)-blue') {
        $versions['README badge'] = $Matches[1]
    }
} catch {}
try {
    $changelogContent = Get-Content -LiteralPath (Join-Path $repoRoot 'CHANGELOG.md') -TotalCount 5 | Out-String
    if ($changelogContent -match '## v([0-9.]+)') {
        $versions['CHANGELOG'] = $Matches[1]
    }
} catch {}

$uniqueVersions = @($versions.Values | Sort-Object -Unique)
if ($uniqueVersions.Count -eq 1) {
    Write-Check 'Version consistency' 'Pass' "$($uniqueVersions[0]) across $($versions.Count) locations"
} else {
    $detail = ($versions.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '
    Write-Check 'Version consistency' 'Fail' "Mismatch: $detail"
}

# --- 4. Pester tests ---
try {
    $pesterModule = Get-Module -Name Pester -ListAvailable | Where-Object { $_.Version -ge [version]'5.0' } | Select-Object -First 1
    if (-not $pesterModule) {
        Write-Check 'Pester tests' 'Warn' 'Pester 5+ not installed; skipping tests.'
    } else {
        Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop
        $config = New-PesterConfiguration
        $config.Run.Path = Join-Path $repoRoot 'Tests'
        $config.Run.PassThru = $true
        $config.Output.Verbosity = 'None'

        if (-not $SkipCoverage) {
            $config.CodeCoverage.Enabled = $true
            $coveragePaths = @(
                (Join-Path $repoRoot 'Public\*.ps1'),
                (Join-Path $repoRoot 'Private\*.ps1')
            )
            $config.CodeCoverage.Path = $coveragePaths
            $config.CodeCoverage.OutputFormat = 'JaCoCo'
            $config.CodeCoverage.OutputPath = Join-Path $env:TEMP 'DisableDefender-coverage.xml'
        }

        $results = Invoke-Pester -Configuration $config

        if ($results.FailedCount -eq 0) {
            Write-Check 'Pester tests' 'Pass' "$($results.PassedCount) passed, $($results.FailedCount) failed"
        } else {
            Write-Check 'Pester tests' 'Fail' "$($results.PassedCount) passed, $($results.FailedCount) failed"
        }

        if (-not $SkipCoverage -and $results.CodeCoverage) {
            $cc = $results.CodeCoverage
            $pct = if ($cc.CommandsAnalyzedCount -gt 0) {
                [math]::Round(($cc.CommandsExecutedCount / $cc.CommandsAnalyzedCount) * 100, 1)
            } else { 0 }
            Write-Check 'Code coverage' 'Info' "${pct}% ($($cc.CommandsExecutedCount)/$($cc.CommandsAnalyzedCount) commands)"

            if ($cc.FilesNotCoveredCount -gt 0) {
                Write-Check 'Untested files' 'Warn' "$($cc.FilesNotCoveredCount) file(s) with zero coverage"
            }
        }
    }
} catch {
    Write-Check 'Pester tests' 'Fail' $_.Exception.Message
}

# --- 5. ScriptAnalyzer ---
if ($SkipAnalyzer) {
    Write-Check 'ScriptAnalyzer' 'Info' 'Skipped (-SkipAnalyzer)'
} else {
    try {
        $saModule = Get-Module -Name PSScriptAnalyzer -ListAvailable | Select-Object -First 1
        if (-not $saModule) {
            Write-Check 'ScriptAnalyzer' 'Warn' 'PSScriptAnalyzer not installed; skipping.'
        } else {
            Import-Module PSScriptAnalyzer -ErrorAction Stop
            $settingsPath = Join-Path $repoRoot 'PSScriptAnalyzerSettings.psd1'
            $settings = if (Test-Path -LiteralPath $settingsPath) { $settingsPath } else { $null }
            $findings = @(Invoke-ScriptAnalyzer -Path $repoRoot -Recurse -Settings $settings -ErrorAction Stop)
            $errors = @($findings | Where-Object { $_.Severity -eq 'Error' })
            $warns  = @($findings | Where-Object { $_.Severity -eq 'Warning' })
            if ($errors.Count -gt 0) {
                Write-Check 'ScriptAnalyzer' 'Fail' "$($errors.Count) error(s), $($warns.Count) warning(s)"
            } elseif ($warns.Count -gt 0) {
                Write-Check 'ScriptAnalyzer' 'Warn' "$($warns.Count) warning(s)"
            } else {
                Write-Check 'ScriptAnalyzer' 'Pass' "No issues found"
            }
        }
    } catch {
        Write-Check 'ScriptAnalyzer' 'Fail' $_.Exception.Message
    }
}

# --- 6. GUI XAML parse check ---
$guiPath = Join-Path $repoRoot 'DisableDefender.GUI.ps1'
if (Test-Path -LiteralPath $guiPath) {
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($guiPath, [ref]$null, [ref]$parseErrors)
    if ($parseErrors.Count -eq 0) {
        Write-Check 'GUI script parse' 'Pass' 'No syntax errors'
    } else {
        Write-Check 'GUI script parse' 'Fail' "$($parseErrors.Count) parse error(s)"
    }
} else {
    Write-Check 'GUI script parse' 'Warn' 'GUI script not found'
}

# --- 7. Artifact inspection ---
$distDir = Join-Path $repoRoot 'dist'
$zips = @()
if (Test-Path -LiteralPath $distDir) {
    $zips = @(Get-ChildItem -LiteralPath $distDir -Filter '*.zip' -File -ErrorAction SilentlyContinue)
}
if ($zips.Count -gt 0) {
    $latest = $zips | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    Write-Check 'Release artifact' 'Pass' "$($latest.Name) ($([math]::Round($latest.Length / 1KB, 1)) KB)"
} else {
    Write-Check 'Release artifact' 'Info' 'No dist/*.zip found. Run tools/New-DisableDefenderRelease.ps1 to build.'
}

# --- Summary ---
Write-Host ''
Write-Host ('=' * 72) -ForegroundColor DarkCyan
$summaryColor = if ($failed -gt 0) { 'Red' } elseif ($warnings -gt 0) { 'Yellow' } else { 'Green' }
Write-Host " Results: $passed passed, $failed failed, $warnings warnings" -ForegroundColor $summaryColor
Write-Host ('=' * 72) -ForegroundColor DarkCyan
Write-Host ''

if ($failed -gt 0) { exit 1 }
exit 0
