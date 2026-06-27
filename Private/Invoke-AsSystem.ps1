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
    try {
        $action = New-ScheduledTaskAction -Execute $Execute -Argument $Argument
        $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
        for ($i=0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 300
            $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
            if ($info -and $info.LastTaskResult -ne 267009) { break }  # 267009 = still running
        }
        return $true
    } catch {
        Write-Log "Invoke-AsSystem failed: $_" DEBUG
        return $false
    } finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}
