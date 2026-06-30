# ---------------------------------------------------------------------------
# Runtime directory preflight
# Protects privileged logs, manifests, phase state, tripwires, and ACL backups.
# ---------------------------------------------------------------------------

function Test-DefenderRuntimeWriteRights {
    param([Parameter(Mandatory)][System.Security.AccessControl.FileSystemRights]$Rights)

    $writeMask = [int64][System.Security.AccessControl.FileSystemRights]::Write `
        -bor [int64][System.Security.AccessControl.FileSystemRights]::WriteData `
        -bor [int64][System.Security.AccessControl.FileSystemRights]::CreateFiles `
        -bor [int64][System.Security.AccessControl.FileSystemRights]::AppendData `
        -bor [int64][System.Security.AccessControl.FileSystemRights]::CreateDirectories `
        -bor [int64][System.Security.AccessControl.FileSystemRights]::WriteAttributes `
        -bor [int64][System.Security.AccessControl.FileSystemRights]::WriteExtendedAttributes `
        -bor [int64][System.Security.AccessControl.FileSystemRights]::Delete `
        -bor [int64][System.Security.AccessControl.FileSystemRights]::ChangePermissions `
        -bor [int64][System.Security.AccessControl.FileSystemRights]::TakeOwnership `
        -bor [int64][System.Security.AccessControl.FileSystemRights]::Modify `
        -bor [int64][System.Security.AccessControl.FileSystemRights]::FullControl

    return (([int64]$Rights -band $writeMask) -ne 0)
}

function Get-DefenderRuntimeDirectoryWeakWriteRules {
    param([Parameter(Mandatory)][System.Security.AccessControl.DirectorySecurity]$Acl)

    $allowedSids = @{
        'S-1-5-18'     = $true # SYSTEM
        'S-1-5-32-544' = $true # BUILTIN\Administrators
    }
    $weak = New-Object System.Collections.ArrayList
    $rules = $Acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])
    foreach ($rule in $rules) {
        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
        $sid = [string]$rule.IdentityReference
        if ($allowedSids.ContainsKey($sid)) { continue }
        if (-not (Test-DefenderRuntimeWriteRights -Rights $rule.FileSystemRights)) { continue }
        [void]$weak.Add([pscustomobject]@{
            Identity = $sid
            Rights   = $rule.FileSystemRights.ToString()
        })
    }
    return @($weak)
}

function Get-DefenderRuntimeDirectoryAcl {
    param([Parameter(Mandatory)][string]$Path)

    $directory = New-Object System.IO.DirectoryInfo($Path)
    return $directory.GetAccessControl()
}

function Set-DefenderRuntimeDirectoryAcl {
    param([Parameter(Mandatory)][string]$Path)

    $acl = Get-DefenderRuntimeDirectoryAcl -Path $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) {
        [void]$acl.RemoveAccessRuleAll($rule)
    }

    $inheritance = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    $accessType = [System.Security.AccessControl.AccessControlType]::Allow
    foreach ($sidValue in @('S-1-5-32-544','S-1-5-18')) {
        $identity = New-Object System.Security.Principal.SecurityIdentifier($sidValue)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $identity,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            $propagation,
            $accessType)
        $acl.AddAccessRule($rule)
    }

    $directory = New-Object System.IO.DirectoryInfo($Path)
    $directory.SetAccessControl($acl)
}

function Test-DefenderDefaultRuntimeDirectory {
    param([Parameter(Mandatory)][string]$Path)

    $defaultPath = [System.IO.Path]::GetFullPath((Join-Path $env:ProgramData 'DisableDefender')).TrimEnd('\')
    $candidatePath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    return $candidatePath.Equals($defaultPath, [System.StringComparison]::OrdinalIgnoreCase)
}

function Initialize-DefenderRuntimeDirectory {
    param(
        [string]$Path = $script:AppDir,
        [bool]$RepairAcl = $true
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'Runtime directory path is not configured.'
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $created = $false
    $repaired = $false

    if (Test-Path -LiteralPath $fullPath) {
        $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
        if (-not $item.PSIsContainer) {
            throw "Runtime directory path exists but is not a directory: $fullPath"
        }
        if (([int]$item.Attributes -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Runtime directory refused because it is a reparse point: $fullPath"
        }
    } else {
        New-Item -ItemType Directory -Path $fullPath -Force | Out-Null
        $created = $true
    }

    $acl = Get-DefenderRuntimeDirectoryAcl -Path $fullPath
    $weakRules = @(Get-DefenderRuntimeDirectoryWeakWriteRules -Acl $acl)
    if ($RepairAcl -and ($created -or $weakRules.Count -gt 0 -or -not $acl.AreAccessRulesProtected)) {
        try {
            Set-DefenderRuntimeDirectoryAcl -Path $fullPath
            $repaired = $true
        } catch {
            throw "Runtime directory ACL hardening failed for ${fullPath}: $($_.Exception.Message)"
        }
    }

    if (-not $RepairAcl) {
        return [pscustomobject]@{
            Path     = $fullPath
            Created  = $created
            Repaired = $repaired
        }
    }

    $verifiedAcl = Get-DefenderRuntimeDirectoryAcl -Path $fullPath
    $remainingWeakRules = @(Get-DefenderRuntimeDirectoryWeakWriteRules -Acl $verifiedAcl)
    if ($remainingWeakRules.Count -gt 0) {
        $identities = ($remainingWeakRules | ForEach-Object { $_.Identity }) -join ', '
        throw "Runtime directory grants write access to non-admin principals: $identities"
    }
    if (-not $verifiedAcl.AreAccessRulesProtected) {
        throw "Runtime directory ACL inheritance remains enabled after hardening: $fullPath"
    }

    return [pscustomobject]@{
        Path     = $fullPath
        Created  = $created
        Repaired = $repaired
    }
}

function Assert-DefenderRuntimeDirectory {
    param([string]$Path = $script:AppDir)
    Initialize-DefenderRuntimeDirectory -Path $Path -RepairAcl:(Test-DefenderDefaultRuntimeDirectory -Path $Path) | Out-Null
}
