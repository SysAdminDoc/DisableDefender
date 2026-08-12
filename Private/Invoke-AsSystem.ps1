# ---------------------------------------------------------------------------
# SYSTEM execution via transient scheduled task (fallback for keys that
# Administrator can't write but SYSTEM can).
# ---------------------------------------------------------------------------
function Invoke-AsSystem {
    param(
        [Parameter(Mandatory)][string]$Execute,
        [Parameter(Mandatory)][string]$Argument
    )
    if ($WhatIfPreference) {
        Write-Log "WhatIf: would run as SYSTEM: $Execute $Argument" INFO
        return $true
    }
    $taskName = "_dp_{0:N}" -f [guid]::NewGuid()
    Assert-DefenderRuntimeDirectory
    try {
        # Execute the allowlisted binary directly. A shell wrapper would add
        # a second command parser at SYSTEM privilege and reintroduce injection
        # risk merely to capture stdout that is not required for verification.
        $action = New-ScheduledTaskAction -Execute $Execute -Argument $Argument
        $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
        $lastResult = $null
        for ($i=0; $i -lt 120; $i++) {
            Start-Sleep -Milliseconds 500
            $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
            if ($info) {
                $lastResult = [int]$info.LastTaskResult
                if ($lastResult -ne 267009) { break }  # 267009 = still running
            }
        }
        if ($lastResult -eq 0) {
            Write-Log "SYSTEM task completed: $Execute $Argument (LastTaskResult=0)" DEBUG
            return $true
        }
        if ($null -eq $lastResult) {
            Write-Log "SYSTEM task did not report a final LastTaskResult: $Execute $Argument" WARN
        } else {
            Write-Log "SYSTEM task failed: $Execute $Argument (LastTaskResult=$lastResult)" WARN
        }
        return $false
    } catch {
        Write-Log "Invoke-AsSystem failed: $_" DEBUG
        return $false
    } finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}
