# ---------------------------------------------------------------------------
# Policy registry writer with refuse-list guard
# ---------------------------------------------------------------------------
function Set-RegValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [ValidateSet('DWord','QWord','String','ExpandString','MultiString','Binary')]
        [string]$Type = 'DWord'
    )
    foreach ($p in $script:RefuseTouchRegPaths) {
        if ($Path -like "$p*") {
            Write-Log "REFUSED firewall path: $Path" ERROR
            return
        }
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    Write-Log "Set $Path\$Name = $Value ($Type)" DEBUG
}
