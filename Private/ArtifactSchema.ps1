# ---------------------------------------------------------------------------
# Persisted artifact schema registry
# Every durable machine-readable format owns an independent version.
# ---------------------------------------------------------------------------

$script:DefenderArtifactSchemas = [ordered]@{
    ActionResult = [PSCustomObject]@{
        CurrentVersion    = 1
        SupportedVersions = @(1)
        LegacyFormats     = @()
    }
    OperationResult = [PSCustomObject]@{
        CurrentVersion    = 1
        SupportedVersions = @(1)
        LegacyFormats     = @()
    }
    RestoreManifestEntry = [PSCustomObject]@{
        CurrentVersion    = 1
        SupportedVersions = @(1)
        LegacyFormats     = @()
    }
    RestoreReplayState = [PSCustomObject]@{
        CurrentVersion    = 1
        SupportedVersions = @(1)
        LegacyFormats     = @()
    }
    PhaseState = [PSCustomObject]@{
        CurrentVersion    = 1
        SupportedVersions = @(1)
        LegacyFormats     = @()
    }
    RegistryAclJournal = [PSCustomObject]@{
        CurrentVersion    = 1
        SupportedVersions = @(1)
        LegacyFormats     = @('LegacyClixmlV0')
    }
    SafeModeTransaction = [PSCustomObject]@{
        CurrentVersion    = 1
        SupportedVersions = @(1)
        LegacyFormats     = @()
    }
    SafeModeTransactionSummary = [PSCustomObject]@{
        CurrentVersion    = 1
        SupportedVersions = @(1)
        LegacyFormats     = @()
    }
    SafeModeStatus = [PSCustomObject]@{
        CurrentVersion    = 1
        SupportedVersions = @(1)
        LegacyFormats     = @()
    }
    ErrorEnvelope = [PSCustomObject]@{
        CurrentVersion    = 1
        SupportedVersions = @(1)
        LegacyFormats     = @('UnversionedJson')
    }
    SurfaceBaseline = [PSCustomObject]@{
        CurrentVersion    = 1
        SupportedVersions = @(1)
        LegacyFormats     = @()
    }
    DefenderSnapshot = [PSCustomObject]@{
        CurrentVersion    = 1
        SupportedVersions = @(1)
        LegacyFormats     = @()
    }
    StructuredLogEntry = [PSCustomObject]@{
        CurrentVersion    = 1
        SupportedVersions = @(1)
        LegacyFormats     = @('UnversionedJsonl')
    }
    SafetyTripwireEntry = [PSCustomObject]@{
        CurrentVersion    = 1
        SupportedVersions = @(1)
        LegacyFormats     = @('UnversionedJsonl')
    }
    SupportBundleSummary = [PSCustomObject]@{
        CurrentVersion    = 1
        SupportedVersions = @(1)
        LegacyFormats     = @('UnversionedJson')
    }
    SupportBundleHealth = [PSCustomObject]@{
        CurrentVersion    = 1
        SupportedVersions = @(1)
        LegacyFormats     = @('UnversionedJson')
    }
    SupportBundleComponents = [PSCustomObject]@{
        CurrentVersion    = 1
        SupportedVersions = @(1)
        LegacyFormats     = @('UnversionedJson')
    }
    SupportBundleEvents = [PSCustomObject]@{
        CurrentVersion    = 1
        SupportedVersions = @(1)
        LegacyFormats     = @('UnversionedJson')
    }
    ReleaseMetadata = [PSCustomObject]@{
        CurrentVersion    = 1
        SupportedVersions = @(1)
        LegacyFormats     = @('UnversionedJson')
    }
}

function Get-DefenderArtifactSchema {
    param([Parameter(Mandatory)][string]$Name)

    if (-not $script:DefenderArtifactSchemas.Contains($Name)) {
        throw "Unknown DisableDefender artifact schema '$Name'."
    }
    return $script:DefenderArtifactSchemas[$Name]
}

function Get-DefenderArtifactSchemaVersion {
    param([Parameter(Mandatory)][string]$Name)

    return [int](Get-DefenderArtifactSchema -Name $Name).CurrentVersion
}

function Assert-DefenderArtifactSchemaVersion {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$InputObject
    )

    $schema = Get-DefenderArtifactSchema -Name $Name
    $hasVersion = $false
    $rawVersion = $null
    if ($InputObject -is [System.Collections.IDictionary]) {
        $hasVersion = $InputObject.Contains('SchemaVersion')
        if ($hasVersion) { $rawVersion = $InputObject['SchemaVersion'] }
    } else {
        $hasVersion = $InputObject.PSObject.Properties.Name -contains 'SchemaVersion'
        if ($hasVersion) { $rawVersion = $InputObject.SchemaVersion }
    }
    if (-not $hasVersion) {
        throw "$Name artifact is missing SchemaVersion. Preserve it and use a supported migration path."
    }

    $version = 0
    if (-not [int]::TryParse(
            [string]$rawVersion,
            [Globalization.NumberStyles]::Integer,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$version) -or
        $version -lt 1) {
        throw "$Name artifact has an invalid SchemaVersion: $rawVersion"
    }
    if (@($schema.SupportedVersions) -contains $version) {
        return $version
    }
    if ($version -gt [int]$schema.CurrentVersion) {
        throw (
            "$Name artifact uses unsupported future schema $version; this release supports " +
            "$($schema.CurrentVersion). Upgrade DisableDefender before using this artifact.")
    }
    throw (
        "$Name artifact uses unsupported schema $version. Preserve the " +
        'original and migrate it with a compatible DisableDefender release.')
}

