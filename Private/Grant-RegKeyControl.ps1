function Grant-RegKeyControl {
    <#
      Takes ownership of an HKLM registry subkey and grants BUILTIN\Administrators
      FullControl. Saves original owner + DACL for later restoration by Restore-RegKeyACLs.
      Returns $true on success. Works without TrustedInstaller.
    #>
    param([Parameter(Mandatory)][string]$SubKey)   # e.g. 'SYSTEM\CurrentControlSet\Services\WinDefend'
    if ($WhatIfPreference) {
        Write-Log "WhatIf: would take ownership + grant FullControl on HKLM:\$SubKey" INFO
        return $true
    }
    Initialize-Priv
    try {
        $admins = New-Object System.Security.Principal.NTAccount('BUILTIN\Administrators')

        # 1. Take ownership -- capture original owner first
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            $SubKey,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [System.Security.AccessControl.RegistryRights]::TakeOwnership)
        if ($null -eq $key) { return $false }
        $ownerAcl = $key.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Owner)
        $originalOwnerSid = $ownerAcl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        $ownerAcl.SetOwner($admins)
        $key.SetAccessControl($ownerAcl)
        $key.Close()

        # 2. Read original DACL (now accessible since we own the key) before adding FullControl
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            $SubKey,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [System.Security.AccessControl.RegistryRights]::ChangePermissions -bor
            [System.Security.AccessControl.RegistryRights]::ReadPermissions)
        if ($null -eq $key) { return $false }
        $acl = $key.GetAccessControl()
        $originalDacl = $acl.GetSecurityDescriptorSddlForm(
            [System.Security.AccessControl.AccessControlSections]::Access)

        # Save original ACL for later restoration
        if ($null -eq $script:AclBackups) { $script:AclBackups = @{} }
        if (-not $script:AclBackups.ContainsKey($SubKey)) {
            $script:AclBackups[$SubKey] = @{ OwnerSid = $originalOwnerSid; Dacl = $originalDacl }
        }

        # 3. Grant FullControl
        $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
            $admins,
            [System.Security.AccessControl.RegistryRights]::FullControl,
            [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
        $key.SetAccessControl($acl)
        $key.Close()
        return $true
    } catch {
        Write-Log "Grant-RegKeyControl failed for $SubKey : $_" DEBUG
        return $false
    }
}

function Save-AclBackup {
    $result = New-DefenderActionResult -Name 'RegistryAclBackup' -Simulation:$WhatIfPreference
    if ($null -eq $script:AclBackups -or $script:AclBackups.Count -eq 0) {
        Add-DefenderEffect -Result $result -Target 'acl-backup.clixml' -Required $false `
            -Attempted $false -Changed $false -Verified $true `
            -Evidence @{ Expected = 'NotApplicable'; Actual = 'NoAclChanges' }
        return (Complete-DefenderActionResult -Result $result)
    }
    $dir = $script:AppDir
    Assert-DefenderRuntimeDirectory -Path $dir
    $path = Join-Path $dir 'acl-backup.clixml'
    if ($WhatIfPreference) {
        Add-DefenderEffect -Result $result -Target $path -Required $false `
            -Attempted $false -Changed $false -Verified $false `
            -Evidence @{ ExpectedEntries = $script:AclBackups.Count; Actual = 'Simulation' }
        return (Complete-DefenderActionResult -Result $result)
    }
    try {
        $script:AclBackups | Export-Clixml -Path $path -Force -ErrorAction Stop
        $verified = Test-Path -LiteralPath $path
        Add-DefenderEffect -Result $result -Target $path -Attempted $true -Changed $verified `
            -Verified $verified -Evidence @{ ExpectedEntries = $script:AclBackups.Count; Actual = $(if ($verified) { 'Present' } else { 'Absent' }) } `
            -Errors $(if ($verified) { @() } else { @('ACL backup file was not present after export.') })
        if ($verified) {
            Write-Log "ACL backup saved ($($script:AclBackups.Count) keys) to $path" DEBUG
        }
    } catch {
        Add-DefenderEffect -Result $result -Target $path -Attempted $true -Changed $false `
            -Verified $false -Evidence @{ ExpectedEntries = $script:AclBackups.Count; Actual = 'Failed' } `
            -Errors $_.Exception.Message
    }
    return (Complete-DefenderActionResult -Result $result)
}

