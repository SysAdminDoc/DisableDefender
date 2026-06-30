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
    $failed = New-Object System.Collections.ArrayList
    foreach ($path in @($script:SafeBootMin, $script:SafeBootNet)) {
        if (Test-Path -LiteralPath $path) {
            Register-RegistryTreeUndo -Path $path -Phase 'SafeBoot'
            try {
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
                if (-not (Test-Path -LiteralPath $path)) {
                    Write-Log "Removed $path" DEBUG
                    continue
                }
                throw "Path remained after direct removal."
            } catch {
                $sub = $path -replace '^HKLM:\\',''
                if (Grant-RegKeyControl -SubKey (Split-Path $sub -Parent)) {
                    Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
                    if (-not (Test-Path -LiteralPath $path)) {
                        Write-Log "Removed $path (ACL takeover)" DEBUG
                        continue
                    }
                    Write-Log "SafeBoot path remained after ACL takeover: $path" WARN
                }
                if (Invoke-AsSystem -Execute 'reg.exe' -Argument "delete `"$($path -replace '^HKLM:\\','HKLM\')`" /f") {
                    Start-Sleep -Milliseconds 300
                    if (-not (Test-Path -LiteralPath $path)) {
                        Write-Log "Removed $path (SYSTEM task)" DEBUG
                        continue
                    }
                }
                Write-Log "SafeBoot path could not be removed: $path" WARN
                [void]$failed.Add($path)
            }
        }
    }
    if ($failed.Count -gt 0) {
        throw "SafeBoot WinDefend removal failed for: $($failed -join ', ')"
    }
}
