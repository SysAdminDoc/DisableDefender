function Test-DefenderAclBackupSubKey {
    param([Parameter(Mandatory)][string]$SubKey)

    $allowed = @(
        @($script:DefenderServices + $script:MDEServices | ForEach-Object {
            "SYSTEM\CurrentControlSet\Services\$_"
        })
        'SYSTEM\CurrentControlSet\Control\SafeBoot\Minimal'
        'SYSTEM\CurrentControlSet\Control\SafeBoot\Network'
    )
    return ($allowed -contains $SubKey)
}

function Assert-DefenderAclBackupDacl {
    param(
        [Parameter(Mandatory)][string]$SubKey,
        [Parameter(Mandatory)][string]$Dacl
    )

    if ([string]::IsNullOrWhiteSpace($Dacl) -or $Dacl.Length -gt 65536) {
        throw "Registry ACL backup DACL has an invalid length for $SubKey."
    }
    try {
        $descriptor = [System.Security.AccessControl.RawSecurityDescriptor]::new(
            "O:SYG:SY$Dacl")
    } catch {
        throw "Registry ACL backup DACL is invalid for ${SubKey}: $($_.Exception.Message)"
    }
    if ($null -eq $descriptor.DiscretionaryAcl -or
        $descriptor.DiscretionaryAcl.Count -gt 256) {
        throw "Registry ACL backup DACL has an invalid ACE count for $SubKey."
    }

    $broadSids = @(
        'S-1-1-0',
        'S-1-5-11',
        'S-1-5-32-545'
    )
    $writeMask = [uint64][System.Security.AccessControl.RegistryRights]::WriteKey `
        -bor [uint64][System.Security.AccessControl.RegistryRights]::SetValue `
        -bor [uint64][System.Security.AccessControl.RegistryRights]::CreateSubKey `
        -bor [uint64][System.Security.AccessControl.RegistryRights]::ChangePermissions `
        -bor [uint64][System.Security.AccessControl.RegistryRights]::TakeOwnership `
        -bor [uint64]0x10000000 `
        -bor [uint64]0x40000000
    foreach ($ace in $descriptor.DiscretionaryAcl) {
        if ($ace -isnot [System.Security.AccessControl.QualifiedAce] -or
            $ace.AceQualifier -ne [System.Security.AccessControl.AceQualifier]::AccessAllowed) {
            continue
        }
        $mask = [uint64][uint32]$ace.AccessMask
        if (($mask -band $writeMask) -ne 0 -and
            $broadSids -contains [string]$ace.SecurityIdentifier.Value) {
            throw "Registry ACL backup DACL grants broad write access for $SubKey."
        }
    }
}

function Assert-DefenderAclBackupOwner {
    param(
        [Parameter(Mandatory)][string]$SubKey,
        [Parameter(Mandatory)][string]$OwnerSid
    )

    try {
        $parsedOwner = New-Object System.Security.Principal.SecurityIdentifier($OwnerSid)
    } catch {
        throw "Registry ACL backup owner SID is invalid for ${SubKey}: $OwnerSid"
    }
    if ($parsedOwner.Value -notin @('S-1-5-18', 'S-1-5-32-544') -and
        -not $parsedOwner.Value.StartsWith('S-1-5-80-', [StringComparison]::Ordinal)) {
        throw "Registry ACL backup owner SID is not privileged for ${SubKey}: $OwnerSid"
    }
}

