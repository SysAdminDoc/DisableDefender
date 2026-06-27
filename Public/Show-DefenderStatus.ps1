function Show-DefenderStatus {
    <#
    .SYNOPSIS
        Displays the current Defender and firewall state in a formatted console view.
    .DESCRIPTION
        Calls Get-DefenderStatus and renders the result with color-coded output.
        Pass -Json to get a machine-readable JSON string instead.
    .PARAMETER Json
        Output as JSON instead of formatted console text.
    .EXAMPLE
        Show-DefenderStatus
    .EXAMPLE
        Show-DefenderStatus -Json
    #>
    [CmdletBinding()]
    param(
        [switch]$Json
    )

    if ($Json) {
        Get-DefenderStatus -Json
        return
    }

    $s = Get-DefenderStatus
    Write-Banner
    foreach ($k in $s.Keys) {
        $v = $s[$k]
        $c = 'Gray'
        if ($v -is [bool]) { $c = if ($v) { 'Green' } else { 'DarkGray' } }
        elseif ($v -is [string] -and $v -match 'Running') { $c = 'Yellow' }
        elseif ($v -is [string] -and $v -match 'Stopped|Disabled|not present') { $c = 'DarkGray' }
        Write-Host (" {0,-32} {1}" -f $k, $v) -ForegroundColor $c
    }
    Write-Host ''
}
