# ---------------------------------------------------------------------------
# Optional ETW capture for Defender reactions during a mutation run.
# Uses inbox logman/tracerpt so no tracing dependency is added to the module.
# ---------------------------------------------------------------------------

$script:DefenderEtwProviderName = 'Microsoft-Windows-Windows Defender'
$script:DefenderEtwProviderGuid = '11CD958A-C507-4EF3-B3F2-5FD9DFBD2C78'
$script:DefenderEtwCapture = $null
$script:EtwCaptureEnabled = $false

function Invoke-DefenderEtwCommand {
    param(
        [Parameter(Mandatory)][ValidateSet('logman.exe','tracerpt.exe')][string]$Executable,
        [Parameter(Mandatory)][string[]]$ArgumentList
    )

    $command = Get-Command -Name $Executable -CommandType Application `
        -ErrorAction Stop
    $output = & $command.Source @ArgumentList 2>&1
    return [PSCustomObject][ordered]@{
        ExitCode = [int]$LASTEXITCODE
        Output   = @($output | ForEach-Object { [string]$_ })
    }
}

function Start-DefenderEtwCapture {
    param([ValidateSet('Disable','Remove','Restore')][string]$Mode = 'Disable')

    if (-not $script:EtwCaptureEnabled) { return $null }
    if ($null -ne $script:DefenderEtwCapture) {
        return [PSCustomObject]$script:DefenderEtwCapture
    }
    if ($WhatIfPreference) {
        Write-Log 'ETW capture skipped during WhatIf simulation.' DEBUG
        return $null
    }

    $captureId = [guid]::NewGuid().ToString('N')
    $sessionName = "DisableDefenderEtw-$($captureId.Substring(0, 12))"
    $tracePath = Join-Path $script:AppDir "defender-etw.$captureId.etl"
    $summaryPath = Join-Path $script:AppDir "defender-etw.$captureId.csv"
    $metadataPath = Join-Path $script:AppDir "defender-etw.$captureId.json"
    $script:DefenderEtwCapture = [ordered]@{
        SchemaVersion = Get-DefenderArtifactSchemaVersion -Name DefenderEtwCapture
        Format        = 'DisableDefender.EtwCapture'
        RunId         = $captureId
        Mode          = $Mode
        Provider      = $script:DefenderEtwProviderName
        ProviderGuid  = $script:DefenderEtwProviderGuid
        SessionName   = $sessionName
        TracePath     = $tracePath
        SummaryPath   = $summaryPath
        MetadataPath  = $metadataPath
        Started       = (Get-Date).ToString('o')
        Stopped       = $null
        StartExitCode = $null
        StopExitCode  = $null
        ConvertExitCode = $null
        Status        = 'Starting'
        Warnings      = @()
    }

    try {
        if (-not $script:RuntimeDirectoryVerified) {
            Assert-DefenderRuntimeDirectory
            $script:RuntimeDirectoryVerified = $true
        }
        $start = Invoke-DefenderEtwCommand -Executable logman.exe -ArgumentList @(
            'start', $sessionName,
            '-p', $script:DefenderEtwProviderName,
            '0xC000000000000000',
            '0x4',
            '-o', $tracePath,
            '-max', '64',
            '-ets'
        )
        $script:DefenderEtwCapture.StartExitCode = $start.ExitCode
        if ($start.ExitCode -ne 0) {
            $detail = (@($start.Output) -join ' ').Trim()
            if ([string]::IsNullOrWhiteSpace($detail)) { $detail = 'no command output' }
            throw "logman start failed with exit code $($start.ExitCode): $detail"
        }
        $script:DefenderEtwCapture.Status = 'Running'
        Write-Log "Defender ETW capture started: $($script:DefenderEtwCapture.TracePath)" INFO
        return [PSCustomObject]$script:DefenderEtwCapture
    } catch {
        $message = $_.Exception.Message
        try {
            Invoke-DefenderEtwCommand -Executable logman.exe -ArgumentList @(
                'stop', $sessionName, '-ets') | Out-Null
        } catch {}
        $script:DefenderEtwCapture = $null
        Write-Log "Defender ETW capture unavailable; continuing without it: $message" WARN
        return $null
    }
}

function Stop-DefenderEtwCapture {
    if ($null -eq $script:DefenderEtwCapture) { return $null }

    $capture = $script:DefenderEtwCapture
    $script:DefenderEtwCapture = $null
    $warnings = New-Object System.Collections.ArrayList
    try {
        $stop = Invoke-DefenderEtwCommand -Executable logman.exe -ArgumentList @(
            'stop', $capture.SessionName, '-ets')
        $capture.StopExitCode = $stop.ExitCode
        if ($stop.ExitCode -ne 0) {
            [void]$warnings.Add("logman stop failed with exit code $($stop.ExitCode).")
        }
    } catch {
        $capture.StopExitCode = -1
        [void]$warnings.Add("logman stop failed: $($_.Exception.Message)")
    }

    if (Test-Path -LiteralPath $capture.TracePath -PathType Leaf) {
        try {
            $convert = Invoke-DefenderEtwCommand -Executable tracerpt.exe -ArgumentList @(
                $capture.TracePath, '-o', $capture.SummaryPath, '-of', 'CSV', '-y')
            $capture.ConvertExitCode = $convert.ExitCode
            if ($convert.ExitCode -ne 0) {
                [void]$warnings.Add("tracerpt conversion failed with exit code $($convert.ExitCode).")
            }
        } catch {
            $capture.ConvertExitCode = -1
            [void]$warnings.Add("tracerpt conversion failed: $($_.Exception.Message)")
        }
    } else {
        [void]$warnings.Add('ETL trace file was not found after the session stopped.')
    }

    $capture.Stopped = (Get-Date).ToString('o')
    $capture.Warnings = @($warnings)
    $capture.Status = if ($warnings.Count -eq 0) { 'Stopped' } else { 'StoppedWithWarnings' }
    $document = [ordered]@{}
    foreach ($key in $capture.Keys) { $document[$key] = $capture[$key] }
    try {
        Write-DefenderJsonArtifactAtomic -Name DefenderEtwCapture `
            -Path $capture.MetadataPath -InputObject $document -Depth 8 | Out-Null
    } catch {
        [void]$warnings.Add("ETW metadata write failed: $($_.Exception.Message)")
        $capture.Warnings = @($warnings)
        $capture.Status = 'StoppedWithWarnings'
    }

    $level = if ($warnings.Count -eq 0) { 'INFO' } else { 'WARN' }
    Write-Log ("Defender ETW capture stopped: status={0}; trace={1}; summary={2}" -f
        $capture.Status, $capture.TracePath, $capture.SummaryPath) $level
    return [PSCustomObject]$capture
}