function Assert-DefenderAclBackupEntry {
    param([Parameter(Mandatory)]$Entry)

    Assert-RestoreManifestProperties -InputObject $Entry `
        -Required @(
            'Sequence', 'SubKey', 'OwnerSid', 'Dacl', 'Stage',
            'CapturedAt', 'Updated', 'Error'
        ) -Allowed @(
            'Sequence', 'SubKey', 'OwnerSid', 'Dacl', 'Stage',
            'CapturedAt', 'Updated', 'Error'
        ) -Context 'Registry ACL journal entry'

    $subKey = [string]$Entry.SubKey
    if (-not (Test-DefenderAclBackupSubKey -SubKey $subKey)) {
        throw "Registry ACL backup target is not allowlisted: $subKey"
    }
    if ([int]$Entry.Sequence -lt 1 -or [int]$Entry.Sequence -gt 128) {
        throw "Registry ACL backup sequence is invalid for $subKey."
    }
    Assert-DefenderAclBackupOwner -SubKey $subKey -OwnerSid ([string]$Entry.OwnerSid)

    $stages = @(
        'OwnerCaptured',
        'OwnerChanged',
        'BaselineCaptured',
        'AclGranted',
        'MutationFailed'
    )
    if ($stages -notcontains [string]$Entry.Stage) {
        throw "Registry ACL backup stage is invalid for ${subKey}: $($Entry.Stage)"
    }
    foreach ($dateProperty in @('CapturedAt', 'Updated')) {
        try {
            [void][datetimeoffset]::Parse(
                [string]$Entry.$dateProperty,
                [Globalization.CultureInfo]::InvariantCulture)
        } catch {
            throw "Registry ACL backup $dateProperty is invalid for $subKey."
        }
    }

    if ($null -eq $Entry.Dacl) {
        if ($Entry.Stage -notin @('OwnerCaptured', 'OwnerChanged', 'MutationFailed')) {
            throw "Registry ACL backup DACL is missing after permission mutation began for $subKey."
        }
    } else {
        Assert-DefenderAclBackupDacl -SubKey $subKey -Dacl ([string]$Entry.Dacl)
    }
}

function Assert-DefenderAclBackupDocument {
    param([Parameter(Mandatory)]$Document)

    Assert-RestoreManifestProperties -InputObject $Document `
        -Required @('SchemaVersion', 'RunId', 'Created', 'Updated', 'Entries') `
        -Allowed @('SchemaVersion', 'RunId', 'Created', 'Updated', 'Entries') `
        -Context 'Registry ACL journal'
    if ([int]$Document.SchemaVersion -ne 1) {
        throw "Unsupported registry ACL journal schema version: $($Document.SchemaVersion)"
    }
    try {
        $runId = [guid]$Document.RunId
    } catch {
        throw "Registry ACL journal RunId is invalid: $($Document.RunId)"
    }
    if ($runId -eq [guid]::Empty) {
        throw 'Registry ACL journal RunId cannot be empty.'
    }
    foreach ($dateProperty in @('Created', 'Updated')) {
        try {
            [void][datetimeoffset]::Parse(
                [string]$Document.$dateProperty,
                [Globalization.CultureInfo]::InvariantCulture)
        } catch {
            throw "Registry ACL journal $dateProperty is invalid."
        }
    }

    $entries = @($Document.Entries)
    if ($entries.Count -lt 1 -or $entries.Count -gt 128) {
        throw 'Registry ACL journal entry count is outside the supported range.'
    }
    $expectedSequence = 1
    $seenSubKeys = @{}
    foreach ($entry in $entries | Sort-Object { [int]$_.Sequence }) {
        Assert-DefenderAclBackupEntry -Entry $entry
        if ([int]$entry.Sequence -ne $expectedSequence) {
            throw 'Registry ACL journal sequence numbers must be unique and contiguous.'
        }
        $subKeyToken = ([string]$entry.SubKey).ToLowerInvariant()
        if ($seenSubKeys.ContainsKey($subKeyToken)) {
            throw "Registry ACL journal contains duplicate target '$($entry.SubKey)'."
        }
        $seenSubKeys[$subKeyToken] = $true
        $expectedSequence++
    }
}

function Assert-DefenderLegacyAclBackup {
    param([Parameter(Mandatory)]$Backups)

    if ($Backups -isnot [System.Collections.IDictionary]) {
        throw 'Legacy registry ACL backup must be a dictionary.'
    }
    if ($Backups.Count -lt 1 -or $Backups.Count -gt 128) {
        throw 'Legacy registry ACL backup entry count is outside the supported range.'
    }
    foreach ($subKeyValue in $Backups.Keys) {
        $subKey = [string]$subKeyValue
        if (-not (Test-DefenderAclBackupSubKey -SubKey $subKey)) {
            throw "Registry ACL backup target is not allowlisted: $subKey"
        }
        $entry = $Backups[$subKeyValue]
        Assert-RestoreManifestProperties -InputObject $entry `
            -Required @('OwnerSid', 'Dacl') -Allowed @('OwnerSid', 'Dacl') `
            -Context "Legacy registry ACL backup entry '$subKey'"
        Assert-DefenderAclBackupOwner -SubKey $subKey -OwnerSid ([string]$entry.OwnerSid)
        Assert-DefenderAclBackupDacl -SubKey $subKey -Dacl ([string]$entry.Dacl)
    }
}

