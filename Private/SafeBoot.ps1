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
    foreach ($path in @($script:SafeBootMin, $script:SafeBootNet)) {
        if (Test-Path -LiteralPath $path) {
            Register-RegistryTreeUndo -Path $path -Phase 'SafeBoot'
            try {
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
                Write-Log "Removed $path" DEBUG
            } catch {
                $sub = $path -replace '^HKLM:\\',''
                if (Grant-RegKeyControl -SubKey (Split-Path $sub -Parent)) {
                    Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
                    Write-Log "Removed $path (ACL takeover)" DEBUG
                } else {
                    Invoke-AsSystem -Execute 'reg.exe' -Argument "delete `"$($path -replace '^HKLM:\\','HKLM\')`" /f" | Out-Null
                }
            }
        }
    }
}
