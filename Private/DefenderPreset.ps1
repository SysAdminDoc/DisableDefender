# ---------------------------------------------------------------------------
# Narrow, versioned portable preset support.
# This is intentionally not a general privacy-settings catalog.
# ---------------------------------------------------------------------------

$script:DefenderPresetFormat = 'DisableDefender.Preset'
$script:DefenderPresetName = 'CloudSampleSubmission'

function Get-DefenderCloudSampleSubmissionPreset {
    $preferences = [ordered]@{}
    foreach ($preference in Get-MpRuntimePreferenceCatalog) {
        $value = switch ($preference.Name) {
            'MAPSReporting'       { 'Advanced' }
            'SubmitSamplesConsent' { 'SendSafeSamples' }
            default               { $preference.DisableValue }
        }
        $preferences[$preference.Name] = $value
    }

    $exclusions = [ordered]@{}
    foreach ($exclusion in Get-MpRuntimeExclusionCatalog) {
        $exclusions[$exclusion.Parameter] = @($exclusion.Values)
    }

    return [PSCustomObject][ordered]@{
        Name        = $script:DefenderPresetName
        Preferences = $preferences
        Exclusions  = $exclusions
    }
}

function New-DefenderPresetDocument {
    param(
        [Parameter(Mandatory)][string]$Preset,
        [string]$Version = $script:Version
    )

    if ($Preset -ne $script:DefenderPresetName) {
        throw "Unsupported Defender preset '$Preset'. Supported preset: $script:DefenderPresetName."
    }
    $definition = Get-DefenderCloudSampleSubmissionPreset
    return [ordered]@{
        SchemaVersion = Get-DefenderArtifactSchemaVersion -Name DefenderPreset
        Format        = $script:DefenderPresetFormat
        Preset        = $definition.Name
        Created       = (Get-Date).ToString('o')
        Version       = $Version
        Preferences   = $definition.Preferences
        Exclusions    = $definition.Exclusions
    }
}

function Test-DefenderPresetValue {
    param(
        [AllowNull()]$Actual,
        [AllowNull()]$Expected
    )
    if ($Actual -is [System.Array] -or $Expected -is [System.Array]) {
        return ((ConvertTo-Json @($Actual) -Compress -Depth 8) -ceq
            (ConvertTo-Json @($Expected) -Compress -Depth 8))
    }
    return ([string]$Actual -ceq [string]$Expected)
}

function Read-DefenderPresetDocument {
    param([Parameter(Mandatory)][string]$Path)

    $document = Read-DefenderJsonArtifact -Name DefenderPreset -Path $Path
    $requiredProperties = @(
        'SchemaVersion', 'Format', 'Preset', 'Created', 'Version',
        'Preferences', 'Exclusions'
    )
    $actualProperties = @($document.PSObject.Properties.Name)
    foreach ($property in $requiredProperties) {
        if ($actualProperties -notcontains $property) {
            throw "Defender preset is missing required property '$property': $Path"
        }
    }
    foreach ($property in $actualProperties) {
        if ($requiredProperties -notcontains $property) {
            throw "Defender preset contains unsupported property '$property': $Path"
        }
    }
    if ([string]$document.Format -cne $script:DefenderPresetFormat) {
        throw "Unsupported Defender preset format '$($document.Format)'."
    }
    if ([string]$document.Preset -cne $script:DefenderPresetName) {
        throw "Unsupported Defender preset '$($document.Preset)'. Supported preset: $script:DefenderPresetName."
    }

    $definition = Get-DefenderCloudSampleSubmissionPreset
    foreach ($section in @('Preferences', 'Exclusions')) {
        $expectedSection = $definition.$section
        $actualSection = $document.$section
        if ($null -eq $actualSection) {
            throw "Defender preset '$section' section is missing."
        }
        $actualNames = @($actualSection.PSObject.Properties.Name)
        foreach ($name in $expectedSection.Keys) {
            if ($actualNames -notcontains $name) {
                throw "Defender preset is missing supported $section value '$name'."
            }
            if (-not (Test-DefenderPresetValue -Actual $actualSection.$name -Expected $expectedSection[$name])) {
                throw "Defender preset value for '$name' is not the supported CloudSampleSubmission value."
            }
        }
        foreach ($name in $actualNames) {
            if (-not $expectedSection.Contains($name)) {
                throw "Defender preset contains unsupported $section value '$name'."
            }
        }
    }
    return $document
}
