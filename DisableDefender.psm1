# ---------------------------------------------------------------------------
# DisableDefender PowerShell Module
# Root module -- dot-sources Private helpers then Public exported functions.
# ---------------------------------------------------------------------------

$moduleRoot = $PSScriptRoot

# Dot-source all private functions (order matters: Variables, runtime preflight, then Write-Log)
. "$moduleRoot\Private\Variables.ps1"
. "$moduleRoot\Private\RuntimeDirectory.ps1"
Initialize-DefenderRuntimeDirectory -Path $script:AppDir | Out-Null
. "$moduleRoot\Private\Write-Log.ps1"
. "$moduleRoot\Private\OperationResult.ps1"
. "$moduleRoot\Private\SurfaceDrift.ps1"
. "$moduleRoot\Private\Tripwire.ps1"
. "$moduleRoot\Private\ReplayManifest.ps1"
. "$moduleRoot\Private\PhaseRunner.ps1"
. "$moduleRoot\Private\Initialize-Priv.ps1"
. "$moduleRoot\Private\Grant-RegKeyControl.ps1"
. "$moduleRoot\Private\Invoke-AsSystem.ps1"
. "$moduleRoot\Private\Test-FirewallIntact.ps1"
. "$moduleRoot\Private\Test-TamperProtection.ps1"
. "$moduleRoot\Private\Set-RegValue.ps1"
. "$moduleRoot\Private\Set-DefenderPolicy.ps1"
. "$moduleRoot\Private\Set-MpRuntimePrefs.ps1"
. "$moduleRoot\Private\Disable-DefenderTasks.ps1"
. "$moduleRoot\Private\Set-ServiceStart.ps1"
. "$moduleRoot\Private\SafeBoot.ps1"
. "$moduleRoot\Private\SecHealthUI.ps1"
. "$moduleRoot\Private\Remove-DefenderPlatformPackages.ps1"
. "$moduleRoot\Private\ContextMenu.ps1"
. "$moduleRoot\Private\ErrorContract.ps1"
. "$moduleRoot\Private\Confirm-Prereqs.ps1"

# Dot-source all public functions (alphabetical)
. "$moduleRoot\Public\Get-DefenderStatus.ps1"
. "$moduleRoot\Public\Get-DefenderHealth.ps1"
. "$moduleRoot\Public\Get-DefenderComponentStatus.ps1"
. "$moduleRoot\Public\Show-DefenderStatus.ps1"
. "$moduleRoot\Public\Invoke-DisableDefender.ps1"
. "$moduleRoot\Public\Invoke-RemoveDefender.ps1"
. "$moduleRoot\Public\Invoke-RestoreDefender.ps1"
. "$moduleRoot\Public\Invoke-SafeModeRemove.ps1"
. "$moduleRoot\Public\New-OfflineRemoveBundle.ps1"
. "$moduleRoot\Public\Export-DefenderSupportBundle.ps1"
. "$moduleRoot\Public\Export-DefenderHtmlReport.ps1"
. "$moduleRoot\Public\Compare-DefenderSnapshots.ps1"

Export-ModuleMember -Function @(
    'Get-DefenderStatus',
    'Get-DefenderHealth',
    'Get-DefenderComponentStatus',
    'Show-DefenderStatus',
    'Invoke-DisableDefender',
    'Invoke-RemoveDefender',
    'Invoke-RestoreDefender',
    'Invoke-SafeModeRemove',
    'New-OfflineRemoveBundle',
    'Export-DefenderSupportBundle',
    'Export-DefenderHtmlReport',
    'Save-DefenderSnapshot',
    'Compare-DefenderSnapshots'
)