function Get-DefenderAclBackupRunId {
    if ([string]::IsNullOrWhiteSpace([string]$script:AclBackupRunId)) {
        if ($script:RestoreManifestActive -and
            -not [string]::IsNullOrWhiteSpace([string]$script:RestoreManifestRunId)) {
            $script:AclBackupRunId = [string]$script:RestoreManifestRunId
        } else {
            $script:AclBackupRunId = [guid]::NewGuid().ToString('D')
        }
    }
    return [string]$script:AclBackupRunId
}

function Get-DefenderAclBackupPath {
    param([string]$RunId = (Get-DefenderAclBackupRunId))

    try {
        $validatedRunId = ([guid]$RunId).ToString('D')
    } catch {
        throw "Registry ACL journal RunId is invalid: $RunId"
    }
    return (Join-Path $script:AppDir "acl-backup.$validatedRunId.json")
}

function New-DefenderAclBackupDocument {
    param([Parameter(Mandatory)][string]$RunId)

    $timestamp = (Get-Date).ToString('o')
    return [PSCustomObject][ordered]@{
        SchemaVersion = 1
        RunId         = ([guid]$RunId).ToString('D')
        Created       = $timestamp
        Updated       = $timestamp
        Entries       = @()
    }
}

function Get-DefenderAclBackupDocument {
    $runId = Get-DefenderAclBackupRunId
    if ($null -eq $script:AclBackupDocument -or
        [string]$script:AclBackupDocument.RunId -ne $runId) {
        $script:AclBackupDocument = New-DefenderAclBackupDocument -RunId $runId
    }
    return $script:AclBackupDocument
}

function Read-DefenderAclBackupArtifact {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$KeepOpen
    )

    $leafName = [System.IO.Path]::GetFileName($Path)
    $legacy = $leafName -eq 'acl-backup.clixml'
    if (-not $legacy -and
        $leafName -notmatch '^acl-backup\.[0-9a-fA-F-]{36}\.json$') {
        throw "Registry ACL journal path has an invalid name: $leafName"
    }

    $lease = $null
    try {
        $lease = Open-DefenderPrivilegedRuntimeFile -Path $Path -MaximumBytes 1MB
        $text = ConvertFrom-DefenderRuntimeFileBytes -Bytes $lease.Bytes
        if ($legacy) {
            $backups = [System.Management.Automation.PSSerializer]::Deserialize($text)
            Assert-DefenderLegacyAclBackup -Backups $backups
            $sequence = 0
            $entries = @($backups.Keys | Sort-Object | ForEach-Object {
                $sequence++
                $entry = $backups[$_]
                [PSCustomObject][ordered]@{
                    Sequence   = $sequence
                    SubKey     = [string]$_
                    OwnerSid   = [string]$entry.OwnerSid
                    Dacl       = [string]$entry.Dacl
                    Stage      = 'AclGranted'
                    CapturedAt = [System.IO.File]::GetLastWriteTimeUtc($Path).ToString('o')
                    Updated    = [System.IO.File]::GetLastWriteTimeUtc($Path).ToString('o')
                    Error      = $null
                }
            })
            $artifact = [PSCustomObject][ordered]@{
                Path     = [System.IO.Path]::GetFullPath($Path)
                RunId    = 'legacy'
                Created  = [System.IO.File]::GetLastWriteTimeUtc($Path).ToString('o')
                Entries  = $entries
                Legacy   = $true
                Lease    = $lease
            }
        } else {
            $document = $text | ConvertFrom-Json -ErrorAction Stop
            Assert-DefenderAclBackupDocument -Document $document
            $pathRunId = [regex]::Match(
                $leafName,
                '^acl-backup\.([0-9a-fA-F-]{36})\.json$').Groups[1].Value
            if (([guid]$pathRunId) -ne ([guid][string]$document.RunId)) {
                throw 'Registry ACL journal RunId does not match its file name.'
            }
            $artifact = [PSCustomObject][ordered]@{
                Path     = [System.IO.Path]::GetFullPath($Path)
                RunId    = [string]$document.RunId
                Created  = [string]$document.Created
                Entries  = @($document.Entries)
                Legacy   = $false
                Lease    = $lease
            }
        }
        $lease.AssertUnchanged()
        if (-not $KeepOpen) {
            $lease.Dispose()
            $artifact.Lease = $null
        }
        return $artifact
    } catch {
        if ($null -ne $lease) { $lease.Dispose() }
        throw
    }
}

