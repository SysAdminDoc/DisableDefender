# ---------------------------------------------------------------------------
# Deterministic presentation-resource loading.
# Machine-readable result keys remain English and stable; only human text uses
# this catalog. Missing translations fall back to en-US instead of failing a
# privileged operation.
# ---------------------------------------------------------------------------

$script:PresentationResourceRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'Resources'
$script:PresentationCatalogCache = @{}
$script:PresentationCulture = 'en-US'
$script:PresentationDirection = 'LeftToRight'

function Import-DefenderPresentationCatalog {
    param(
        [Parameter(Mandatory)][string]$Culture
    )

    if ($script:PresentationCatalogCache.ContainsKey($Culture)) {
        return $script:PresentationCatalogCache[$Culture]
    }

    $path = Join-Path $script:PresentationResourceRoot "$Culture.psd1"
    if (-not (Test-Path -LiteralPath $path)) {
        if ($Culture -ne 'en-US') {
            return (Import-DefenderPresentationCatalog -Culture 'en-US')
        }
        throw "Presentation resource catalog not found: $path"
    }

    try {
        $document = Import-PowerShellDataFile -LiteralPath $path
    } catch {
        if ($Culture -ne 'en-US') {
            return (Import-DefenderPresentationCatalog -Culture 'en-US')
        }
        throw "Presentation resource catalog could not be loaded: $($_.Exception.Message)"
    }

    if (-not $document.ContainsKey('Culture') -or
        -not $document.ContainsKey('Direction') -or
        -not $document.ContainsKey('Strings') -or
        $document.Strings -isnot [System.Collections.IDictionary]) {
        if ($Culture -ne 'en-US') {
            return (Import-DefenderPresentationCatalog -Culture 'en-US')
        }
        throw "Presentation resource catalog is malformed: $path"
    }

    $catalog = [PSCustomObject][ordered]@{
        Culture   = [string]$document.Culture
        Direction = [string]$document.Direction
        Strings   = $document.Strings
    }
    $script:PresentationCatalogCache[$Culture] = $catalog
    return $catalog
}

function Resolve-DefenderPresentationCulture {
    param([string]$Culture)

    if ([string]::IsNullOrWhiteSpace($Culture)) { return 'en-US' }
    if ($Culture -eq 'qps-ploc') { return $Culture }
    try {
        return [Globalization.CultureInfo]::GetCultureInfo($Culture).Name
    } catch {
        return $Culture
    }
}

function Set-DefenderPresentationCulture {
    <#
    .SYNOPSIS
        Selects the human-facing presentation catalog for this module session.
    .PARAMETER Culture
        Resource culture. Unknown cultures deterministically fall back to en-US.
    #>
    [CmdletBinding()]
    param(
        [string]$Culture = 'en-US'
    )

    $requested = Resolve-DefenderPresentationCulture -Culture $Culture
    $catalog = Import-DefenderPresentationCatalog -Culture $requested
    $script:PresentationCulture = $requested
    $script:PresentationDirection = if ($catalog.Direction -eq 'RightToLeft') {
        'RightToLeft'
    } else {
        'LeftToRight'
    }

    return [PSCustomObject][ordered]@{
        Requested = $requested
        Culture   = $catalog.Culture
        Direction = $script:PresentationDirection
        Fallback  = ($catalog.Culture -ne $requested)
    }
}

function Get-DefenderPresentationCulture {
    [CmdletBinding()]
    param()
    return $script:PresentationCulture
}

function Get-DefenderPresentationDirection {
    [CmdletBinding()]
    param()
    return $script:PresentationDirection
}

function ConvertTo-DefenderPseudoLocalizedText {
    param([Parameter(Mandatory)][string]$Text)

    # Deliberately preserve privileged action names and machine tokens while
    # expanding the visible boundary so clipping is obvious in screenshots.
    return "[[$Text]]"
}

function Get-DefenderPresentationString {
    <#
    .SYNOPSIS
        Resolves a human-facing resource string with deterministic fallback.
    .PARAMETER Id
        Stable resource identifier, never emitted as a JSON/result key.
    .PARAMETER ArgumentList
        Values formatted with invariant culture.
    .PARAMETER Culture
        Optional one-shot culture override for tests and presentation hosts.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [object[]]$ArgumentList,
        [string]$Culture
    )

    $requested = if ([string]::IsNullOrWhiteSpace($Culture)) {
        $script:PresentationCulture
    } else {
        Resolve-DefenderPresentationCulture -Culture $Culture
    }
    $catalog = Import-DefenderPresentationCatalog -Culture $requested
    $fallback = Import-DefenderPresentationCatalog -Culture 'en-US'
    $text = $null
    if ($catalog.Strings.ContainsKey($Id)) {
        $text = [string]$catalog.Strings[$Id]
    } elseif ($fallback.Strings.ContainsKey($Id)) {
        $text = [string]$fallback.Strings[$Id]
    } else {
        $text = "[$Id]"
    }

    if ($null -ne $ArgumentList -and $ArgumentList.Count -gt 0) {
        try {
            $text = [string]::Format(
                [Globalization.CultureInfo]::InvariantCulture,
                $text,
                [object[]]$ArgumentList)
        } catch {
            throw "Presentation resource '$Id' has invalid format arguments: $($_.Exception.Message)"
        }
    }
    if ($requested -eq 'qps-ploc') {
        $text = ConvertTo-DefenderPseudoLocalizedText -Text $text
    }
    return $text
}

Set-DefenderPresentationCulture -Culture 'en-US' | Out-Null
