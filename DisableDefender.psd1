@{
    RootModule        = 'DisableDefender.psm1'
    ModuleVersion     = '0.0.31'
    GUID              = 'a7e3f8d1-4b2c-4e9a-b5d6-1c8f2a3e4d5b'
    Author            = 'SysAdminDoc'
    CompanyName       = 'SysAdminDoc'
    Copyright         = '(c) SysAdminDoc. All rights reserved.'
    Description       = 'Disable, remove, and restore Microsoft Defender Antivirus on Windows 10/11 while explicitly preserving the Windows Firewall.'

    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Get-DefenderStatus'
        'Get-DefenderHealth'
        'Get-DefenderComponentStatus'
        'Show-DefenderStatus'
        'Invoke-DisableDefender'
        'Invoke-RemoveDefender'
        'Invoke-RestoreDefender'
        'New-OfflineRemoveBundle'
        'Export-DefenderSupportBundle'
    )

    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('Defender', 'Security', 'Windows', 'Disable', 'Remove', 'Restore', 'Firewall')
            LicenseUri   = 'https://github.com/SysAdminDoc/DisableDefender/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/SysAdminDoc/DisableDefender'
            ReleaseNotes = 'v0.0.31: Exportable support bundle for diagnosis.'
        }
    }
}