function Write-DefenderAclBackupDocument {
    param([Parameter(Mandatory)]$Document)

    Assert-DefenderAclBackupDocument -Document $Document
    $path = Get-DefenderAclBackupPath -RunId ([string]$Document.RunId)
    Assert-DefenderRuntimeDirectory -Path (Split-Path -Parent $path)
    $Document.Updated = (Get-Date).ToString('o')
    $json = $Document | ConvertTo-Json -Depth 8
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($json)
    if ($bytes.Length -gt 1MB) {
        throw 'Registry ACL journal exceeds the 1 MB safety limit.'
    }

    $temporaryPath = Join-Path $script:AppDir (
        '.acl-backup-{0:N}.tmp' -f [guid]::NewGuid())
    $stream = $null
    try {
        Assert-DefenderRuntimePathComponents -RuntimeRoot $script:AppDir -Path $temporaryPath
        $stream = [System.IO.File]::Open(
            $temporaryPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::Read)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null

        if (Test-Path -LiteralPath $path) {
            Assert-DefenderRuntimePathComponents -RuntimeRoot $script:AppDir -Path $path
            [System.IO.File]::Replace($temporaryPath, $path, $null, $true)
        } else {
            [System.IO.File]::Move($temporaryPath, $path)
        }

        $verified = Read-DefenderAclBackupArtifact -Path $path
        if ([string]$verified.RunId -ne [string]$Document.RunId -or
            @($verified.Entries).Count -ne @($Document.Entries).Count) {
            throw 'Registry ACL journal readback did not match the written document.'
        }
        return $path
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-DefenderRegistryOwnerSnapshot {
    param([Parameter(Mandatory)][string]$SubKey)

    $key = $null
    try {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            $SubKey,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [System.Security.AccessControl.RegistryRights]::TakeOwnership)
        if ($null -eq $key) { throw "Registry key was not found: HKLM:\$SubKey" }
        $ownerAcl = $key.GetAccessControl(
            [System.Security.AccessControl.AccessControlSections]::Owner)
        return $ownerAcl.GetOwner(
            [System.Security.Principal.SecurityIdentifier]).Value
    } finally {
        if ($null -ne $key) { $key.Close() }
    }
}

function Set-DefenderRegistryOwnerAdministrators {
    param([Parameter(Mandatory)][string]$SubKey)

    $key = $null
    try {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            $SubKey,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [System.Security.AccessControl.RegistryRights]::TakeOwnership)
        if ($null -eq $key) { throw "Registry key was not found: HKLM:\$SubKey" }
        $ownerAcl = $key.GetAccessControl(
            [System.Security.AccessControl.AccessControlSections]::Owner)
        $ownerAcl.SetOwner(
            (New-Object System.Security.Principal.NTAccount('BUILTIN\Administrators')))
        $key.SetAccessControl($ownerAcl)
    } finally {
        if ($null -ne $key) { $key.Close() }
    }
}

function Get-DefenderRegistryDaclSnapshot {
    param([Parameter(Mandatory)][string]$SubKey)

    $key = $null
    try {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            $SubKey,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadSubTree,
            [System.Security.AccessControl.RegistryRights]::ReadPermissions)
        if ($null -eq $key) { throw "Registry key was not found: HKLM:\$SubKey" }
        $acl = $key.GetAccessControl(
            [System.Security.AccessControl.AccessControlSections]::Access)
        return $acl.GetSecurityDescriptorSddlForm(
            [System.Security.AccessControl.AccessControlSections]::Access)
    } finally {
        if ($null -ne $key) { $key.Close() }
    }
}

function Set-DefenderRegistryAdministratorsFullControl {
    param([Parameter(Mandatory)][string]$SubKey)

    $key = $null
    try {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            $SubKey,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [System.Security.AccessControl.RegistryRights]::ChangePermissions -bor
            [System.Security.AccessControl.RegistryRights]::ReadPermissions)
        if ($null -eq $key) { throw "Registry key was not found: HKLM:\$SubKey" }
        $acl = $key.GetAccessControl()
        $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
            (New-Object System.Security.Principal.NTAccount('BUILTIN\Administrators')),
            [System.Security.AccessControl.RegistryRights]::FullControl,
            [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
        $key.SetAccessControl($acl)
    } finally {
        if ($null -ne $key) { $key.Close() }
    }
}

