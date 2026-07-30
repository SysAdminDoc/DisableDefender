function Register-DefenderSafeModeTask {
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$EncodedScript
    )

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $EncodedScript"
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
    return (Get-DefenderSafeModeTaskEvidence -TaskName $TaskName -Kind Main `
        -ExpectedEncodedScript $EncodedScript)
}

function ConvertTo-DefenderSafeModeTransactionSummary {
    param(
        [Parameter(Mandatory)]$State,
        [switch]$Resumed
    )

    return [PSCustomObject][ordered]@{
        SchemaVersion   = Get-DefenderArtifactSchemaVersion -Name SafeModeTransactionSummary
        TransactionId   = [string]$State.TransactionId
        Stage           = [string]$State.Stage
        StatePath       = Get-DefenderSafeModeTransactionPath
        TaskName        = [string]$State.MainTaskName
        WatchdogName    = [string]$State.WatchdogTaskName
        SafeBootSet     = [bool](
            $null -ne $State.BcdEvidence -and $State.BcdEvidence.SafeBootConfigured)
        RebootDelay     = [int]$State.Options.RebootDelay
        IncludeMDE      = [bool]$State.Options.IncludeMDE
        NoRestorePoint  = [bool]$State.Options.NoRestorePoint
        Force           = [bool]$State.Options.Force
        Resumed         = [bool]$Resumed
        RecoveryAction  = $State.RecoveryAction
        LastError       = $State.LastError
    }
}

function Resume-DefenderSafeModeTransaction {
    param([Parameter(Mandatory)]$State)

    if ($State.Stage -notin @('TasksVerified', 'SafeBootConfigured', 'RebootRequested')) {
        throw "Safe Mode transaction stage '$($State.Stage)' cannot be resumed safely."
    }
    $encodedWorker = New-DefenderSafeModeWorkerCommand -State $State
    $State.MainTaskEvidence = Get-DefenderSafeModeTaskEvidence `
        -TaskName $State.MainTaskName -Kind Main -ExpectedEncodedScript $encodedWorker
    $State.WatchdogEvidence = Get-DefenderSafeModeTaskEvidence `
        -TaskName $State.WatchdogTaskName -Kind Watchdog

    if ($State.Stage -eq 'TasksVerified') {
        $State.BcdEvidence = Set-DefenderBcdSafeBoot
        Set-DefenderSafeModeTransactionStage -State $State -Stage SafeBootConfigured
    } else {
        $bcdEvidence = Get-DefenderBcdSafeBootEvidence
        if ($bcdEvidence.QueryExitCode -ne 0) {
            throw 'Could not query BCD while resuming the Safe Mode transaction.'
        }
        if (-not $bcdEvidence.SafeBootConfigured -or $bcdEvidence.Value -ine 'minimal') {
            $bcdEvidence = Set-DefenderBcdSafeBoot
        }
        $State.BcdEvidence = $bcdEvidence
        Save-DefenderSafeModeTransaction -State $State | Out-Null
    }

    $State.RecoveryAction = 'Resume'
    if ($State.Stage -eq 'SafeBootConfigured') {
        Set-DefenderSafeModeTransactionStage -State $State -Stage RebootRequested
    } else {
        Save-DefenderSafeModeTransaction -State $State | Out-Null
    }
    Invoke-DefenderSafeModeReboot -DelaySeconds ([int]$State.Options.RebootDelay) `
        -Comment "$script:AppName: resuming verified Safe Mode Defender Remove"
    return (ConvertTo-DefenderSafeModeTransactionSummary -State $State -Resumed)
}

