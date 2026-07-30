# ---------------------------------------------------------------------------
# Safe Mode cross-boot transaction
# ---------------------------------------------------------------------------

function Get-DefenderSafeModeTransactionPath {
    return (Join-Path $script:AppDir 'safe-mode-transaction.json')
}

function Get-DefenderSafeModeTransactionStages {
    return @(
        'Preparing',
        'TasksVerified',
        'SafeBootConfigured',
        'RebootRequested',
        'SafeModeRunning',
        'RemoveVerified',
        'ReturnConfigured',
        'RebootRequestedNormal',
        'Completed',
        'Failed',
        'RolledBack'
    )
}

function Assert-DefenderSafeModeTransactionState {
    param([Parameter(Mandatory)]$State)

    $requiredProperties = @(
        'SchemaVersion',
        'TransactionId',
        'Stage',
        'Created',
        'Updated',
        'CliPath',
        'ModuleManifestPath',
        'MainTaskName',
        'WatchdogTaskName',
        'Options',
        'MainTaskEvidence',
        'WatchdogEvidence',
        'BcdEvidence',
        'BootEvidence',
        'ChildExitCode',
        'SafeModeTaskResult',
        'FinalizerTaskResult',
        'OperationResult',
        'EffectEvidence',
        'LastError',
        'RecoveryAction'
    )
    foreach ($property in $requiredProperties) {
        if ($State.PSObject.Properties.Name -notcontains $property) {
            throw "Safe Mode transaction is missing required property '$property'."
        }
    }
    if ([int]$State.SchemaVersion -ne 1) {
        throw "Unsupported Safe Mode transaction schema version: $($State.SchemaVersion)"
    }
    try {
        $transactionId = [guid]$State.TransactionId
    } catch {
        throw 'Safe Mode transaction ID is not a GUID.'
    }
    if ($transactionId -eq [guid]::Empty) {
        throw 'Safe Mode transaction ID cannot be empty.'
    }
    if ((Get-DefenderSafeModeTransactionStages) -notcontains [string]$State.Stage) {
        throw "Safe Mode transaction has invalid stage '$($State.Stage)'."
    }
    if ([string]$State.MainTaskName -ne "${script:AppName}_SafeModeRemove" -or
        [string]$State.WatchdogTaskName -ne "${script:AppName}_SafeBootWatchdog") {
        throw 'Safe Mode transaction task names do not match the fixed privileged task names.'
    }
    foreach ($pathProperty in @('CliPath', 'ModuleManifestPath')) {
        $candidatePath = [string]$State.$pathProperty
        if ([string]::IsNullOrWhiteSpace($candidatePath) -or
            -not [System.IO.Path]::IsPathRooted($candidatePath) -or
            $candidatePath.IndexOfAny([char[]]"`r`n`"") -ge 0) {
            throw "Safe Mode transaction $pathProperty is invalid."
        }
    }
    if ([System.IO.Path]::GetFileName([string]$State.CliPath) -ne 'DisableDefender.ps1' -or
        [System.IO.Path]::GetFileName([string]$State.ModuleManifestPath) -ne 'DisableDefender.psd1') {
        throw 'Safe Mode transaction executable paths do not identify the expected project files.'
    }
    if ($null -eq $State.Options) {
        throw 'Safe Mode transaction options are missing.'
    }
    foreach ($option in @('IncludeMDE', 'NoRestorePoint', 'Force', 'RebootDelay')) {
        if ($State.Options.PSObject.Properties.Name -notcontains $option) {
            throw "Safe Mode transaction options are missing '$option'."
        }
    }
    foreach ($booleanOption in @('IncludeMDE', 'NoRestorePoint', 'Force')) {
        if ($State.Options.$booleanOption -isnot [bool]) {
            throw "Safe Mode transaction option '$booleanOption' must be Boolean."
        }
    }
    if ([int]$State.Options.RebootDelay -lt 0 -or [int]$State.Options.RebootDelay -gt 3600) {
        throw 'Safe Mode transaction reboot delay is outside the supported range.'
    }
    if (@($State.EffectEvidence).Count -gt 4096) {
        throw 'Safe Mode transaction contains too many effect evidence records.'
    }
}

function Save-DefenderSafeModeTransaction {
    param([Parameter(Mandatory)]$State)

    $path = Get-DefenderSafeModeTransactionPath
    Assert-DefenderRuntimeDirectory -Path (Split-Path -Parent $path)
    $State.Updated = (Get-Date).ToString('o')
    Assert-DefenderSafeModeTransactionState -State $State
    $json = $State | ConvertTo-Json -Depth 20
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($json)
    if ($bytes.Length -gt 4194304) {
        throw 'Safe Mode transaction exceeds the 4 MB safety limit.'
    }

    $temporaryPath = Join-Path (Split-Path -Parent $path) (
        '.safe-mode-transaction-{0:N}.tmp' -f [guid]::NewGuid())
    try {
        [System.IO.File]::WriteAllBytes($temporaryPath, $bytes)
        if (Test-Path -LiteralPath $path) {
            Assert-DefenderRuntimePathComponents `
                -RuntimeRoot ([System.IO.Path]::GetFullPath($script:AppDir)) -Path $path
            [System.IO.File]::Replace($temporaryPath, $path, $null, $true)
        } else {
            [System.IO.File]::Move($temporaryPath, $path)
        }
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
    return $path
}

function Read-DefenderSafeModeTransaction {
    $path = Get-DefenderSafeModeTransactionPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }

    $lease = $null
    try {
        $lease = Open-DefenderPrivilegedRuntimeFile -Path $path -MaximumBytes 4194304
        $json = ConvertFrom-DefenderRuntimeFileBytes -Bytes $lease.Bytes
        $state = $json | ConvertFrom-Json -ErrorAction Stop
        Assert-DefenderSafeModeTransactionState -State $state
        $lease.AssertUnchanged()
        return $state
    } finally {
        if ($null -ne $lease) { $lease.Dispose() }
    }
}

function New-DefenderSafeModeTransaction {
    param(
        [Parameter(Mandatory)][string]$CliPath,
        [Parameter(Mandatory)][string]$ModuleManifestPath,
        [switch]$IncludeMDE,
        [switch]$NoRestorePoint,
        [switch]$Force,
        [ValidateRange(0, 3600)][int]$RebootDelay
    )

    $timestamp = (Get-Date).ToString('o')
    return [PSCustomObject][ordered]@{
        SchemaVersion       = 1
        TransactionId       = [guid]::NewGuid().ToString('D')
        Stage               = 'Preparing'
        Created             = $timestamp
        Updated             = $timestamp
        CliPath             = [System.IO.Path]::GetFullPath($CliPath)
        ModuleManifestPath  = [System.IO.Path]::GetFullPath($ModuleManifestPath)
        MainTaskName        = "${script:AppName}_SafeModeRemove"
        WatchdogTaskName    = "${script:AppName}_SafeBootWatchdog"
        Options             = [PSCustomObject][ordered]@{
            IncludeMDE     = [bool]$IncludeMDE
            NoRestorePoint = [bool]$NoRestorePoint
            Force          = [bool]$Force
            RebootDelay    = $RebootDelay
        }
        MainTaskEvidence    = $null
        WatchdogEvidence    = $null
        BcdEvidence         = $null
        BootEvidence        = $null
        ChildExitCode       = $null
        SafeModeTaskResult  = $null
        FinalizerTaskResult = $null
        OperationResult     = $null
        EffectEvidence      = @()
        LastError           = $null
        RecoveryAction      = $null
    }
}

function Set-DefenderSafeModeTransactionStage {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Stage
    )

    $allowedTransitions = @{
        Preparing             = @('TasksVerified', 'Failed', 'RolledBack')
        TasksVerified         = @('SafeBootConfigured', 'Failed', 'RolledBack')
        SafeBootConfigured    = @('RebootRequested', 'Failed', 'RolledBack')
        RebootRequested       = @('SafeModeRunning', 'Failed', 'RolledBack')
        SafeModeRunning       = @('RemoveVerified', 'Failed', 'RolledBack')
        RemoveVerified        = @('ReturnConfigured', 'Failed', 'RolledBack')
        ReturnConfigured      = @('RebootRequestedNormal', 'Failed', 'RolledBack')
        RebootRequestedNormal = @('Completed', 'Failed', 'RolledBack')
        Failed                = @('RolledBack')
        Completed             = @()
        RolledBack            = @()
    }
    if (-not $allowedTransitions.ContainsKey([string]$State.Stage) -or
        $allowedTransitions[[string]$State.Stage] -notcontains $Stage) {
        throw "Invalid Safe Mode transaction transition: $($State.Stage) -> $Stage"
    }
    $State.Stage = $Stage
    Save-DefenderSafeModeTransaction -State $State | Out-Null
}

function Test-DefenderBootTrigger {
    param([Parameter(Mandatory)]$Trigger)

    if ($Trigger.PSObject.Properties.Name -contains 'TriggerType' -and
        [string]$Trigger.TriggerType -eq 'Boot') {
        return $true
    }
    if ($null -ne $Trigger.CimClass -and
        [string]$Trigger.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger') {
        return $true
    }
    return (@($Trigger.PSObject.TypeNames) -match 'BootTrigger').Count -gt 0
}

function Get-DefenderSafeModeTaskEvidence {
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][ValidateSet('Main', 'Watchdog')][string]$Kind,
        [string]$ExpectedEncodedScript,
        [switch]$AllowMissing
    )

    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    } catch {
        if (-not $AllowMissing) { throw "Scheduled task '$TaskName' was not found after registration." }
        return [PSCustomObject][ordered]@{
            TaskName       = $TaskName
            Kind           = $Kind
            Exists         = $false
            Verified       = $false
            State          = 'Missing'
            LastTaskResult = $null
            Execute        = $null
            Arguments      = $null
            BootTrigger    = $false
            UserId         = $null
            RunLevel       = $null
        }
    }

    $actions = @($task.Actions)
    $triggers = @($task.Triggers)
    $action = $actions | Select-Object -First 1
    $execute = if ($null -ne $action) { [string]$action.Execute } else { '' }
    $arguments = if ($null -ne $action) { [string]$action.Arguments } else { '' }
    $bootTrigger = @($triggers | Where-Object { Test-DefenderBootTrigger -Trigger $_ }).Count -gt 0
    $userId = if ($null -ne $task.Principal) { [string]$task.Principal.UserId } else { '' }
    $runLevel = if ($null -ne $task.Principal) { [string]$task.Principal.RunLevel } else { '' }
    $expectedArguments = if ($Kind -eq 'Main') {
        "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $ExpectedEncodedScript"
    } else {
        '/deletevalue {current} safeboot'
    }
    $expectedExecute = if ($Kind -eq 'Main') { 'powershell.exe' } else { 'bcdedit.exe' }
    $verified = (
        $actions.Count -eq 1 -and
        [System.IO.Path]::GetFileName($execute) -ieq $expectedExecute -and
        $arguments -ceq $expectedArguments -and
        $bootTrigger -and
        $userId -eq 'S-1-5-18' -and
        $runLevel -eq 'Highest'
    )

    $lastTaskResult = $null
    try {
        $taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop
        if ($null -ne $taskInfo) { $lastTaskResult = [int64]$taskInfo.LastTaskResult }
    } catch {}

    $evidence = [PSCustomObject][ordered]@{
        TaskName       = $TaskName
        Kind           = $Kind
        Exists         = $true
        Verified       = $verified
        State          = [string]$task.State
        LastTaskResult = $lastTaskResult
        Execute        = $execute
        Arguments      = $arguments
        BootTrigger    = $bootTrigger
        UserId         = $userId
        RunLevel       = $runLevel
    }
    if (-not $verified -and -not $AllowMissing) {
        throw "Scheduled task '$TaskName' did not match its required SYSTEM startup definition."
    }
    return $evidence
}

function Get-DefenderBcdSafeBootEvidence {
    $output = @(& bcdedit.exe /enum '{current}' 2>&1)
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { [string]$_ }) -join "`n"
    $match = [regex]::Match($text, '(?im)^\s*safeboot\s+(\S+)\s*$')
    return [PSCustomObject][ordered]@{
        QueryExitCode      = $exitCode
        SafeBootConfigured = $match.Success
        Value              = if ($match.Success) { $match.Groups[1].Value } else { $null }
        Output             = $text
    }
}

function Set-DefenderBcdSafeBoot {
    $output = @(& bcdedit.exe /set '{current}' safeboot minimal 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "bcdedit safeboot failed (exit $exitCode): $(($output | ForEach-Object { [string]$_ }) -join ' ')"
    }
    $evidence = Get-DefenderBcdSafeBootEvidence
    if ($evidence.QueryExitCode -ne 0 -or
        -not $evidence.SafeBootConfigured -or
        $evidence.Value -ine 'minimal') {
        throw 'bcdedit did not verify safeboot=minimal after mutation.'
    }
    return $evidence
}

function Clear-DefenderBcdSafeBoot {
    $output = @(& bcdedit.exe /deletevalue '{current}' safeboot 2>&1)
    $mutationExitCode = $LASTEXITCODE
    $evidence = Get-DefenderBcdSafeBootEvidence
    if ($evidence.QueryExitCode -ne 0 -or $evidence.SafeBootConfigured) {
        throw "bcdedit safeboot rollback could not be verified (delete exit $mutationExitCode)."
    }
    $evidence | Add-Member -NotePropertyName DeleteExitCode -NotePropertyValue $mutationExitCode
    $evidence | Add-Member -NotePropertyName DeleteOutput -NotePropertyValue (
        ($output | ForEach-Object { [string]$_ }) -join "`n")
    return $evidence
}

function Register-SafeBootWatchdog {
    param([string]$TaskName = "${script:AppName}_SafeBootWatchdog")

    try {
        $action = New-ScheduledTaskAction -Execute 'bcdedit.exe' -Argument '/deletevalue {current} safeboot'
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        $evidence = Get-DefenderSafeModeTaskEvidence -TaskName $TaskName -Kind Watchdog
        Write-Log 'SafeBoot watchdog registered and verified (independent bcdedit startup action).' DEBUG
        return $evidence
    } catch {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Log "Could not register and verify SafeBoot watchdog: $_" WARN
        throw
    }
}

function Unregister-SafeBootWatchdog {
    param([string]$TaskName = "${script:AppName}_SafeBootWatchdog")
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
}

function Remove-DefenderSafeModeTasks {
    param(
        [Parameter(Mandatory)][string]$MainTaskName,
        [Parameter(Mandatory)][string]$WatchdogTaskName
    )

    Unregister-ScheduledTask -TaskName $WatchdogTaskName -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $MainTaskName -Confirm:$false -ErrorAction SilentlyContinue
}

function Undo-DefenderSafeModeTransaction {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Reason
    )

    $rollbackError = $null
    try {
        $State.BcdEvidence = Clear-DefenderBcdSafeBoot
    } catch {
        $rollbackError = $_.Exception.Message
    }
    if ($null -eq $rollbackError) {
        Remove-DefenderSafeModeTasks -MainTaskName $State.MainTaskName `
            -WatchdogTaskName $State.WatchdogTaskName
        $State.LastError = $Reason
        $State.RecoveryAction = 'Rollback'
        if ($State.Stage -ne 'RolledBack') {
            Set-DefenderSafeModeTransactionStage -State $State -Stage RolledBack
        } else {
            Save-DefenderSafeModeTransaction -State $State | Out-Null
        }
        return $State
    }

    $State.LastError = "$Reason Rollback error: $rollbackError"
    if ($State.Stage -ne 'Failed') {
        Set-DefenderSafeModeTransactionStage -State $State -Stage Failed
    } else {
        Save-DefenderSafeModeTransaction -State $State | Out-Null
    }
    throw $State.LastError
}

function Test-DefenderSafeModeOperationResult {
    param([Parameter(Mandatory)]$OperationResult)

    if ($OperationResult.PSObject.Properties.Name -notcontains 'SchemaVersion' -or
        [int]$OperationResult.SchemaVersion -ne 1 -or
        $OperationResult.PSObject.Properties.Name -notcontains 'Ok' -or
        -not [bool]$OperationResult.Ok -or
        $OperationResult.PSObject.Properties.Name -notcontains 'Succeeded' -or
        -not [bool]$OperationResult.Succeeded -or
        [string]$OperationResult.Mode -ne 'Remove') {
        return $false
    }
    $effects = @($OperationResult.Phases | ForEach-Object { @($_.Result.Effects) })
    $requiredEffects = @($effects | Where-Object { [bool]$_.Required })
    if ($requiredEffects.Count -eq 0) { return $false }
    return @($requiredEffects | Where-Object {
        -not [bool]$_.Verified -or @($_.Errors).Count -gt 0
    }).Count -eq 0
}

function Invoke-DefenderSafeModeChild {
    param([Parameter(Mandatory)]$State)

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', [string]$State.CliPath,
        '-Mode', 'Remove',
        '-Silent',
        '-NoReboot',
        '-Json'
    )
    if ([bool]$State.Options.Force) { $arguments += '-Force' }
    if ([bool]$State.Options.IncludeMDE) { $arguments += '-IncludeMDE' }
    if ([bool]$State.Options.NoRestorePoint) { $arguments += '-NoRestorePoint' }

    $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powerShellPath
    $quotedArguments = foreach ($argument in $arguments) {
        if ($argument.IndexOfAny([char[]]" `t`"") -ge 0) {
            '"' + ($argument -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
        } else {
            $argument
        }
    }
    $startInfo.Arguments = $quotedArguments -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw 'Safe Mode Remove child process did not start.'
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        $exitCode = $process.ExitCode
    } finally {
        $process.Dispose()
    }

    $operationResult = $null
    if (-not [string]::IsNullOrWhiteSpace($stdout)) {
        try {
            $operationResult = $stdout | ConvertFrom-Json -ErrorAction Stop
        } catch {}
    }
    return [PSCustomObject][ordered]@{
        ExitCode       = $exitCode
        StandardOutput = $stdout
        StandardError  = $stderr
        OperationResult = $operationResult
    }
}

function Invoke-DefenderSafeModeReboot {
    param(
        [ValidateRange(0, 3600)][int]$DelaySeconds,
        [Parameter(Mandatory)][string]$Comment
    )

    $output = @(& shutdown.exe /r /t $DelaySeconds /c $Comment 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "shutdown reboot request failed (exit $exitCode): $(($output | ForEach-Object { [string]$_ }) -join ' ')"
    }
}

function Complete-DefenderSafeModeNormalBoot {
    param([Parameter(Mandatory)]$State)

    $State.BootEvidence = [PSCustomObject][ordered]@{
        BootupState = 'Normal boot'
        Observed    = (Get-Date).ToString('o')
    }
    if ($State.Stage -eq 'RebootRequestedNormal' -and
        $null -ne $State.SafeModeTaskResult -and
        [int]$State.SafeModeTaskResult -eq 0 -and
        $null -ne $State.OperationResult -and
        (Test-DefenderSafeModeOperationResult -OperationResult $State.OperationResult)) {
        $bcdEvidence = Get-DefenderBcdSafeBootEvidence
        if ($bcdEvidence.QueryExitCode -ne 0 -or $bcdEvidence.SafeBootConfigured) {
            return (Undo-DefenderSafeModeTransaction -State $State `
                -Reason 'Normal-boot finalization found safeboot still configured.')
        }
        $State.BcdEvidence = $bcdEvidence
        $State.RecoveryAction = 'Finalize'
        Set-DefenderSafeModeTransactionStage -State $State -Stage Completed
        Remove-DefenderSafeModeTasks -MainTaskName $State.MainTaskName `
            -WatchdogTaskName $State.WatchdogTaskName
        return [PSCustomObject]@{ Succeeded = $true; Stage = 'Completed' }
    }

    $reason = if ($State.Stage -eq 'Failed') {
        'Safe Mode removal failed; normal-boot rollback completed.'
    } else {
        "Safe Mode transaction was interrupted in stage '$($State.Stage)'; normal-boot rollback completed."
    }
    Undo-DefenderSafeModeTransaction -State $State -Reason $reason | Out-Null
    return [PSCustomObject]@{ Succeeded = $true; Stage = 'RolledBack' }
}

function Invoke-DefenderSafeModeWorker {
    param([Parameter(Mandatory)][string]$TransactionId)

    $state = Read-DefenderSafeModeTransaction
    if ($null -eq $state -or [string]$state.TransactionId -ne $TransactionId) {
        throw 'Safe Mode transaction state is missing or does not match the scheduled worker.'
    }
    $bootState = [string](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).BootupState
    if ($bootState -notlike '*Fail-safe*') {
        return (Complete-DefenderSafeModeNormalBoot -State $state)
    }
    if ($state.Stage -notin @('RebootRequested', 'SafeBootConfigured')) {
        throw "Safe Mode worker refused unexpected stage '$($state.Stage)'."
    }

    $state.BootEvidence = [PSCustomObject][ordered]@{
        BootupState = $bootState
        Observed    = (Get-Date).ToString('o')
    }
    Set-DefenderSafeModeTransactionStage -State $state -Stage SafeModeRunning

    $bcdCleared = $false
    try {
        $encodedWorker = New-DefenderSafeModeWorkerCommand -State $state
        $state.MainTaskEvidence = Get-DefenderSafeModeTaskEvidence `
            -TaskName $state.MainTaskName -Kind Main -ExpectedEncodedScript $encodedWorker
        $state.WatchdogEvidence = Get-DefenderSafeModeTaskEvidence `
            -TaskName $state.WatchdogTaskName -Kind Watchdog
        Save-DefenderSafeModeTransaction -State $state | Out-Null

        $child = Invoke-DefenderSafeModeChild -State $state
        $state.ChildExitCode = [int]$child.ExitCode
        $state.OperationResult = $child.OperationResult
        if ($null -ne $child.OperationResult) {
            $state.EffectEvidence = @(
                $child.OperationResult.Phases | ForEach-Object {
                    $phaseName = [string]$_.Name
                    foreach ($effect in @($_.Result.Effects)) {
                        [PSCustomObject][ordered]@{
                            Phase    = $phaseName
                            Target   = [string]$effect.Target
                            Required = [bool]$effect.Required
                            Verified = [bool]$effect.Verified
                            Evidence = $effect.Evidence
                            Errors   = @($effect.Errors)
                        }
                    }
                }
            )
        }
        Save-DefenderSafeModeTransaction -State $state | Out-Null
        if ($child.ExitCode -ne 0 -or
            $null -eq $child.OperationResult -or
            -not (Test-DefenderSafeModeOperationResult -OperationResult $child.OperationResult)) {
            $details = if (-not [string]::IsNullOrWhiteSpace($child.StandardError)) {
                $child.StandardError.Trim()
            } else {
                'The child did not return a verified Remove operation result.'
            }
            throw "Safe Mode Remove child failed (exit $($child.ExitCode)): $details"
        }

        Set-DefenderSafeModeTransactionStage -State $state -Stage RemoveVerified
        $state.BcdEvidence = Clear-DefenderBcdSafeBoot
        $bcdCleared = $true
        Set-DefenderSafeModeTransactionStage -State $state -Stage ReturnConfigured
        Unregister-SafeBootWatchdog -TaskName $state.WatchdogTaskName
        Set-DefenderSafeModeTransactionStage -State $state -Stage RebootRequestedNormal
        Invoke-DefenderSafeModeReboot -DelaySeconds 10 `
            -Comment 'DisableDefender: verified Safe Mode Remove complete; returning to normal boot'
        return [PSCustomObject]@{ Succeeded = $true; Stage = 'RebootRequestedNormal' }
    } catch {
        $failure = $_.Exception.Message
        if (-not $bcdCleared) {
            try {
                $state.BcdEvidence = Clear-DefenderBcdSafeBoot
                $bcdCleared = $true
            } catch {
                $failure = "$failure BCD recovery also failed: $($_.Exception.Message)"
            }
        }
        if ($bcdCleared) {
            Unregister-SafeBootWatchdog -TaskName $state.WatchdogTaskName
        }
        $state.LastError = $failure
        if ($state.Stage -ne 'Failed') {
            Set-DefenderSafeModeTransactionStage -State $state -Stage Failed
        } else {
            Save-DefenderSafeModeTransaction -State $state | Out-Null
        }
        return [PSCustomObject]@{ Succeeded = $false; Stage = 'Failed'; Error = $failure }
    }
}

