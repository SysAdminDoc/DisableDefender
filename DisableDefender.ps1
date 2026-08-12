#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
    DisableDefender v0.0.41
    CLI launcher for the DisableDefender PowerShell module.

    DOES NOT touch the Windows Firewall. Firewall services (mpssvc, BFE) and the
    per-profile firewall state are verified before and after every operation.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Disable','Remove','Restore','Status','Health','PrepareOffline')]
    [string]$Mode,

    [switch]$Silent,
    [switch]$NoRestorePoint,
    [switch]$NoReboot,
    [switch]$Force,
    [switch]$IncludeMDE,
    [switch]$AllowRemoting,
    [switch]$EnableEtw,
    [string[]]$ComputerName,
    [switch]$Json,
    [string[]]$Only,
    [string[]]$Skip,
    [ValidateSet('Newest','All','Active')]
    [string]$ManifestSelection = 'Newest',
    [switch]$RepairWithoutManifest,
    [ValidateSet('Disable','Remove','Restore')]
    [string]$HealthTarget = 'Disable',
    [string]$Culture = 'en-US',
    [string]$LogPath = "$env:ProgramData\DisableDefender\DisableDefender.log"
)

$script:AppName = 'DisableDefender'
$script:AppDir = Join-Path $env:ProgramData $script:AppName
$runtimeDirectoryHelper = Join-Path $PSScriptRoot 'Private\RuntimeDirectory.ps1'
if (-not (Test-Path -LiteralPath $runtimeDirectoryHelper)) {
    throw "Runtime directory helper not found: $runtimeDirectoryHelper"
}
. $runtimeDirectoryHelper
Initialize-DefenderRuntimeDirectory -Path $script:AppDir | Out-Null

$modulePath = Join-Path $PSScriptRoot 'DisableDefender.psd1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "DisableDefender module manifest not found: $modulePath"
}
Import-Module -Name $modulePath -Force -ErrorAction Stop
$script:Version = (Get-Module -Name DisableDefender).Version.ToString()
$script:Presentation = Set-DefenderPresentationCulture -Culture $Culture

function Write-CliBanner {
    if ($Silent) { return }
    $bar = '=' * 72
    Write-Host ''
    Write-Host $bar -ForegroundColor DarkCyan
    Write-Host " $script:AppName v$script:Version" -ForegroundColor Cyan
    Write-Host (Get-DefenderPresentationString -Id 'app.tagline') -ForegroundColor Gray
    Write-Host $bar -ForegroundColor DarkCyan
    Write-Host ''
}

function Show-Menu {
    Write-CliBanner
    Write-Host (Get-DefenderPresentationString -Id 'menu.disable') -ForegroundColor White
    Write-Host (Get-DefenderPresentationString -Id 'menu.remove') -ForegroundColor Red
    Write-Host (Get-DefenderPresentationString -Id 'menu.restore') -ForegroundColor Green
    Write-Host (Get-DefenderPresentationString -Id 'menu.status') -ForegroundColor Cyan
    Write-Host (Get-DefenderPresentationString -Id 'menu.health') -ForegroundColor Cyan
    Write-Host (Get-DefenderPresentationString -Id 'menu.offline') -ForegroundColor Magenta
    Write-Host (Get-DefenderPresentationString -Id 'menu.quit') -ForegroundColor Gray
    Write-Host ''
    $choice = Read-Host (Get-DefenderPresentationString -Id 'menu.select')
    switch ($choice.ToUpper()) {
        '1' { return 'Disable' }
        '2' { return 'Remove' }
        '3' { return 'Restore' }
        '4' { return 'Status' }
        '5' { return 'Health' }
        '6' { return 'PrepareOffline' }
        'Q' { return $null }
        default {
            Write-Host (Get-DefenderPresentationString -Id 'menu.invalid' -ArgumentList @($choice)) -ForegroundColor Yellow
            return $null
        }
    }
}

