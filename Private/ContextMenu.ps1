# ---------------------------------------------------------------------------
# Phase: Context menu cleanup (Remove mode only)
# ---------------------------------------------------------------------------
function Remove-DefenderContextMenu {
    Write-Log "Removing Defender context menu entries..." INFO
    $shellPaths = @(
        'HKLM:\SOFTWARE\Classes\*\shellex\ContextMenuHandlers\EPP',
        'HKLM:\SOFTWARE\Classes\Directory\shellex\ContextMenuHandlers\EPP',
        'HKLM:\SOFTWARE\Classes\Drive\shellex\ContextMenuHandlers\EPP'
    )
    foreach ($p in $shellPaths) {
        if (Test-Path -LiteralPath $p) {
            Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
            Write-Log "Removed context menu: $p" DEBUG
        }
    }
    Write-Log "Context menu entries removed." OK
}

function Restore-DefenderContextMenu {
    Write-Log "Restoring Defender context menu entries..." INFO
    $eppGuid = '{09A47860-11B0-4DA5-AFA5-26D86198A780}'
    $shellPaths = @(
        'HKLM:\SOFTWARE\Classes\*\shellex\ContextMenuHandlers\EPP',
        'HKLM:\SOFTWARE\Classes\Directory\shellex\ContextMenuHandlers\EPP',
        'HKLM:\SOFTWARE\Classes\Drive\shellex\ContextMenuHandlers\EPP'
    )
    foreach ($p in $shellPaths) {
        if (-not (Test-Path -LiteralPath $p)) {
            New-Item -Path $p -Force -ErrorAction SilentlyContinue | Out-Null
        }
        New-ItemProperty -LiteralPath $p -Name '(Default)' -Value $eppGuid -Force -ErrorAction SilentlyContinue | Out-Null
    }
    Write-Log "Context menu entries restored." OK
}