function Invoke-SafeModeRemove {
    <#
    .SYNOPSIS
        Schedules an automatic Safe Mode boot, Remove run, and normal reboot.
    .DESCRIPTION
        Creates a persisted transaction with two verified SYSTEM startup tasks.
        The independent watchdog clears safeboot at startup. The worker captures
        the Remove child exit code and effect evidence, clears BCD only with
        readback verification, and reboots only after verified completion.
        Interrupted pre-boot stages resume; failed stages roll back deterministically.
    .PARAMETER NoRestorePoint
        Skip creating a System Restore checkpoint before the Remove run.
    .PARAMETER IncludeMDE
        Also target the MDE Sense service during Remove.
    .PARAMETER Force
        Preserve an explicit caller choice to bypass managed/domain safety
        gates in the generated Safe Mode task. Force is never added implicitly.
    .PARAMETER DelaySeconds
        Seconds to wait before rebooting into Safe Mode. Default 10.
    .PARAMETER RecoveryAction
        Auto resumes verified pre-boot stages and rolls failed stages back.
        Resume or Rollback can be selected explicitly for an existing transaction.
    .EXAMPLE
        Invoke-SafeModeRemove
    .EXAMPLE
        Invoke-SafeModeRemove -IncludeMDE -DelaySeconds 30
    .EXAMPLE
        Invoke-SafeModeRemove -Force
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$NoRestorePoint,
        [switch]$IncludeMDE,
        [switch]$Force,
        [ValidateRange(0, 3600)][int]$DelaySeconds = 10,
        [ValidateSet('Auto', 'Resume', 'Rollback')][string]$RecoveryAction = 'Auto'
    )

    if (-not $PSCmdlet.ShouldProcess('System', 'Schedule Safe Mode reboot and Defender Remove')) { return }

    $safe = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).BootupState
    $existingState = Read-DefenderSafeModeTransaction
    if ($null -ne $existingState -and
        $existingState.Stage -notin @('Completed', 'RolledBack')) {
        if ($RecoveryAction -eq 'Rollback') {
            $rolledBack = Undo-DefenderSafeModeTransaction -State $existingState `
                -Reason 'Operator requested rollback.'
            return (ConvertTo-DefenderSafeModeTransactionSummary -State $rolledBack)
        }
        if ($safe -like '*Fail-safe*') {
            throw 'An active Safe Mode transaction is already running. Let its startup task finish or reboot normally for recovery.'
        }
        if ($existingState.Stage -in @('TasksVerified', 'SafeBootConfigured', 'RebootRequested')) {
            try {
                return (Resume-DefenderSafeModeTransaction -State $existingState)
            } catch {
                $resumeError = $_.Exception.Message
                Undo-DefenderSafeModeTransaction -State $existingState `
                    -Reason "Safe Mode transaction resume failed: $resumeError" | Out-Null
                throw "Safe Mode transaction resume failed and was rolled back: $resumeError"
            }
        }
        if ($existingState.Stage -eq 'RebootRequestedNormal') {
            $completed = Complete-DefenderSafeModeNormalBoot -State $existingState
            $refreshedState = Read-DefenderSafeModeTransaction
            if (-not $completed.Succeeded) {
                throw 'Safe Mode transaction normal-boot finalization failed.'
            }
            return (ConvertTo-DefenderSafeModeTransactionSummary -State $refreshedState)
        }

        $rolledBack = Undo-DefenderSafeModeTransaction -State $existingState `
            -Reason "Interrupted Safe Mode transaction stage '$($existingState.Stage)' was rolled back."
        if ($RecoveryAction -eq 'Resume') {
            throw "Stage '$($existingState.Stage)' cannot be resumed safely; it was rolled back."
        }
        return (ConvertTo-DefenderSafeModeTransactionSummary -State $rolledBack)
    }

    if ($RecoveryAction -ne 'Auto') {
        throw "No active Safe Mode transaction is available for $RecoveryAction."
    }
    if ($safe -like '*Fail-safe*') {
        Write-Log 'Already in Safe Mode. Run -Mode Remove directly instead of scheduling.' WARN
        throw 'Already in Safe Mode. Use: .\DisableDefender.ps1 -Mode Remove'
    }

    $scriptDir = $PSScriptRoot
    if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    $moduleRoot = Split-Path -Parent $scriptDir
    $cliPath = Join-Path $moduleRoot 'DisableDefender.ps1'
    $moduleManifestPath = Join-Path $moduleRoot 'DisableDefender.psd1'
    if (-not (Test-Path -LiteralPath $cliPath)) {
        throw "CLI launcher not found: $cliPath"
    }
    if (-not (Test-Path -LiteralPath $moduleManifestPath)) {
        throw "Module manifest not found: $moduleManifestPath"
    }

    $state = New-DefenderSafeModeTransaction -CliPath $cliPath `
        -ModuleManifestPath $moduleManifestPath -IncludeMDE:$IncludeMDE `
        -NoRestorePoint:$NoRestorePoint -Force:$Force -RebootDelay $DelaySeconds
    Save-DefenderSafeModeTransaction -State $state | Out-Null
    $encodedScript = New-DefenderSafeModeWorkerCommand -State $state
    try {
        $state.MainTaskEvidence = Register-DefenderSafeModeTask `
            -TaskName $state.MainTaskName -EncodedScript $encodedScript
        Write-Log "Safe Mode Remove task registered and verified: $($state.MainTaskName)" OK

        $state.WatchdogEvidence = Register-SafeBootWatchdog `
            -TaskName $state.WatchdogTaskName
        Write-Log 'Independent SafeBoot watchdog registered and verified.' OK

        # Query both definitions again after registration so no BCD mutation can
        # occur unless the two-task set is simultaneously present and exact.
        $state.MainTaskEvidence = Get-DefenderSafeModeTaskEvidence `
            -TaskName $state.MainTaskName -Kind Main -ExpectedEncodedScript $encodedScript
        $state.WatchdogEvidence = Get-DefenderSafeModeTaskEvidence `
            -TaskName $state.WatchdogTaskName -Kind Watchdog
        Set-DefenderSafeModeTransactionStage -State $state -Stage TasksVerified

        $state.BcdEvidence = Set-DefenderBcdSafeBoot
        Set-DefenderSafeModeTransactionStage -State $state -Stage SafeBootConfigured
        Write-Log 'bcdedit safeboot=minimal set and verified.' WARN

        Set-DefenderSafeModeTransactionStage -State $state -Stage RebootRequested
        Invoke-DefenderSafeModeReboot -DelaySeconds $DelaySeconds `
            -Comment "$script:AppName: rebooting into Safe Mode for verified Defender Remove"
    } catch {
        $bootstrapError = $_.Exception.Message
        try {
            Undo-DefenderSafeModeTransaction -State $state `
                -Reason "Safe Mode bootstrap failed: $bootstrapError" | Out-Null
        } catch {
            throw "Safe Mode bootstrap failed and rollback could not be verified: $bootstrapError $($_.Exception.Message)"
        }
        throw "Safe Mode bootstrap failed and was rolled back: $bootstrapError"
    }
    return (ConvertTo-DefenderSafeModeTransactionSummary -State $state)
}