function Test-DefenderRegistryAdministratorsControl {
    param([Parameter(Mandatory)][string]$SubKey)

    $key = $null
    try {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            $SubKey,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadSubTree,
            [System.Security.AccessControl.RegistryRights]::ReadPermissions)
        if ($null -eq $key) { return $false }
        $acl = $key.GetAccessControl(
            [System.Security.AccessControl.AccessControlSections]::Access -bor
            [System.Security.AccessControl.AccessControlSections]::Owner)
        $owner = $acl.GetOwner(
            [System.Security.Principal.SecurityIdentifier]).Value
        if ($owner -ne 'S-1-5-32-544') { return $false }
        $rules = $acl.GetAccessRules(
            $true,
            $true,
            [System.Security.Principal.SecurityIdentifier])
        foreach ($rule in $rules) {
            if ([string]$rule.IdentityReference.Value -eq 'S-1-5-32-544' -and
                $rule.AccessControlType -eq
                    [System.Security.AccessControl.AccessControlType]::Allow -and
                ($rule.RegistryRights -band
                    [System.Security.AccessControl.RegistryRights]::FullControl) -eq
                    [System.Security.AccessControl.RegistryRights]::FullControl) {
                return $true
            }
        }
        return $false
    } finally {
        if ($null -ne $key) { $key.Close() }
    }
}

