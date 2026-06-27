#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
    DisableDefender v0.0.15
    CLI launcher for the DisableDefender PowerShell module.

    DOES NOT touch the Windows Firewall. Firewall services (mpssvc, BFE) and the
    per-profile firewall state are verified before and after every operation.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Disable','Remove','Restore','Status','Health')]
    [string]$Mode,

    [switch]$Silent,
    [switch]$NoRestorePoint,
    [switch]$NoReboot,
    [switch]$Force,
    [switch]$IncludeMDE,
    [switch]$AllowRemoting,
    [switch]$Json,
    [string[]]$Only,
    [string[]]$Skip,
    [ValidateSet('Disable','Remove','Restore')]
    [string]$HealthTarget = 'Disable',
    [string]$LogPath = "$env:ProgramData\DisableDefender\DisableDefender.log"
)

$script:AppName = 'DisableDefender'
$script:AppDir = Join-Path $env:ProgramData $script:AppName
if (-not (Test-Path -LiteralPath $script:AppDir)) {
    New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
    try {
        $dirAcl = Get-Acl -LiteralPath $script:AppDir
        $dirAcl.SetAccessRuleProtection($true, $false)
        $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            'BUILTIN\Administrators', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            'NT AUTHORITY\SYSTEM', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $dirAcl.AddAccessRule($adminRule)
        $dirAcl.AddAccessRule($systemRule)
        Set-Acl -LiteralPath $script:AppDir -AclObject $dirAcl
    } catch {}
}

$modulePath = Join-Path $PSScriptRoot 'DisableDefender.psd1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "DisableDefender module manifest not found: $modulePath"
}
Import-Module -Name $modulePath -Force -ErrorAction Stop
$script:Version = (Get-Module -Name DisableDefender).Version.ToString()

function Write-CliBanner {
    if ($Silent) { return }
    $bar = '=' * 72
    Write-Host ''
    Write-Host $bar -ForegroundColor DarkCyan
    Write-Host " $script:AppName v$script:Version" -ForegroundColor Cyan
    Write-Host "  Microsoft Defender disabler / remover (firewall preserved)" -ForegroundColor Gray
    Write-Host $bar -ForegroundColor DarkCyan
    Write-Host ''
}

function Show-Menu {
    Write-CliBanner
    Write-Host '  [1] Disable  (reversible; policy + tasks + passive mode + services)' -ForegroundColor White
    Write-Host '  [2] Remove   (aggressive; Safe Mode recommended; SecHealthUI + SafeBoot trap)' -ForegroundColor Red
    Write-Host '  [3] Restore  (undo: clear policy, re-enable services, reprovision UI)' -ForegroundColor Green
    Write-Host '  [4] Status   (show current Defender + firewall state)' -ForegroundColor Cyan
    Write-Host '  [5] Health   (compare current state to expected target)' -ForegroundColor Cyan
    Write-Host '  [Q] Quit' -ForegroundColor Gray
    Write-Host ''
    $choice = Read-Host 'Select'
    switch ($choice.ToUpper()) {
        '1' { return 'Disable' }
        '2' { return 'Remove' }
        '3' { return 'Restore' }
        '4' { return 'Status' }
        '5' { return 'Health' }
        'Q' { return $null }
        default { return $null }
    }
}

function Invoke-SelectedMode {
    param([Parameter(Mandatory)][ValidateSet('Disable','Remove','Restore','Status','Health')][string]$SelectedMode)

    $common = @{
        Silent      = [bool]$Silent
        LogPath     = $LogPath
        ErrorAction = 'Stop'
        Confirm     = $false
        WhatIf      = [bool]$WhatIfPreference
    }

    switch ($SelectedMode) {
        'Disable' {
            Invoke-DisableDefender @common -Force:$Force -NoRestorePoint:$NoRestorePoint -IncludeMDE:$IncludeMDE -AllowRemoting:$AllowRemoting -Only $Only -Skip $Skip
        }
        'Remove' {
            Invoke-RemoveDefender @common -Force:$Force -NoRestorePoint:$NoRestorePoint -IncludeMDE:$IncludeMDE -AllowRemoting:$AllowRemoting -Only $Only -Skip $Skip
        }
        'Restore' {
            Invoke-RestoreDefender @common -AllowRemoting:$AllowRemoting -Only $Only -Skip $Skip
        }
        'Status' {
            Show-DefenderStatus -Json:$Json
        }
        'Health' {
            $health = Get-DefenderHealth -Target $HealthTarget -IncludeMDE:$IncludeMDE -Json:$Json
            if ($Json) {
                $health
            } else {
                Write-Host "Health target: $($health.Target)" -ForegroundColor Cyan
                Write-Host "OK=$($health.Summary.OK) Drift=$($health.Summary.Drift) Unknown=$($health.Summary.Unknown) Total=$($health.Summary.Total)" -ForegroundColor Gray
                $health.Items | Format-Table Category, Name, Expected, Actual, Status -AutoSize
            }
        }
    }
}

try {
    Start-Transcript -Path (Join-Path $script:AppDir 'transcript.log') -Append -Force | Out-Null
} catch {}

try {
    Add-Content -LiteralPath $LogPath -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [INFO] === $script:AppName v$script:Version starting (Mode=$Mode) ===" -ErrorAction SilentlyContinue
} catch {}

if (-not $Mode) {
    if ($Silent) { throw 'Silent mode requires -Mode' }
    $Mode = Show-Menu
    if (-not $Mode) { Write-Host 'Aborted.'; exit 0 }
}

try {
    Invoke-SelectedMode -SelectedMode $Mode
    if ($Mode -ne 'Status') {
        Show-DefenderStatus -Json:$Json
    }
    if (-not $NoReboot -and -not $WhatIfPreference -and ($Mode -eq 'Disable' -or $Mode -eq 'Remove')) {
        if ($Silent) {
            Add-Content -LiteralPath $LogPath -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [WARN] Rebooting in 15 seconds..." -ErrorAction SilentlyContinue
            shutdown.exe /r /t 15 /c "$script:AppName reboot" | Out-Null
        } else {
            $r = Read-Host 'Reboot now? (Y/n)'
            if ($r.ToUpper() -ne 'N') { shutdown.exe /r /t 5 | Out-Null }
        }
    }
} catch {
    $msg = $_.Exception.Message
    try { Add-Content -LiteralPath $LogPath -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [ERROR] FATAL: $msg" -ErrorAction SilentlyContinue } catch {}
    $exitCode = 1
    if ($msg -match 'Tamper Protection') { $exitCode = 2 }
    elseif ($msg -match 'Safe Mode')     { $exitCode = 3 }
    elseif ($msg -match 'Firewall')      { $exitCode = 4 }
    elseif ($msg -match 'managed')       { $exitCode = 5 }
    if (-not $Silent) {
        Add-Type -AssemblyName PresentationFramework
        [System.Windows.MessageBox]::Show($msg, "$script:AppName error", 'OK', 'Error') | Out-Null
    }
    try { Stop-Transcript | Out-Null } catch {}
    exit $exitCode
}

try { Stop-Transcript | Out-Null } catch {}
