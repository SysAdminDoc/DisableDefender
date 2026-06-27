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
    if ($null -eq $script:AclBackups -or $script:AclBackups.Count -eq 0) { return }
    $dir = $script:AppDir
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir 'acl-backup.clixml'
    $script:AclBackups | Export-Clixml -Path $path -Force
    Write-Log "ACL backup saved ($($script:AclBackups.Count) keys) to $path" DEBUG
}

function Restore-RegKeyACLs {
    $path = Join-Path $script:AppDir 'acl-backup.clixml'
    if (-not (Test-Path $path)) {
        Write-Log "No ACL backup found -- skipping ACL restore." DEBUG
        return
    }
    Write-Log "Restoring original registry ACLs..." INFO
    Initialize-Priv
    $backups = Import-Clixml -Path $path
    foreach ($subKey in $backups.Keys) {
        try {
            $entry = $backups[$subKey]
            $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
                $subKey,
                [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
                [System.Security.AccessControl.RegistryRights]::ChangePermissions -bor
                [System.Security.AccessControl.RegistryRights]::TakeOwnership)
            if ($null -eq $key) {
                Write-Log "Cannot open $subKey for ACL restore -- key may not exist." WARN
                continue
            }
            $acl = $key.GetAccessControl()
            $acl.SetSecurityDescriptorSddlForm(
                $entry.Dacl, [System.Security.AccessControl.AccessControlSections]::Access)
            $ownerSid = New-Object System.Security.Principal.SecurityIdentifier($entry.OwnerSid)
            $acl.SetOwner($ownerSid)
            $key.SetAccessControl($acl)
            $key.Close()
            Write-Log "Restored ACL for $subKey" DEBUG
        } catch {
            Write-Log "Failed to restore ACL for ${subKey}: $_" WARN
        }
    }
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    Write-Log "Registry ACLs restored." OK
}
