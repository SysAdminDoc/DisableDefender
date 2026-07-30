# ---------------------------------------------------------------------------
# Phase: Scheduled tasks
# ---------------------------------------------------------------------------
function Get-DefenderScheduledTaskState {
    param(
        [Parameter(Mandatory)][string]$TaskPath
    )

    $taskName = Split-Path $TaskPath -Leaf
    $parentPath = "$(Split-Path $TaskPath -Parent)\"
    try {
        $task = Get-ScheduledTask -TaskName $taskName -TaskPath $parentPath -ErrorAction Stop
        if ($null -eq $task) {
            return [PSCustomObject]@{
                Readable = $true
                Exists   = $false
                Enabled  = $null
                State    = 'Absent'
                Error    = $null
            }
        }
        return [PSCustomObject]@{
            Readable = $true
            Exists   = $true
            Enabled  = ($task.State -ne 'Disabled')
            State    = [string]$task.State
            Error    = $null
        }
    } catch {
        if ($_.CategoryInfo.Category -eq 'ObjectNotFound' -or
            $_.FullyQualifiedErrorId -match 'NoMatching|ObjectNotFound' -or
            $_.Exception.Message -match 'cannot find|does not exist|not found') {
            return [PSCustomObject]@{
                Readable = $true
                Exists   = $false
                Enabled  = $null
                State    = 'Absent'
                Error    = $null
            }
        }
        return [PSCustomObject]@{
            Readable = $false
            Exists   = $null
            Enabled  = $null
            State    = 'Unknown'
            Error    = $_.Exception.Message
        }
    }
}

function Invoke-DefenderScheduledTaskFallback {
    param(
        [Parameter(Mandatory)][string]$TaskPath,
        [Parameter(Mandatory)][ValidateSet('Disable','Enable')][string]$Mode
    )

    $argument = if ($Mode -eq 'Disable') { '/Disable' } else { '/Enable' }
    & schtasks.exe /Change /TN $TaskPath $argument 2>&1 | Out-Null
    return [int]$LASTEXITCODE
}

function Invoke-DefenderScheduledTaskPlan {
    param(
        [Parameter(Mandatory)][ValidateSet('Disable','Enable')][string]$Mode,
        [string[]]$TaskPaths = $script:DefenderTasks
    )

    $result = New-DefenderActionResult -Name "ScheduledTasks:$Mode" -Simulation:$WhatIfPreference
    $expectedEnabled = ($Mode -eq 'Enable')
    foreach ($taskPath in $TaskPaths) {
        $before = Get-DefenderScheduledTaskState -TaskPath $taskPath
        if (-not $before.Readable) {
            Add-DefenderEffect -Result $result -Target $taskPath -Attempted $false -Changed $false `
                -Verified $false -Evidence @{ ExpectedEnabled = $expectedEnabled; Actual = 'Unknown' } `
                -Errors $before.Error
            continue
        }
        if (-not $before.Exists) {
            Add-DefenderEffect -Result $result -Target $taskPath -Required $false `
                -Attempted $false -Changed $false -Verified $true `
                -Evidence @{ Expected = 'NotApplicable'; Actual = 'Absent' }
            continue
        }
        if ($before.Enabled -eq $expectedEnabled) {
            Add-DefenderEffect -Result $result -Target $taskPath -Attempted $false `
                -Changed $false -Verified $true `
                -Evidence @{ ExpectedEnabled = $expectedEnabled; ActualEnabled = $before.Enabled; State = 'AlreadyCorrect' }
            continue
        }
        if ($WhatIfPreference) {
            Add-DefenderEffect -Result $result -Target $taskPath -Required $false `
                -Attempted $false -Changed $false -Verified $false `
                -Evidence @{ ExpectedEnabled = $expectedEnabled; ActualEnabled = $before.Enabled; State = 'Simulation' }
            continue
        }

        if ($Mode -eq 'Disable' -and (Test-RestoreManifestRecording)) {
            Write-RestoreManifestEntry -Phase 'Tasks' -Action 'SetScheduledTaskState' -Target $taskPath -Data ([ordered]@{
                TaskPath = $taskPath
                Enabled  = $before.Enabled
            })
        }

        $taskName = Split-Path $taskPath -Leaf
        $parentPath = "$(Split-Path $taskPath -Parent)\"
        $cmdletError = $null
        try {
            if ($Mode -eq 'Disable') {
                Disable-ScheduledTask -TaskName $taskName -TaskPath $parentPath -ErrorAction Stop | Out-Null
            } else {
                Enable-ScheduledTask -TaskName $taskName -TaskPath $parentPath -ErrorAction Stop | Out-Null
            }
        } catch {
            $cmdletError = $_.Exception.Message
        }

        $after = Get-DefenderScheduledTaskState -TaskPath $taskPath
        $nativeExitCode = $null
        if (-not $after.Readable -or -not $after.Exists -or $after.Enabled -ne $expectedEnabled) {
            try {
                $nativeExitCode = Invoke-DefenderScheduledTaskFallback -TaskPath $taskPath -Mode $Mode
            } catch {
                $nativeExitCode = -1
                if (-not $cmdletError) { $cmdletError = $_.Exception.Message }
            }
            $after = Get-DefenderScheduledTaskState -TaskPath $taskPath
        }

        $verified = $after.Readable -and $after.Exists -and ($after.Enabled -eq $expectedEnabled)
        $errors = if ($verified) {
            @()
        } elseif (-not $after.Readable) {
            @("Could not verify scheduled task state: $($after.Error)")
        } elseif ($null -ne $nativeExitCode -and $nativeExitCode -ne 0) {
            @("Scheduled task cmdlet failed ('$cmdletError') and schtasks.exe exited $nativeExitCode.")
        } elseif ($cmdletError) {
            @($cmdletError)
        } else {
            @('Scheduled task did not converge to the requested state.')
        }
        Add-DefenderEffect -Result $result -Target $taskPath -Attempted $true `
            -Changed $verified -Verified $verified `
            -Evidence @{
                ExpectedEnabled = $expectedEnabled
                ActualEnabled   = $after.Enabled
                ActualState     = $after.State
                NativeExitCode  = $nativeExitCode
                CmdletError     = $cmdletError
            } -Errors $errors
        if ($verified) {
            Write-Log "$Mode task verified: $taskPath" DEBUG
        } else {
            Write-Log "$Mode task verification failed: $taskPath" WARN
        }
    }

    return (Complete-DefenderActionResult -Result $result)
}

function Disable-DefenderTasks {
    Write-Log "Disabling Defender scheduled tasks..." INFO
    $completed = Invoke-DefenderScheduledTaskPlan -Mode Disable
    $level = if ($completed.Succeeded) { 'OK' } else { 'WARN' }
    Write-Log "Scheduled task result: attempted=$($completed.Attempted) changed=$($completed.Changed) verified=$($completed.Verified) errors=$(@($completed.Errors).Count)." $level
    return $completed
}

function Enable-DefenderTasks {
    Write-Log "Enabling Defender scheduled tasks..." INFO
    $completed = Invoke-DefenderScheduledTaskPlan -Mode Enable
    $level = if ($completed.Succeeded) { 'OK' } else { 'WARN' }
    Write-Log "Scheduled task restore result: attempted=$($completed.Attempted) changed=$($completed.Changed) verified=$($completed.Verified) errors=$(@($completed.Errors).Count)." $level
    return $completed
}
