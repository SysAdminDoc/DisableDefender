# ---------------------------------------------------------------------------
# Phase: Scheduled tasks
# ---------------------------------------------------------------------------
function Disable-DefenderTasks {
    Write-Log "Disabling Defender scheduled tasks..." INFO
    foreach ($t in $script:DefenderTasks) {
        if ($WhatIfPreference) { Write-Log "WhatIf: would disable task $t" INFO; continue }
        $tn = Split-Path $t -Leaf
        $tp = Split-Path $t -Parent
        try {
            Disable-ScheduledTask -TaskName $tn -TaskPath "$tp\" -ErrorAction Stop | Out-Null
            Write-Log "Disabled task: $t" DEBUG
        } catch {
            schtasks.exe /Change /TN $t /Disable 2>&1 | Out-Null
        }
    }
    Write-Log "Scheduled tasks disabled." OK
}

function Enable-DefenderTasks {
    Write-Log "Enabling Defender scheduled tasks..." INFO
    foreach ($t in $script:DefenderTasks) {
        if ($WhatIfPreference) { Write-Log "WhatIf: would enable task $t" INFO; continue }
        $tn = Split-Path $t -Leaf
        $tp = Split-Path $t -Parent
        try {
            Enable-ScheduledTask -TaskName $tn -TaskPath "$tp\" -ErrorAction SilentlyContinue | Out-Null
        } catch {
            schtasks.exe /Change /TN $t /Enable 2>&1 | Out-Null
        }
    }
    Write-Log "Scheduled tasks enabled." OK
}
