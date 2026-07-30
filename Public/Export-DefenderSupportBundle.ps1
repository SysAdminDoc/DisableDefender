function Export-DefenderSupportBundle {
    <#
    .SYNOPSIS
        Exports diagnostic artifacts into a single zip for support and diagnosis.
    .DESCRIPTION
        Collects logs, phase-state, tripwire entries, component status, health
        summary, Windows build info, and optional redacted Defender event-log
        excerpts into a timestamped zip. No secrets (registry ACL backups,
        restore manifests with registry values) are included by default.
    .PARAMETER OutputDirectory
        Directory where the zip is written. Defaults to the current directory.
    .PARAMETER IncludeEventLog
        Include the last 100 Microsoft-Windows-Windows Defender/Operational
        event-log entries (redacted to exclude file paths from scan events).
    .EXAMPLE
        Export-DefenderSupportBundle
    .EXAMPLE
        Export-DefenderSupportBundle -OutputDirectory C:\Support -IncludeEventLog
    #>
    [CmdletBinding()]
    param(
        [string]$OutputDirectory = '.',
        [switch]$IncludeEventLog
    )

    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }
    $resolvedOutput = (Resolve-Path -LiteralPath $OutputDirectory).Path

    $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss')
    $bundleDir = Join-Path $env:TEMP "DisableDefender-support-$stamp"
    New-Item -ItemType Directory -Path $bundleDir -Force | Out-Null

    try {
        $summary = [ordered]@{
            SchemaVersion = Get-DefenderArtifactSchemaVersion -Name SupportBundleSummary
            GeneratedAt = (Get-Date).ToString('o')
            Version     = $script:Version
        }

        try {
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            $summary.WindowsBuild = [ordered]@{
                Caption      = $os.Caption
                Version      = $os.Version
                BuildNumber  = $os.BuildNumber
            }
            try {
                $displayVer = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'DisplayVersion' -ErrorAction Stop).DisplayVersion
                $summary.WindowsBuild.DisplayVersion = $displayVer
            } catch {}
        } catch {
            $summary.WindowsBuild = 'unavailable'
        }

        $summary.LanguageMode = [string]$ExecutionContext.SessionState.LanguageMode
        $summary.IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        $summary.SafeMode = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).BootupState -like '*Fail-safe*'

        try {
            $health = Get-DefenderHealth -Target Disable
            $summary.Health = [ordered]@{
                Target  = $health.Target
                Summary = $health.Summary
            }
            $healthDocument = [ordered]@{
                SchemaVersion = Get-DefenderArtifactSchemaVersion -Name SupportBundleHealth
                GeneratedAt   = (Get-Date).ToString('o')
                Data          = $health
            }
            Write-DefenderJsonArtifactAtomic -Name SupportBundleHealth `
                -Path (Join-Path $bundleDir 'health.json') `
                -InputObject $healthDocument -Depth 10 | Out-Null
        } catch {
            $summary.Health = "Error: $($_.Exception.Message)"
            Write-Log "Support bundle: health collection failed: $($_.Exception.Message)" WARN
        }

        try {
            $components = @(Get-DefenderComponentStatus)
            $summary.ComponentCount = $components.Count
            $componentDocument = [ordered]@{
                SchemaVersion = Get-DefenderArtifactSchemaVersion -Name SupportBundleComponents
                GeneratedAt   = (Get-Date).ToString('o')
                Data          = @($components)
            }
            Write-DefenderJsonArtifactAtomic -Name SupportBundleComponents `
                -Path (Join-Path $bundleDir 'components.json') `
                -InputObject $componentDocument -Depth 6 | Out-Null
        } catch {
            $summary.ComponentCount = 0
            Write-Log "Support bundle: component collection failed: $($_.Exception.Message)" WARN
        }

        $runtimeDir = $script:AppDir
        if (Test-Path -LiteralPath $runtimeDir) {
            $logFile = Join-Path $runtimeDir "$script:AppName.log"
            if (Test-Path -LiteralPath $logFile) {
                Copy-Item -LiteralPath $logFile -Destination (Join-Path $bundleDir 'DisableDefender.log') -Force
            }

            $jsonlLog = Join-Path $runtimeDir "$script:AppName.jsonl"
            if (Test-Path -LiteralPath $jsonlLog) {
                Copy-Item -LiteralPath $jsonlLog -Destination (Join-Path $bundleDir 'DisableDefender.jsonl') -Force
            }

            $transcriptFile = Join-Path $runtimeDir 'transcript.log'
            if (Test-Path -LiteralPath $transcriptFile) {
                Copy-Item -LiteralPath $transcriptFile -Destination (Join-Path $bundleDir 'transcript.log') -Force
            }

            $phaseState = Join-Path $runtimeDir 'phase-state.json'
            if (Test-Path -LiteralPath $phaseState) {
                Copy-Item -LiteralPath $phaseState -Destination (Join-Path $bundleDir 'phase-state.json') -Force
            }

            $tripwire = Join-Path $runtimeDir 'tripwire.jsonl'
            if (Test-Path -LiteralPath $tripwire) {
                Copy-Item -LiteralPath $tripwire -Destination (Join-Path $bundleDir 'tripwire.jsonl') -Force
            }

            $surfaceBaseline = Join-Path $runtimeDir 'surface-baseline.json'
            if (Test-Path -LiteralPath $surfaceBaseline) {
                Copy-Item -LiteralPath $surfaceBaseline -Destination (Join-Path $bundleDir 'surface-baseline.json') -Force
            }
        }

        if ($IncludeEventLog) {
            try {
                $events = Get-WinEvent -LogName 'Microsoft-Windows-Windows Defender/Operational' -MaxEvents 100 -ErrorAction Stop
                $redacted = @($events | ForEach-Object {
                    [ordered]@{
                        TimeCreated = $_.TimeCreated.ToString('o')
                        Id          = $_.Id
                        Level       = $_.LevelDisplayName
                        Message     = ($_.Message -replace '(?i)(file|path|name):\s*[A-Za-z]:\\[^\r\n]+', '$1: [REDACTED]')
                    }
                })
                $eventDocument = [ordered]@{
                    SchemaVersion = Get-DefenderArtifactSchemaVersion -Name SupportBundleEvents
                    GeneratedAt   = (Get-Date).ToString('o')
                    Data          = @($redacted)
                }
                Write-DefenderJsonArtifactAtomic -Name SupportBundleEvents `
                    -Path (Join-Path $bundleDir 'defender-events.json') `
                    -InputObject $eventDocument -Depth 6 | Out-Null
                $summary.EventLogEntries = $redacted.Count
            } catch {
                $summary.EventLogEntries = "Error: $($_.Exception.Message)"
            }
        }

        Write-DefenderJsonArtifactAtomic -Name SupportBundleSummary `
            -Path (Join-Path $bundleDir 'summary.json') `
            -InputObject $summary -Depth 8 | Out-Null

        $zipName = "DisableDefender-support-$stamp.zip"
        $zipPath = Join-Path $resolvedOutput $zipName
        if (Test-Path -LiteralPath $zipPath) {
            Remove-Item -LiteralPath $zipPath -Force
        }

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::CreateFromDirectory($bundleDir, $zipPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)

        Write-Log "Support bundle exported: $zipPath" OK

        return [PSCustomObject]@{
            ZipPath   = $zipPath
            Generated = $stamp
            Version   = $script:Version
        }
    } finally {
        Remove-Item -LiteralPath $bundleDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
