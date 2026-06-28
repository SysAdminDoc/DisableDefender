# ---------------------------------------------------------------------------
# Firewall safety guard (critical vs touch-refuse distinction)
# ---------------------------------------------------------------------------
function Test-FirewallIntact {
    $bad = @()
    foreach ($s in $script:CriticalFirewallServices) {
        $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
        if ($null -eq $svc) { continue }
        if ($svc.StartType -eq 'Disabled') { $bad += "$s is Disabled" }
    }
    try {
        $profiles = Get-NetFirewallProfile -ErrorAction Stop
        foreach ($p in $profiles) {
            if (-not $p.Enabled) { $bad += "Firewall profile $($p.Name) is off" }
        }
    } catch { $bad += "Get-NetFirewallProfile failed: $_" }
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