function Restore-DefenderRegistryAclEntry {
    param(
        [Parameter(Mandatory)][string]$SubKey,
        [Parameter(Mandatory)]$Entry
    )

    $key = $null
    try {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            $SubKey,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [System.Security.AccessControl.RegistryRights]::ChangePermissions -bor
            [System.Security.AccessControl.RegistryRights]::TakeOwnership)
        if ($null -eq $key) {
            return [PSCustomObject]@{
                Exists   = $false
                Verified = $true
                OwnerSid = $null
                Dacl     = $null
                Error    = $null
            }
        }
        $acl = $key.GetAccessControl()
        $acl.SetSecurityDescriptorSddlForm(
            $Entry.Dacl, [System.Security.AccessControl.AccessControlSections]::Access)
        $ownerSid = New-Object System.Security.Principal.SecurityIdentifier($Entry.OwnerSid)
        $acl.SetOwner($ownerSid)
        $key.SetAccessControl($acl)
        $key.Close()
        $key = $null

        $verifyKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            $SubKey,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadSubTree,
            [System.Security.AccessControl.RegistryRights]::ReadPermissions)
        if ($null -eq $verifyKey) {
            throw 'Registry key could not be reopened for ACL verification.'
        }
        try {
            $verifyAcl = $verifyKey.GetAccessControl(
                [System.Security.AccessControl.AccessControlSections]::Access -bor
                [System.Security.AccessControl.AccessControlSections]::Owner)
            $actualOwner = $verifyAcl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
            $actualDacl = $verifyAcl.GetSecurityDescriptorSddlForm(
                [System.Security.AccessControl.AccessControlSections]::Access)
        } finally {
            $verifyKey.Close()
        }
        return [PSCustomObject]@{
            Exists   = $true
            Verified = ($actualOwner -eq $Entry.OwnerSid -and $actualDacl -eq $Entry.Dacl)
            OwnerSid = $actualOwner
            Dacl     = $actualDacl
            Error    = $null
        }
    } catch {
        return [PSCustomObject]@{
            Exists   = $true
            Verified = $false
            OwnerSid = $null
            Dacl     = $null
            Error    = $_.Exception.Message
        }
    } finally {
        if ($null -ne $key) { $key.Close() }
    }
}

function Restore-RegKeyACLs {
    $result = New-DefenderActionResult -Name 'RegistryAclRestore' -Simulation:$WhatIfPreference
    $path = Join-Path $script:AppDir 'acl-backup.clixml'
    Assert-DefenderRuntimeDirectory -Path (Split-Path -Parent $path)
    if (-not (Test-Path $path)) {
        Write-Log "No ACL backup found -- skipping ACL restore." DEBUG
        Add-DefenderEffect -Result $result -Target $path -Required $false `
            -Attempted $false -Changed $false -Verified $true `
            -Evidence @{ Expected = 'NotApplicable'; Actual = 'Absent' }
        return (Complete-DefenderActionResult -Result $result)
    }
    Write-Log "Restoring original registry ACLs..." INFO
    Initialize-Priv
    try {
        $backups = Import-Clixml -Path $path -ErrorAction Stop
    } catch {
        Add-DefenderEffect -Result $result -Target $path -Attempted $false -Changed $false `
            -Verified $false -Evidence @{ Expected = 'Readable'; Actual = 'InvalidOrUnreadable' } `
            -Errors $_.Exception.Message
        return (Complete-DefenderActionResult -Result $result)
    }

    foreach ($subKey in $backups.Keys) {
        $entry = $backups[$subKey]
        if ($WhatIfPreference) {
            Add-DefenderEffect -Result $result -Target "HKLM:\$subKey" -Required $false `
                -Attempted $false -Changed $false -Verified $false `
                -Evidence @{ ExpectedOwner = $entry.OwnerSid; Actual = 'Simulation' }
            continue
        }

        $restore = Restore-DefenderRegistryAclEntry -SubKey $subKey -Entry $entry
        if (-not $restore.Exists) {
            Add-DefenderEffect -Result $result -Target "HKLM:\$subKey" -Required $false `
                -Attempted $false -Changed $false -Verified $true `
                -Evidence @{ Expected = 'NotApplicable'; Actual = 'KeyAbsent' }
        } else {
            Add-DefenderEffect -Result $result -Target "HKLM:\$subKey" -Attempted $true `
                -Changed $restore.Verified -Verified $restore.Verified `
                -Evidence @{
                    ExpectedOwner = $entry.OwnerSid
                    ActualOwner   = $restore.OwnerSid
                    ExpectedDacl  = $entry.Dacl
                    ActualDacl    = $restore.Dacl
                } -Errors $(if ($restore.Verified) { @() } else { @($restore.Error | Where-Object { $_ }) + @('Registry ACL did not converge.') })
            if ($restore.Verified) {
                Write-Log "Restored ACL for $subKey" DEBUG
            } else {
                Write-Log "Failed to restore ACL for ${subKey}: $($restore.Error)" WARN
            }
        }
    }

    $completed = Complete-DefenderActionResult -Result $result
    if ($completed.Succeeded -and -not $WhatIfPreference) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
    $level = if ($completed.Succeeded) { 'OK' } else { 'WARN' }
    Write-Log "Registry ACL restore result: attempted=$($completed.Attempted) changed=$($completed.Changed) verified=$($completed.Verified) errors=$(@($completed.Errors).Count)." $level
    return $completed
}
