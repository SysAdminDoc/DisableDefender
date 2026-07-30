# ---------------------------------------------------------------------------
# SafeBoot BCD watchdog -- auto-reverts safeboot flag if the tool crashes
# before cleanup, preventing the system from being trapped in Safe Mode.
# ---------------------------------------------------------------------------
function Register-SafeBootWatchdog {
    $taskName = "${script:AppName}_SafeBootWatchdog"
    try {
        $action = New-ScheduledTaskAction -Execute 'bcdedit.exe' -Argument '/deletevalue {current} safeboot'
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        Write-Log "SafeBoot watchdog registered (auto-reverts on next boot)." DEBUG
    } catch {
        Write-Log "Could not register SafeBoot watchdog: $_" WARN
    }
}

function Unregister-SafeBootWatchdog {
    $taskName = "${script:AppName}_SafeBootWatchdog"
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
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