function Invoke-SelectedMode {
    param([Parameter(Mandatory)][ValidateSet('Disable','Remove','Restore','Status','Health','PrepareOffline')][string]$SelectedMode)

    if (@($ComputerName).Count -gt 0 -and $SelectedMode -ne 'Status') {
        throw '-ComputerName is only supported with -Mode Status for read-only fleet collection.'
    }

    $common = @{
        Silent      = [bool]($Silent -or $Json)
        LogPath     = $LogPath
        ErrorAction = 'Stop'
        Confirm     = $false
        WhatIf      = [bool]$WhatIfPreference
    }

    switch ($SelectedMode) {
        'Disable' {
            Invoke-DisableDefender @common -Force:$Force -NoRestorePoint:$NoRestorePoint -IncludeMDE:$IncludeMDE -AllowRemoting:$AllowRemoting -EnableEtw:$EnableEtw -Only $Only -Skip $Skip
        }
        'Remove' {
            Invoke-RemoveDefender @common -Force:$Force -NoRestorePoint:$NoRestorePoint -IncludeMDE:$IncludeMDE -AllowRemoting:$AllowRemoting -EnableEtw:$EnableEtw -Only $Only -Skip $Skip
        }
        'Restore' {
            Invoke-RestoreDefender @common -AllowRemoting:$AllowRemoting -EnableEtw:$EnableEtw -Only $Only -Skip $Skip `
                -ManifestSelection $ManifestSelection -RepairWithoutManifest:$RepairWithoutManifest
        }
        'Status' {
            if (@($ComputerName).Count -gt 0) {
                Get-DefenderFleetStatus -ComputerName $ComputerName `
                    -AllowRemoting:$AllowRemoting -Json:$Json
            } else {
                Show-DefenderStatus -Json:$Json
            }
        }
        'Health' {
            $health = Get-DefenderHealth -Target $HealthTarget -IncludeMDE:$IncludeMDE -Json:$Json
            if ($Json) {
                $health
            } else {
                Write-Host (Get-DefenderPresentationString -Id 'cli.health.target' -ArgumentList @($health.Target)) -ForegroundColor Cyan
                Write-Host (Get-DefenderPresentationString -Id 'cli.health.summary' -ArgumentList @(
                        $health.Summary.OK,
                        $health.Summary.Drift,
                        $health.Summary.Unknown,
                        $health.Summary.Total)) -ForegroundColor Gray
                $health.Items | Format-Table Category, Name, Expected, Actual, Status -AutoSize
                if ($health.ReapplyPlan -and $health.ReapplyPlan.Count -gt 0) {
                    Write-Host ''
                    Write-Host (Get-DefenderPresentationString -Id 'cli.health.reapply') -ForegroundColor Yellow
                    foreach ($step in $health.ReapplyPlan) {
                        Write-Host (Get-DefenderPresentationString -Id 'cli.health.reapply.item' -ArgumentList @($step)) -ForegroundColor Gray
                    }
                }
            }
        }
        'PrepareOffline' {
            $outputDir = Join-Path $PSScriptRoot 'dist'
            $bundle = New-OfflineRemoveBundle -OutputDirectory $outputDir -Force:$Force
            Write-Host ''
            Write-Host (Get-DefenderPresentationString -Id 'cli.offline.generated') -ForegroundColor Cyan
            Write-Host (Get-DefenderPresentationString -Id 'cli.offline.script' -ArgumentList @($bundle.ScriptPath)) -ForegroundColor White
            Write-Host (Get-DefenderPresentationString -Id 'cli.offline.version' -ArgumentList @($bundle.Version)) -ForegroundColor Gray
            Write-Host ''
            Write-Host (Get-DefenderPresentationString -Id 'cli.offline.usage') -ForegroundColor Yellow
            Write-Host '  .\Invoke-OfflineDefenderRemove.ps1 -TargetVolume D:\' -ForegroundColor White
            Write-Host ''
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
    if (-not $Mode) { Write-Host (Get-DefenderPresentationString -Id 'cli.aborted'); exit 0 }
}

try {
    $actionModes = @('Disable','Remove','Restore')
    if ($actionModes -contains $Mode) {
        $operationResult = Invoke-SelectedMode -SelectedMode $Mode
        if ($null -eq $operationResult -or -not $operationResult.Succeeded) {
            throw "$Mode did not return a successful verified operation result."
        }
        if ($Json) {
            $operationResult | ConvertTo-Json -Depth 12
        } elseif (-not $Silent) {
            Write-Host (Get-DefenderPresentationString -Id 'cli.operation.verified' -ArgumentList @(
                    $operationResult.Attempted,
                    $operationResult.Changed,
                    $operationResult.Verified)) -ForegroundColor Cyan
        }
    } else {
        Invoke-SelectedMode -SelectedMode $Mode
    }
    if (($Mode -eq 'Disable' -or $Mode -eq 'Remove') -and -not $Json) {
        Show-DefenderStatus
    }
    if (-not $NoReboot -and -not $WhatIfPreference -and
        ($Mode -eq 'Disable' -or $Mode -eq 'Remove')) {
        if ($Silent) {
            $rebootWarning = Get-DefenderPresentationString -Id 'cli.reboot.warning'
            Add-Content -LiteralPath $LogPath -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [WARN] $rebootWarning" -ErrorAction SilentlyContinue
            shutdown.exe /r /t 15 /c "$script:AppName reboot" | Out-Null
        } else {
            $r = Read-Host (Get-DefenderPresentationString -Id 'cli.reboot.prompt')
            if ($r.ToUpper() -ne 'N') { shutdown.exe /r /t 5 | Out-Null }
        }
    }
} catch {
    $msg = $_.Exception.Message
    try { Add-Content -LiteralPath $LogPath -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [ERROR] FATAL: $msg" -ErrorAction SilentlyContinue } catch {}
    $mapping = Get-DefenderErrorMapping -Message $msg
    $exitCode = $mapping.ExitCode
    if ($Json) {
        $phaseStatePath = Join-Path $script:AppDir 'phase-state.json'
        $failedPhase = $null
        if (Test-Path -LiteralPath $phaseStatePath) {
            try {
                $phaseState = Get-Content -Raw -LiteralPath $phaseStatePath | ConvertFrom-Json
                if ($phaseState.FailedPhase) { $failedPhase = $phaseState.FailedPhase }
            } catch {}
        }
        New-DefenderErrorEnvelope -Message $msg -Mode $Mode -FailedPhase $failedPhase -PhaseStatePath $phaseStatePath | ConvertTo-Json -Depth 4
    } elseif (-not $Silent) {
        Add-Type -AssemblyName PresentationFramework
        [System.Windows.MessageBox]::Show($msg, (Get-DefenderPresentationString -Id 'cli.error.title'), 'OK', 'Error') | Out-Null
    }
    try { Stop-Transcript | Out-Null } catch {}
    exit $exitCode
}

try { Stop-Transcript | Out-Null } catch {}