function Grant-RegKeyControl {
    <#
      Takes ownership of an allowlisted HKLM registry key and grants
      BUILTIN\Administrators FullControl. A per-run journal durably records the
      original owner before owner mutation and the unchanged DACL before any
      permission mutation.
    #>
    param([Parameter(Mandatory)][string]$SubKey)

    if (-not (Test-DefenderAclBackupSubKey -SubKey $SubKey)) {
        Write-Log "Refused registry ACL takeover outside the allowlist: HKLM:\$SubKey" ERROR
        return $false
    }
    if ($WhatIfPreference) {
        Write-Log "WhatIf: would journal, take ownership, and grant FullControl on HKLM:\$SubKey" INFO
        return $true
    }

    $entry = $null
    try {
        Initialize-Priv
        $document = Get-DefenderAclBackupDocument
        $entry = @($document.Entries | Where-Object {
            [string]$_.SubKey -eq $SubKey
        } | Select-Object -First 1)
        if ($entry.Count -gt 0) {
            $entry = $entry[0]
        } else {
            $timestamp = (Get-Date).ToString('o')
            $entry = [PSCustomObject][ordered]@{
                Sequence   = @($document.Entries).Count + 1
                SubKey     = $SubKey
                OwnerSid   = Get-DefenderRegistryOwnerSnapshot -SubKey $SubKey
                Dacl       = $null
                Stage      = 'OwnerCaptured'
                CapturedAt = $timestamp
                Updated    = $timestamp
                Error      = $null
            }
            $document.Entries = @($document.Entries) + @($entry)

            # The original owner reaches stable storage before SetOwner.
            Write-DefenderAclBackupDocument -Document $document | Out-Null
        }

        Set-DefenderRegistryOwnerAdministrators -SubKey $SubKey
        $entry.Stage = 'OwnerChanged'
        $entry.Updated = (Get-Date).ToString('o')
        Write-DefenderAclBackupDocument -Document $document | Out-Null

        if ($null -eq $entry.Dacl) {
            $entry.Dacl = Get-DefenderRegistryDaclSnapshot -SubKey $SubKey
            $entry.Stage = 'BaselineCaptured'
            $entry.Updated = (Get-Date).ToString('o')

            # No DACL mutation is permitted until its exact baseline is durable.
            Write-DefenderAclBackupDocument -Document $document | Out-Null
        }

        Set-DefenderRegistryAdministratorsFullControl -SubKey $SubKey
        if (-not (Test-DefenderRegistryAdministratorsControl -SubKey $SubKey)) {
            throw 'Administrators FullControl did not verify after ACL takeover.'
        }
        $entry.Stage = 'AclGranted'
        $entry.Updated = (Get-Date).ToString('o')
        $entry.Error = $null
        Write-DefenderAclBackupDocument -Document $document | Out-Null
        return $true
    } catch {
        $failure = $_.Exception.Message
        if ($null -ne $entry) {
            $entry.Stage = 'MutationFailed'
            $entry.Updated = (Get-Date).ToString('o')
            $entry.Error = $failure
            try {
                Write-DefenderAclBackupDocument `
                    -Document (Get-DefenderAclBackupDocument) | Out-Null
            } catch {
                Write-Log "Registry ACL failure journal update also failed: $($_.Exception.Message)" WARN
            }
        }
        Write-Log "Grant-RegKeyControl failed for ${SubKey}: $failure" DEBUG
        return $false
    }
}

function Save-AclBackup {
    $result = New-DefenderActionResult -Name 'RegistryAclBackup' -Simulation:$WhatIfPreference
    if ($null -eq $script:AclBackupDocument -or
        @($script:AclBackupDocument.Entries).Count -eq 0) {
        Add-DefenderEffect -Result $result -Target 'acl-backup.<RunId>.json' `
            -Required $false -Attempted $false -Changed $false -Verified $true `
            -Evidence @{ Expected = 'NotApplicable'; Actual = 'NoAclChanges' }
        return (Complete-DefenderActionResult -Result $result)
    }

    $path = Get-DefenderAclBackupPath -RunId ([string]$script:AclBackupDocument.RunId)
    if ($WhatIfPreference) {
        Add-DefenderEffect -Result $result -Target $path -Required $false `
            -Attempted $false -Changed $false -Verified $false `
            -Evidence @{
                ExpectedEntries = @($script:AclBackupDocument.Entries).Count
                Actual = 'Simulation'
            }
        return (Complete-DefenderActionResult -Result $result)
    }

    try {
        Write-DefenderAclBackupDocument -Document $script:AclBackupDocument | Out-Null
        $verified = Read-DefenderAclBackupArtifact -Path $path
        Add-DefenderEffect -Result $result -Target $path -Attempted $true `
            -Changed $false -Verified $true -Evidence @{
                ExpectedEntries = @($script:AclBackupDocument.Entries).Count
                ActualEntries   = @($verified.Entries).Count
                RunId           = [string]$verified.RunId
            }
        Write-Log (
            "ACL journal verified ({0} keys, RunId={1}): {2}" -f
            @($verified.Entries).Count, $verified.RunId, $path) DEBUG
    } catch {
        Add-DefenderEffect -Result $result -Target $path -Attempted $true `
            -Changed $false -Verified $false `
            -Evidence @{
                ExpectedEntries = @($script:AclBackupDocument.Entries).Count
                Actual = 'Failed'
            } -Errors $_.Exception.Message
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
            [System.Security.AccessControl.RegistryRights]::TakeOwnership -bor
            [System.Security.AccessControl.RegistryRights]::ReadPermissions)
        if ($null -eq $key) {
            return [PSCustomObject]@{
                Exists       = $false
                Verified     = $true
                OwnerSid     = $null
                Dacl         = $null
                ExpectedDacl = $Entry.Dacl
                Error        = $null
            }
        }

        $acl = $key.GetAccessControl()
        $expectedDacl = if ($null -eq $Entry.Dacl) {
            # A null DACL is valid only for an owner-only write-ahead stage. The
            # application never mutates permissions until the DACL is durable,
            # so the live DACL remains the baseline after interruption.
            $acl.GetSecurityDescriptorSddlForm(
                [System.Security.AccessControl.AccessControlSections]::Access)
        } else {
            [string]$Entry.Dacl
        }
        $acl.SetSecurityDescriptorSddlForm(
            $expectedDacl,
            [System.Security.AccessControl.AccessControlSections]::Access)
        $ownerSid = New-Object System.Security.Principal.SecurityIdentifier(
            [string]$Entry.OwnerSid)
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
            $actualOwner = $verifyAcl.GetOwner(
                [System.Security.Principal.SecurityIdentifier]).Value
            $actualDacl = $verifyAcl.GetSecurityDescriptorSddlForm(
                [System.Security.AccessControl.AccessControlSections]::Access)
        } finally {
            $verifyKey.Close()
        }
        return [PSCustomObject]@{
            Exists       = $true
            Verified     = (
                $actualOwner -eq [string]$Entry.OwnerSid -and
                $actualDacl -eq $expectedDacl)
            OwnerSid     = $actualOwner
            Dacl         = $actualDacl
            ExpectedDacl = $expectedDacl
            Error        = $null
        }
    } catch {
        return [PSCustomObject]@{
            Exists       = $true
            Verified     = $false
            OwnerSid     = $null
            Dacl         = $null
            ExpectedDacl = $Entry.Dacl
            Error        = $_.Exception.Message
        }
    } finally {
        if ($null -ne $key) { $key.Close() }
    }
}