function Set-DefenderSafeModeTaskResult {
    param(
        [Parameter(Mandatory)][string]$TransactionId,
        [Parameter(Mandatory)][int]$Result,
        [switch]$Finalizer
    )

    $state = Read-DefenderSafeModeTransaction
    if ($null -eq $state -or [string]$state.TransactionId -ne $TransactionId) { return }
    if ($Finalizer -or $state.Stage -in @('Completed', 'RolledBack')) {
        $state.FinalizerTaskResult = $Result
    } else {
        $state.SafeModeTaskResult = $Result
    }
    Save-DefenderSafeModeTransaction -State $state | Out-Null
}

function New-DefenderSafeModeWorkerCommand {
    param([Parameter(Mandatory)]$State)

    $modulePath = ([string]$State.ModuleManifestPath).Replace("'", "''")
    $transactionId = ([string]$State.TransactionId).Replace("'", "''")
    $workerScript = @"
`$ErrorActionPreference = 'Stop'
`$module = `$null
try {
    Import-Module -Name '$modulePath' -Force -ErrorAction Stop
    `$module = Get-Module -Name DisableDefender -ErrorAction Stop
    `$isFinalizer = ((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).BootupState -notlike '*Fail-safe*')
    `$result = & `$module { param(`$id) Invoke-DefenderSafeModeWorker -TransactionId `$id } '$transactionId'
    `$exitCode = if (`$result.Succeeded) { 0 } else { 1 }
    & `$module { param(`$id, `$code, `$finalizer) Set-DefenderSafeModeTaskResult -TransactionId `$id -Result `$code -Finalizer:`$finalizer } '$transactionId' `$exitCode `$isFinalizer
    exit `$exitCode
} catch {
    bcdedit.exe /deletevalue '{current}' safeboot 2>`$null | Out-Null
    if (`$null -ne `$module) {
        try {
            & `$module { param(`$id) Set-DefenderSafeModeTaskResult -TransactionId `$id -Result 1 } '$transactionId'
        } catch {}
    }
    exit 1
}
"@
    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($workerScript))
}

# ---------------------------------------------------------------------------
# Phase: SafeBoot trap (Remove mode only)
# Removing SafeBoot\WinDefend prevents the service from loading even in Safe Mode.
# ---------------------------------------------------------------------------
function Remove-SafeBootWinDefend {
    Write-Log "Removing SafeBoot\WinDefend entries..." INFO
    $result = New-DefenderActionResult -Name 'SafeBoot:RemoveWinDefend' -Simulation:$WhatIfPreference
    foreach ($path in @($script:SafeBootMin, $script:SafeBootNet)) {
        $exists = Test-Path -LiteralPath $path
        if (-not $exists) {
            Add-DefenderEffect -Result $result -Target $path -Attempted $false -Changed $false `
                -Verified $true -Evidence @{ Expected = 'Absent'; Actual = 'Absent'; State = 'AlreadyCorrect' }
            continue
        }
        if ($WhatIfPreference) {
            Add-DefenderEffect -Result $result -Target $path -Required $false `
                -Attempted $false -Changed $false -Verified $false `
                -Evidence @{ Expected = 'Absent'; Actual = 'Present'; State = 'Simulation' }
            continue
        }

        Register-RegistryTreeUndo -Path $path -Phase 'SafeBoot'
        $attempts = New-Object System.Collections.ArrayList
        try {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
            [void]$attempts.Add([PSCustomObject]@{ Method = 'Direct'; Error = $null })
            if (-not (Test-Path -LiteralPath $path)) {
                Write-Log "Removed $path" DEBUG
                Add-DefenderEffect -Result $result -Target $path -Attempted $true -Changed $true `
                    -Verified $true -Evidence @{ Expected = 'Absent'; Actual = 'Absent'; Method = 'Direct'; Attempts = @($attempts) }
                continue
            }
            [void]$attempts.Add([PSCustomObject]@{ Method = 'DirectReadback'; Error = 'Path remained after direct removal.' })
        } catch {
            [void]$attempts.Add([PSCustomObject]@{ Method = 'Direct'; Error = $_.Exception.Message })
        }

        $sub = $path -replace '^HKLM:\\',''
        if (Grant-RegKeyControl -SubKey (Split-Path $sub -Parent)) {
            try {
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
                [void]$attempts.Add([PSCustomObject]@{ Method = 'AclTakeover'; Error = $null })
                if (-not (Test-Path -LiteralPath $path)) {
                    Write-Log "Removed $path (ACL takeover)" DEBUG
                    Add-DefenderEffect -Result $result -Target $path -Attempted $true -Changed $true `
                        -Verified $true -Evidence @{ Expected = 'Absent'; Actual = 'Absent'; Method = 'AclTakeover'; Attempts = @($attempts) }
                    continue
                }
                [void]$attempts.Add([PSCustomObject]@{ Method = 'AclReadback'; Error = 'Path remained after ACL removal.' })
            } catch {
                [void]$attempts.Add([PSCustomObject]@{ Method = 'AclTakeover'; Error = $_.Exception.Message })
            }
        }

        $systemSucceeded = Invoke-AsSystem -Execute 'reg.exe' -Argument "delete `"$($path -replace '^HKLM:\\','HKLM\')`" /f"
        [void]$attempts.Add([PSCustomObject]@{
            Method = 'SystemTask'
            Error  = if ($systemSucceeded) { $null } else { 'SYSTEM task failed.' }
        })
        if ($systemSucceeded) {
            Start-Sleep -Milliseconds 300
            if (-not (Test-Path -LiteralPath $path)) {
                Write-Log "Removed $path (SYSTEM task)" DEBUG
                Add-DefenderEffect -Result $result -Target $path -Attempted $true -Changed $true `
                    -Verified $true -Evidence @{ Expected = 'Absent'; Actual = 'Absent'; Method = 'SystemTask'; Attempts = @($attempts) }
                continue
            }
        }

        Write-Log "SafeBoot path could not be removed: $path" WARN
        Add-DefenderEffect -Result $result -Target $path -Attempted $true -Changed $false `
            -Verified $false -Evidence @{ Expected = 'Absent'; Actual = 'Present'; Attempts = @($attempts) } `
            -Errors "SafeBoot WinDefend removal failed for $path."
    }

    return (Complete-DefenderActionResult -Result $result)
}