function Resolve-DefenderArtifactSchemaVersion {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$InputObject,
        [string]$LegacyFormat
    )

    $hasVersion = if ($InputObject -is [System.Collections.IDictionary]) {
        $InputObject.Contains('SchemaVersion')
    } else {
        $InputObject.PSObject.Properties.Name -contains 'SchemaVersion'
    }
    if ($hasVersion) {
        return [PSCustomObject][ordered]@{
            Version = Assert-DefenderArtifactSchemaVersion -Name $Name `
                -InputObject $InputObject
            Legacy  = $false
            Format  = 'Versioned'
        }
    }

    $schema = Get-DefenderArtifactSchema -Name $Name
    if (-not [string]::IsNullOrWhiteSpace($LegacyFormat) -and
        @($schema.LegacyFormats) -contains $LegacyFormat) {
        return [PSCustomObject][ordered]@{
            Version = 0
            Legacy  = $true
            Format  = $LegacyFormat
        }
    }
    Assert-DefenderArtifactSchemaVersion -Name $Name `
        -InputObject $InputObject | Out-Null
}

function Read-DefenderJsonArtifact {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path,
        [string]$LegacyFormat,
        [ValidateRange(1, 16777216)][int]$MaximumBytes = 16777216
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    if ($item.Length -gt $MaximumBytes) {
        throw "$Name artifact exceeds the $MaximumBytes byte limit: $fullPath"
    }
    $document = Get-Content -Raw -LiteralPath $fullPath -ErrorAction Stop |
        ConvertFrom-Json -ErrorAction Stop
    Resolve-DefenderArtifactSchemaVersion -Name $Name `
        -InputObject $document -LegacyFormat $LegacyFormat | Out-Null
    return $document
}

function Write-DefenderJsonArtifactAtomic {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$InputObject,
        [ValidateRange(2, 32)][int]$Depth = 12,
        [ValidateRange(1, 16777216)][int]$MaximumBytes = 16777216
    )

    Assert-DefenderArtifactSchemaVersion -Name $Name `
        -InputObject $InputObject | Out-Null
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $directory = [System.IO.Path]::GetDirectoryName($fullPath)
    if (-not [System.IO.Directory]::Exists($directory)) {
        throw "$Name artifact directory does not exist: $directory"
    }

    $json = $InputObject | ConvertTo-Json -Depth $Depth
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($json)
    if ($bytes.Length -gt $MaximumBytes) {
        throw "$Name artifact exceeds the $MaximumBytes byte limit."
    }

    $temporaryPath = Join-Path $directory (
        '.{0}.{1:N}.tmp' -f [System.IO.Path]::GetFileName($fullPath),
        [guid]::NewGuid())
    $backupPath = Join-Path $directory (
        '.{0}.{1:N}.bak' -f [System.IO.Path]::GetFileName($fullPath),
        [guid]::NewGuid())
    $verifiedWrite = $false
    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $temporaryPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::Read)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null

        if ([System.IO.File]::Exists($fullPath)) {
            [System.IO.File]::Replace(
                $temporaryPath,
                $fullPath,
                $backupPath,
                $true)
        } else {
            [System.IO.File]::Move($temporaryPath, $fullPath)
        }

        $verified = Read-DefenderJsonArtifact -Name $Name -Path $fullPath `
            -MaximumBytes $MaximumBytes
        if ([int]$verified.SchemaVersion -ne
            [int](Get-DefenderArtifactSchemaVersion -Name $Name)) {
            throw "$Name artifact readback schema did not match the write."
        }
        $verifiedWrite = $true
        return $fullPath
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        Remove-Item -LiteralPath $temporaryPath -Force `
            -ErrorAction SilentlyContinue
        if ($verifiedWrite) {
            Remove-Item -LiteralPath $backupPath -Force `
                -ErrorAction SilentlyContinue
        }
    }
}

function Get-DefenderArtifactSchemaCatalog {
    return @($script:DefenderArtifactSchemas.GetEnumerator() | ForEach-Object {
        [PSCustomObject][ordered]@{
            Name              = [string]$_.Key
            CurrentVersion    = [int]$_.Value.CurrentVersion
            SupportedVersions = @($_.Value.SupportedVersions)
            LegacyFormats     = @($_.Value.LegacyFormats)
        }
    })
}
