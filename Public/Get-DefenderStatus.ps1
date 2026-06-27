function Get-DefenderStatus {
    <#
    .SYNOPSIS
        Returns an ordered dictionary of current Defender and firewall state.
    .DESCRIPTION
        Queries Get-MpComputerStatus, Win32_DeviceGuard, Defender services, and
        firewall profiles. Safe to call at any time; read-only.
    .PARAMETER Json
        If specified, outputs the result as a JSON string instead of a dictionary.
    .EXAMPLE
        Get-DefenderStatus
    .EXAMPLE
        Get-DefenderStatus -Json
    #>
    [CmdletBinding()]
    param(
        [switch]$Json
    )

    $o = [ordered]@{}
    try {
        $s = Get-MpComputerStatus -ErrorAction Stop
        $o.AntivirusEnabled          = $s.AntivirusEnabled
        $o.RealTimeProtectionEnabled = $s.RealTimeProtectionEnabled
        $o.IsTamperProtected         = $s.IsTamperProtected
        $o.AMServiceEnabled          = $s.AMServiceEnabled
        $o.OnAccessProtection        = $s.OnAccessProtectionEnabled
        $o.BehaviorMonitor           = $s.BehaviorMonitorEnabled
        $o.IoavProtection            = $s.IoavProtectionEnabled
        $o.AntispywareEnabled        = $s.AntispywareEnabled
        if ($s.AMProductVersion)     { $o.PlatformVersion = $s.AMProductVersion }
        if ($s.AMRunningMode)        { $o.RunningMode = $s.AMRunningMode }
    } catch {
        $o.AMQuery = "Get-MpComputerStatus failed: $($_.Exception.Message)"
    }
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $o.WindowsBuild = "$($os.Caption) $($os.Version)"
    } catch {}
    # VBS / HVCI / Credential Guard (read-only reporting -- never modified)
    try {
        $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace 'root\Microsoft\Windows\DeviceGuard' -ErrorAction Stop
        $o.VBS_Enabled = ($dg.VirtualizationBasedSecurityStatus -eq 2)
        $o.HVCI_Enabled = ($dg.SecurityServicesRunning -contains 1)
        $o.CredentialGuard_Enabled = ($dg.SecurityServicesRunning -contains 2)
    } catch {
        $o.VBS_Query = 'DeviceGuard WMI not available'
    }
    foreach ($s in ($script:DefenderServices + $script:MDEServices)) {
        $sv = Get-Service -Name $s -ErrorAction SilentlyContinue
        if ($sv) { $o["svc_$s"] = "$($sv.Status) / $($sv.StartType)" } else { $o["svc_$s"] = 'not present' }
    }
    foreach ($f in $script:CriticalFirewallServices) {
        $sv = Get-Service -Name $f -ErrorAction SilentlyContinue
        if ($sv) { $o["fw_$f"] = "$($sv.Status) / $($sv.StartType)" }
    }
    try {
        $fwp = Get-NetFirewallProfile -ErrorAction Stop
        foreach ($p in $fwp) { $o["firewall_$($p.Name)"] = $p.Enabled }
    } catch {}

    if ($Json) {
        return ([PSCustomObject]$o | ConvertTo-Json -Depth 3)
    }
    return $o
}
