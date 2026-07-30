@{
    RootModule        = 'DisableDefender.psm1'
    ModuleVersion     = '0.0.40'
    GUID              = 'a7e3f8d1-4b2c-4e9a-b5d6-1c8f2a3e4d5b'
    Author            = 'SysAdminDoc'
    CompanyName       = 'SysAdminDoc'
    Copyright         = '(c) SysAdminDoc. All rights reserved.'
    Description       = 'Disable, remove, and restore Microsoft Defender Antivirus on Windows 10/11 while explicitly preserving the Windows Firewall.'

    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Get-DefenderStatus'
        'Get-DefenderFirewallStatus'
        'Get-DefenderHealth'
        'Get-DefenderComponentStatus'
        'Get-DefenderSafeModeStatus'
        'Show-DefenderStatus'
        'Invoke-DisableDefender'
        'Invoke-RemoveDefender'
        'Invoke-RestoreDefender'
        'Invoke-SafeModeRemove'
        'New-OfflineRemoveBundle'
        'Export-DefenderSupportBundle'
        'Export-DefenderHtmlReport'
        'Save-DefenderSnapshot'
        'Compare-DefenderSnapshots'
    )

    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('Defender', 'Security', 'Windows', 'Disable', 'Remove', 'Restore', 'Firewall')
            LicenseUri   = 'https://github.com/SysAdminDoc/DisableDefender/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/SysAdminDoc/DisableDefender'
            ReleaseNotes = 'v0.0.40: Deep engineering audit -- correctness, safety, and UX hardening.'
        }
    }
}
