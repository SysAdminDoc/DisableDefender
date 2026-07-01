function Invoke-SafeModeRemove {
    <#
    .SYNOPSIS
        Schedules an automatic Safe Mode boot, Remove run, and normal reboot.
    .DESCRIPTION
        Creates a one-shot scheduled task that:
        1. Sets bcdedit safeboot minimal
        2. Reboots into Safe Mode
        3. On Safe Mode boot, runs DisableDefender -Mode Remove -Force -Silent -NoReboot
        4. Clears the safeboot flag
        5. Reboots back to normal

        A watchdog task is registered to clear the safeboot flag on the next
        boot even if the Remove script fails, preventing the system from
        being trapped in Safe Mode.
    .PARAMETER NoRestorePoint
        Skip creating a System Restore checkpoint before the Remove run.
    .PARAMETER IncludeMDE
        Also target the MDE Sense service during Remove.
    .PARAMETER DelaySeconds
        Seconds to wait before rebooting into Safe Mode. Default 10.
    .EXAMPLE
        Invoke-SafeModeRemove
    .EXAMPLE
        Invoke-SafeModeRemove -IncludeMDE -DelaySeconds 30
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$NoRestorePoint,
        [switch]$IncludeMDE,
        [int]$DelaySeconds = 10
    )

    if (-not $PSCmdlet.ShouldProcess('System', 'Schedule Safe Mode reboot and Defender Remove')) { return }

    $safe = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).BootupState
    if ($safe -like '*Fail-safe*') {
        Write-Log "Already in Safe Mode. Run -Mode Remove -Force directly instead of scheduling." WARN
        throw "Already in Safe Mode. Use: .\DisableDefender.ps1 -Mode Remove -Force"
    }

    $scriptDir = $PSScriptRoot
    if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    $moduleRoot = Split-Path -Parent $scriptDir
    $cliPath = Join-Path $moduleRoot 'DisableDefender.ps1'
    if (-not (Test-Path -LiteralPath $cliPath)) {
        throw "CLI launcher not found: $cliPath"
    }

    $taskName = "${script:AppName}_SafeModeRemove"
    $watchdogName = "${script:AppName}_SafeBootWatchdog"

    $mdeFlag = if ($IncludeMDE) { ' -IncludeMDE' } else { '' }
    $rpFlag = if ($NoRestorePoint) { ' -NoRestorePoint' } else { '' }

    $removeScript = @"
try {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$cliPath" -Mode Remove -Force -Silent -NoReboot$mdeFlag$rpFlag
} finally {
    bcdedit.exe /deletevalue '{current}' safeboot 2>`$null
    Unregister-ScheduledTask -TaskName '$taskName' -Confirm:`$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName '$watchdogName' -Confirm:`$false -ErrorAction SilentlyContinue
    shutdown.exe /r /t 10 /c 'DisableDefender: returning to normal boot after Safe Mode Remove'
}
"@

    $encodedScript = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($removeScript))

    try {
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedScript"
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        Write-Log "Safe Mode Remove task registered: $taskName" OK
    } catch {
        throw "Failed to register Safe Mode Remove task: $_"
    }

    Register-SafeBootWatchdog
    Write-Log "SafeBoot watchdog registered as fallback." OK

    $result = bcdedit.exe /set '{current}' safeboot minimal 2>&1
    if ($LASTEXITCODE -ne 0) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Unregister-SafeBootWatchdog
        throw "bcdedit safeboot failed: $result"
    }
    Write-Log "bcdedit safeboot minimal set. Rebooting in $DelaySeconds seconds..." WARN
    shutdown.exe /r /t $DelaySeconds /c "$script:AppName: rebooting into Safe Mode for Defender Remove" | Out-Null

    return [PSCustomObject]@{
        TaskName      = $taskName
        WatchdogName  = $watchdogName
        SafeBootSet   = $true
        RebootDelay   = $DelaySeconds
        IncludeMDE    = [bool]$IncludeMDE
        NoRestorePoint = [bool]$NoRestorePoint
    }
}
