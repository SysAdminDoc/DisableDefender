# ---------------------------------------------------------------------------
# Firewall safety guard (critical vs touch-refuse distinction)
# ---------------------------------------------------------------------------
function Test-FirewallIntact {
    $status = Get-DefenderFirewallStatus
    $bad = @($status.Issues)
    return ,$bad
}

function Assert-FirewallSafety {
    param([string]$Stage = 'pre')
    $issues = Test-FirewallIntact
    if ($issues.Count -gt 0) {
        Write-Log "Firewall issues at $Stage stage:" WARN
        foreach ($i in $issues) { Write-Log "  - $i" WARN }
        throw "Firewall integrity broken at $Stage stage. Aborting."
    } else {
        Write-Log "Firewall intact at $Stage stage." OK
    }
}