function Get-DefenderAclBackupPaths {
    param([string[]]$RunId)

    $selectedRunIds = @{}
    foreach ($value in @($RunId | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    })) {
        try {
            $selectedRunIds[([guid]$value).ToString('D')] = $true
        } catch {
            throw "Registry ACL journal selection contains an invalid RunId: $value"
        }
    }

    $paths = New-Object System.Collections.ArrayList
    $legacyPath = Join-Path $script:AppDir 'acl-backup.clixml'
    if (Test-Path -LiteralPath $legacyPath) {
        [void]$paths.Add($legacyPath)
    }
    if (Test-Path -LiteralPath $script:AppDir) {
        foreach ($file in @(Get-ChildItem -LiteralPath $script:AppDir `
            -Filter 'acl-backup.*.json' -File -ErrorAction SilentlyContinue)) {
            if ($file.Name -match
                '^acl-backup\.(?<RunId>[0-9a-fA-F-]{36})\.json$') {
                $fileRunId = try {
                    ([guid]$Matches.RunId).ToString('D')
                } catch {
                    throw "Registry ACL journal has an invalid RunId in its name: $($file.Name)"
                }
                if ($selectedRunIds.Count -eq 0 -or
                    $selectedRunIds.ContainsKey($fileRunId)) {
                    [void]$paths.Add($file.FullName)
                }
                continue
            }
            if ($file.Name -match
                '^acl-backup\.[0-9a-fA-F-]{36}\.restored\.\d{17}\.json$') {
                continue
            }
            throw "Unrecognized registry ACL journal artifact: $($file.Name)"
        }
    }
    return @($paths)
}

function Move-DefenderRestoredAclBackup {
    param([Parameter(Mandatory)][string]$Path)

    $directory = Split-Path -Parent $Path
    $name = [System.IO.Path]::GetFileName($Path)
    $stamp = Get-Date -Format 'yyyyMMddHHmmssfff'
    $archiveName = if ($name -eq 'acl-backup.clixml') {
        "acl-backup.restored.$stamp.clixml"
    } else {
        $name -replace '\.json$', ".restored.$stamp.json"
    }
    $archivePath = Join-Path $directory $archiveName
    Assert-DefenderRuntimePathComponents -RuntimeRoot $script:AppDir -Path $archivePath
    Move-Item -LiteralPath $Path -Destination $archivePath -ErrorAction Stop
    return $archivePath
}

function Restore-RegKeyACLs {
    param([string[]]$RunId)

    $result = New-DefenderActionResult -Name 'RegistryAclRestore' -Simulation:$WhatIfPreference
    try {
        Assert-DefenderRuntimeDirectory -Path $script:AppDir
        $paths = @(Get-DefenderAclBackupPaths -RunId $RunId)
    } catch {
        Add-DefenderEffect -Result $result -Target 'RegistryAclJournalDiscovery' `
            -Attempted $false -Changed $false -Verified $false `
            -Evidence @{
                Expected = 'AllowlistedPerRunArtifacts'
                Actual   = 'InvalidArtifactSet'
            } -Errors $_.Exception.Message
        return (Complete-DefenderActionResult -Result $result)
    }
    if ($paths.Count -eq 0) {
        Write-Log 'No ACL journal found -- skipping ACL restore.' DEBUG
        Add-DefenderEffect -Result $result -Target 'acl-backup.<RunId>.json' `
            -Required $false -Attempted $false -Changed $false -Verified $true `
            -Evidence @{ Expected = 'NotApplicable'; Actual = 'Absent' }
        return (Complete-DefenderActionResult -Result $result)
    }

    Write-Log "Restoring original registry ACLs from $($paths.Count) journal(s)..." INFO
    $artifacts = New-Object System.Collections.ArrayList
    try {
        foreach ($path in $paths) {
            [void]$artifacts.Add(
                (Read-DefenderAclBackupArtifact -Path $path -KeepOpen))
        }
    } catch {
        foreach ($artifact in $artifacts) {
            if ($null -ne $artifact.Lease) { $artifact.Lease.Dispose() }
        }
        Add-DefenderEffect -Result $result -Target 'RegistryAclJournalSet' `
            -Attempted $false -Changed $false -Verified $false `
            -Evidence @{ Expected = 'AllReadableAndValid'; Actual = 'InvalidOrUnreadable' } `
            -Errors $_.Exception.Message
        return (Complete-DefenderActionResult -Result $result)
    }

    try {
        Initialize-Priv
        foreach ($artifact in @($artifacts | Sort-Object {
            [datetimeoffset]::Parse([string]$_.Created)
        } -Descending)) {
            foreach ($entry in @($artifact.Entries | Sort-Object {
                [int]$_.Sequence
            } -Descending)) {
                if ($WhatIfPreference) {
                    Add-DefenderEffect -Result $result `
                        -Target "HKLM:\$($entry.SubKey)" -Required $false `
                        -Attempted $false -Changed $false -Verified $false `
                        -Evidence @{
                            RunId = $artifact.RunId
                            ExpectedOwner = $entry.OwnerSid
                            Actual = 'Simulation'
                        }
                    continue
                }

                $artifact.Lease.AssertUnchanged()
                $restore = Restore-DefenderRegistryAclEntry `
                    -SubKey ([string]$entry.SubKey) -Entry $entry
                if (-not $restore.Exists) {
                    Add-DefenderEffect -Result $result `
                        -Target "HKLM:\$($entry.SubKey)" -Required $false `
                        -Attempted $false -Changed $false -Verified $true `
                        -Evidence @{
                            RunId = $artifact.RunId
                            Expected = 'NotApplicable'
                            Actual = 'KeyAbsent'
                        }
                } else {
                    $errors = if ($restore.Verified) {
                        @()
                    } else {
                        @($restore.Error | Where-Object { $_ }) +
                            @('Registry ACL did not converge.')
                    }
                    Add-DefenderEffect -Result $result `
                        -Target "HKLM:\$($entry.SubKey)" -Attempted $true `
                        -Changed $restore.Verified -Verified $restore.Verified `
                        -Evidence @{
                            RunId         = $artifact.RunId
                            JournalStage  = $entry.Stage
                            ExpectedOwner = $entry.OwnerSid
                            ActualOwner   = $restore.OwnerSid
                            ExpectedDacl  = $restore.ExpectedDacl
                            ActualDacl    = $restore.Dacl
                        } -Errors $errors
                    if ($restore.Verified) {
                        Write-Log (
                            "Restored ACL for {0} from RunId={1}" -f
                            $entry.SubKey, $artifact.RunId) DEBUG
                    } else {
                        Write-Log (
                            "Failed to restore ACL for {0} from RunId={1}: {2}" -f
                            $entry.SubKey, $artifact.RunId, $restore.Error) WARN
                    }
                }
            }
        }
    } catch {
        Add-DefenderEffect -Result $result -Target 'RegistryAclReplay' `
            -Attempted $true -Changed $false -Verified $false `
            -Evidence @{ Expected = 'AllEntriesVerified'; Actual = 'Interrupted' } `
            -Errors $_.Exception.Message
    } finally {
        foreach ($artifact in $artifacts) {
            if ($null -ne $artifact.Lease) {
                $artifact.Lease.Dispose()
                $artifact.Lease = $null
            }
        }
    }

    $completed = Complete-DefenderActionResult -Result $result
    if ($completed.Succeeded -and -not $WhatIfPreference) {
        foreach ($artifact in $artifacts) {
            try {
                $archivePath = Move-DefenderRestoredAclBackup -Path $artifact.Path
                Write-Log "Archived verified ACL journal to $archivePath" DEBUG
            } catch {
                # A successfully replayed but unarchived journal is safe to
                # replay idempotently. Never delete it after cleanup failure.
                Write-Log (
                    "Verified ACL journal retained after archive failure: {0}: {1}" -f
                    $artifact.Path, $_.Exception.Message) WARN
            }
        }
    }
    $level = if ($completed.Succeeded) { 'OK' } else { 'WARN' }
    Write-Log (
        "Registry ACL restore result: attempted={0} changed={1} verified={2} errors={3}." -f
        $completed.Attempted,
        $completed.Changed,
        $completed.Verified,
        @($completed.Errors).Count) $level
    return $completed
}
