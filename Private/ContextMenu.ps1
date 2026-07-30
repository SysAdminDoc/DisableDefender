# ---------------------------------------------------------------------------
# Phase: Context menu cleanup (Remove mode only)
# ---------------------------------------------------------------------------
function Remove-DefenderContextMenu {
    Write-Log "Removing Defender context menu entries..." INFO
    $result = New-DefenderActionResult -Name 'ContextMenu:Remove' -Simulation:$WhatIfPreference
    $shellPaths = @(
        'HKLM:\SOFTWARE\Classes\*\shellex\ContextMenuHandlers\EPP',
        'HKLM:\SOFTWARE\Classes\Directory\shellex\ContextMenuHandlers\EPP',
        'HKLM:\SOFTWARE\Classes\Drive\shellex\ContextMenuHandlers\EPP'
    )
    foreach ($p in $shellPaths) {
        $exists = Test-Path -LiteralPath $p
        if (-not $exists) {
            Add-DefenderEffect -Result $result -Target $p -Attempted $false -Changed $false `
                -Verified $true -Evidence @{ Expected = 'Absent'; Actual = 'Absent'; State = 'AlreadyCorrect' }
            continue
        }
        if ($WhatIfPreference) {
            Add-DefenderEffect -Result $result -Target $p -Required $false `
                -Attempted $false -Changed $false -Verified $false `
                -Evidence @{ Expected = 'Absent'; Actual = 'Present'; State = 'Simulation' }
            continue
        }
        try {
            Register-RegistryTreeUndo -Path $p -Phase 'ContextMenu'
            Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop
            $verified = -not (Test-Path -LiteralPath $p)
            $errors = if ($verified) { @() } else { @('Context-menu key remained after removal.') }
            Add-DefenderEffect -Result $result -Target $p -Attempted $true -Changed $verified `
                -Verified $verified -Evidence @{ Expected = 'Absent'; Actual = $(if ($verified) { 'Absent' } else { 'Present' }) } `
                -Errors $errors
            if ($verified) { Write-Log "Removed context menu: $p" DEBUG }
        } catch {
            Add-DefenderEffect -Result $result -Target $p -Attempted $true -Changed $false `
                -Verified $false -Evidence @{ Expected = 'Absent'; Actual = 'Unknown' } -Errors $_.Exception.Message
        }
    }
    $completed = Complete-DefenderActionResult -Result $result
    $level = if ($completed.Succeeded) { 'OK' } else { 'WARN' }
    Write-Log "Context-menu removal result: attempted=$($completed.Attempted) changed=$($completed.Changed) verified=$($completed.Verified) errors=$(@($completed.Errors).Count)." $level
    return $completed
}

function Restore-DefenderContextMenu {
    Write-Log "Restoring Defender context menu entries..." INFO
    $result = New-DefenderActionResult -Name 'ContextMenu:Restore' -Simulation:$WhatIfPreference
    $eppGuid = '{09A47860-11B0-4DA5-AFA5-26D86198A780}'
    $shellPaths = @(
        'HKLM:\SOFTWARE\Classes\*\shellex\ContextMenuHandlers\EPP',
        'HKLM:\SOFTWARE\Classes\Directory\shellex\ContextMenuHandlers\EPP',
        'HKLM:\SOFTWARE\Classes\Drive\shellex\ContextMenuHandlers\EPP'
    )
    foreach ($p in $shellPaths) {
        $before = Get-DefenderRegistryValueState -Path $p -Name '(Default)'
        if ($before.Readable -and (Test-DefenderRegistryValue -State $before -Expected $eppGuid)) {
            Add-DefenderEffect -Result $result -Target $p -Attempted $false -Changed $false `
                -Verified $true -Evidence @{ Expected = $eppGuid; Actual = $before.Value; State = 'AlreadyCorrect' }
            continue
        }
        if ($WhatIfPreference) {
            Add-DefenderEffect -Result $result -Target $p -Required $false `
                -Attempted $false -Changed $false -Verified $false `
                -Evidence @{ Expected = $eppGuid; Actual = $before.Value; State = 'Simulation' }
            continue
        }
        try {
            if (-not $before.Readable) {
                throw "Could not read context-menu key: $($before.Error)"
            }
            if (-not $before.PathExists) {
                New-Item -Path $p -Force -ErrorAction Stop | Out-Null
            }
            New-ItemProperty -LiteralPath $p -Name '(Default)' -Value $eppGuid -Force `
                -ErrorAction Stop | Out-Null
            $after = Get-DefenderRegistryValueState -Path $p -Name '(Default)'
            $verified = Test-DefenderRegistryValue -State $after -Expected $eppGuid
            Add-DefenderEffect -Result $result -Target $p -Attempted $true -Changed $verified `
                -Verified $verified -Evidence @{ Expected = $eppGuid; Actual = $after.Value } `
                -Errors $(if ($verified) { @() } else { @('Context-menu registration did not converge.') })
        } catch {
            Add-DefenderEffect -Result $result -Target $p -Attempted $true -Changed $false `
                -Verified $false -Evidence @{ Expected = $eppGuid; Actual = 'Unknown' } -Errors $_.Exception.Message
        }
    }
    $completed = Complete-DefenderActionResult -Result $result
    $level = if ($completed.Succeeded) { 'OK' } else { 'WARN' }
    Write-Log "Context-menu restore result: attempted=$($completed.Attempted) changed=$($completed.Changed) verified=$($completed.Verified) errors=$(@($completed.Errors).Count)." $level
    return $completed
}
