# ---------------------------------------------------------------------------
# DisableDefender PowerShell Module
# Root module -- dot-sources Private helpers then Public exported functions.
# ---------------------------------------------------------------------------

$moduleRoot = $PSScriptRoot

# Initialize app directory with hardened ACLs
$script:AppDir = Join-Path $env:ProgramData 'DisableDefender'
if (-not (Test-Path $script:AppDir)) {
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

# Dot-source all private functions (order matters: Variables first, Write-Log second)
. "$moduleRoot\Private\Variables.ps1"
. "$moduleRoot\Private\Write-Log.ps1"
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
. "$moduleRoot\Private\Confirm-Prereqs.ps1"

# Dot-source all public functions
. "$moduleRoot\Public\Get-DefenderStatus.ps1"
. "$moduleRoot\Public\Show-DefenderStatus.ps1"
. "$moduleRoot\Public\Invoke-DisableDefender.ps1"
. "$moduleRoot\Public\Invoke-RemoveDefender.ps1"
. "$moduleRoot\Public\Invoke-RestoreDefender.ps1"

Export-ModuleMember -Function @(
    'Get-DefenderStatus',
    'Show-DefenderStatus',
    'Invoke-DisableDefender',
    'Invoke-RemoveDefender',
    'Invoke-RestoreDefender'
)
