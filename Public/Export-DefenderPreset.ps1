function Export-DefenderPreset {
    <#
    .SYNOPSIS
        Exports the supported cloud-sample-submission preset definition.
    .DESCRIPTION
        Writes a strict, versioned JSON preset. The preset disables the
        existing local Defender runtime preference catalog while preserving
        MAPS lookups and safe sample submission. It is intentionally narrow;
        arbitrary privacy settings are not accepted.
    .PARAMETER OutputPath
        Destination JSON file. The parent directory must already exist.
    .PARAMETER Preset
        Supported preset name. The current release supports CloudSampleSubmission.
    .PARAMETER Force
        Replace an existing output file.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$OutputPath,
        [ValidateSet('CloudSampleSubmission')]
        [string]$Preset = 'CloudSampleSubmission',
        [switch]$Force
    )

    $fullPath = [System.IO.Path]::GetFullPath($OutputPath)
    if ((Test-Path -LiteralPath $fullPath) -and -not $Force) {
        throw "Preset output already exists: $fullPath. Use -Force to replace it."
    }
    $document = New-DefenderPresetDocument -Preset $Preset
    if (-not $PSCmdlet.ShouldProcess($fullPath, "Export $Preset preset")) {
        return [PSCustomObject][ordered]@{
            Preset     = $Preset
            OutputPath = $fullPath
            Written    = $false
        }
    }

    Write-DefenderJsonArtifactAtomic -Name DefenderPreset `
        -Path $fullPath -InputObject $document -Depth 12 | Out-Null
    Write-Log "Defender preset exported: $fullPath ($Preset)" OK
    return [PSCustomObject][ordered]@{
        Preset       = $Preset
        OutputPath   = $fullPath
        Written      = $true
        SchemaVersion = $document.SchemaVersion
    }
}
