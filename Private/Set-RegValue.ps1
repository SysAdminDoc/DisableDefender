# ---------------------------------------------------------------------------
# Policy registry writer with refuse-list guard
# ---------------------------------------------------------------------------
function Get-DefenderRegistryValueState {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    try {
        if (-not (Test-Path -LiteralPath $Path -ErrorAction Stop)) {
            return [PSCustomObject]@{
                Readable   = $true
                PathExists = $false
                Exists     = $false
                Value      = $null
                Error      = $null
            }
        }

        try {
            $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
            return [PSCustomObject]@{
                Readable   = $true
                PathExists = $true
                Exists     = $true
                Value      = $item.$Name
                Error      = $null
            }
        } catch {
            if ($_.FullyQualifiedErrorId -match 'PropertyNotFound|PSArgumentException' -or
                $_.Exception.Message -match 'does not exist|cannot find.*property') {
                return [PSCustomObject]@{
                    Readable   = $true
                    PathExists = $true
                    Exists     = $false
                    Value      = $null
                    Error      = $null
                }
            }
            throw
        }
    } catch {
        return [PSCustomObject]@{
            Readable   = $false
            PathExists = $null
            Exists     = $null
            Value      = $null
            Error      = $_.Exception.Message
        }
    }
}

function Test-DefenderRegistryValue {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][AllowNull()]$Expected
    )

    if (-not $State.Readable -or -not $State.Exists) { return $false }
    if ($Expected -is [array] -or $State.Value -is [array]) {
        return ((ConvertTo-Json @($Expected) -Compress) -eq
            (ConvertTo-Json @($State.Value) -Compress))
    }
    return ([string]$State.Value -ceq [string]$Expected)
}

function Set-RegValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [ValidateSet('DWord','QWord','String','ExpandString','MultiString','Binary')]
        [string]$Type = 'DWord'
    )

    $result = New-DefenderActionResult -Name "Registry:$Path\$Name" -Simulation:$WhatIfPreference
    $target = "$Path\$Name"
    foreach ($p in $script:RefuseTouchRegPaths) {
        if ($Path -like "$p*") {
            Write-Log "REFUSED firewall path: $Path" ERROR
            Add-DefenderEffect -Result $result -Target $target -Attempted $false -Changed $false `
                -Verified $false -Evidence @{ RefusedPath = $Path } `
                -Errors "Refused protected Firewall registry path: $Path"
            return (Complete-DefenderActionResult -Result $result)
        }
    }

    $before = Get-DefenderRegistryValueState -Path $Path -Name $Name
    if (-not $before.Readable) {
        Add-DefenderEffect -Result $result -Target $target -Attempted $false -Changed $false `
            -Verified $false -Evidence @{ Expected = $Value; ReadError = $before.Error } `
            -Errors "Could not read current registry value: $($before.Error)"
        return (Complete-DefenderActionResult -Result $result)
    }

    if (Test-DefenderRegistryValue -State $before -Expected $Value) {
        Add-DefenderEffect -Result $result -Target $target -Attempted $false -Changed $false `
            -Verified $true -Evidence @{ Expected = $Value; Actual = $before.Value; State = 'AlreadyCorrect' }
        return (Complete-DefenderActionResult -Result $result)
    }

    if ($WhatIfPreference) {
        Write-Log "WhatIf: would set $target = $Value ($Type)" INFO
        Add-DefenderEffect -Result $result -Target $target -Attempted $false -Changed $false `
            -Verified $false -Required $false `
            -Evidence @{ Expected = $Value; Actual = $before.Value; State = 'Simulation' }
        return (Complete-DefenderActionResult -Result $result)
    }

    try {
        Register-RegistryValueUndo -Path $Path -Name $Name -Phase 'Policies'
        if (-not $before.PathExists) {
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type `
            -Force -ErrorAction Stop | Out-Null
    } catch {
        Add-DefenderEffect -Result $result -Target $target -Attempted $true -Changed $false `
            -Verified $false -Evidence @{ Expected = $Value; Actual = $before.Value } `
            -Errors $_.Exception.Message
        return (Complete-DefenderActionResult -Result $result)
    }

    $after = Get-DefenderRegistryValueState -Path $Path -Name $Name
    $verified = Test-DefenderRegistryValue -State $after -Expected $Value
    $errors = if ($verified) { @() } elseif (-not $after.Readable) {
        @("Could not verify registry value: $($after.Error)")
    } else {
        @("Registry value did not converge to expected value '$Value'.")
    }
    if ($verified) {
        Write-Log "Set $target = $Value ($Type) and verified." DEBUG
    } else {
        Write-Log "Registry verification failed for $target." WARN
    }
    Add-DefenderEffect -Result $result -Target $target -Attempted $true -Changed $verified `
        -Verified $verified -Evidence @{ Expected = $Value; Actual = $after.Value } -Errors $errors
    return (Complete-DefenderActionResult -Result $result)
}
