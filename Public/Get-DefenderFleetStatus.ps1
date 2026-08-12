function Get-DefenderFleetStatus {
    <#
    .SYNOPSIS
        Collects read-only Defender status from multiple WinRM targets.
    .DESCRIPTION
        Fleet collection never invokes a DisableDefender mutation command. It
        requires an explicit -AllowRemoting opt-in because the target list is
        sent to remote computers through WinRM.
    .PARAMETER ComputerName
        One or more computer names accepted by Invoke-Command.
    .PARAMETER AllowRemoting
        Required explicit opt-in for remote status collection.
    .PARAMETER Credential
        Optional credential used for the WinRM connection.
    .PARAMETER Authentication
        WinRM authentication mechanism. Default delegates to the local
        session configuration.
    .PARAMETER UseSSL
        Use WinRM over HTTPS.
    .PARAMETER Json
        Return the complete fleet envelope as JSON text.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string[]]$ComputerName,
        [switch]$AllowRemoting,
        [PSCredential]$Credential,
        [ValidateSet('Default','Negotiate','Kerberos','CredSSP','Basic','Digest')]
        [string]$Authentication = 'Default',
        [switch]$UseSSL,
        [switch]$Json
    )

    if (-not $AllowRemoting) {
        throw 'Fleet status collection is disabled by default. Use -AllowRemoting to opt in to WinRM.'
    }

    $targets = @($ComputerName | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { [string]$_ } | Select-Object -Unique)
    if ($targets.Count -eq 0) {
        throw 'At least one non-empty -ComputerName value is required.'
    }

    $remoteProbe = {
        $status = [ordered]@{}
        try {
            $mp = Get-MpComputerStatus -ErrorAction Stop
            $status.AntivirusEnabled = $mp.AntivirusEnabled
            $status.RealTimeProtectionEnabled = $mp.RealTimeProtectionEnabled
            $status.IsTamperProtected = $mp.IsTamperProtected
            $status.AMServiceEnabled = $mp.AMServiceEnabled
            $status.OnAccessProtection = $mp.OnAccessProtectionEnabled
            $status.BehaviorMonitor = $mp.BehaviorMonitorEnabled
            $status.IoavProtection = $mp.IoavProtectionEnabled
            $status.AntispywareEnabled = $mp.AntispywareEnabled
            $status.PlatformVersion = $mp.AMProductVersion
            $status.RunningMode = $mp.AMRunningMode
        } catch {
            $status.AMQuery = "Get-MpComputerStatus failed: $($_.Exception.Message)"
        }
        try {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            $status.WindowsBuild = "$($os.Caption) $($os.Version)"
            $status.WindowsDisplayVersion = [string]$os.Caption
        } catch {
            $status.WindowsBuildQuery = $_.Exception.Message
        }
        foreach ($serviceName in @('WinDefend','WdNisSvc','Sense','mpssvc','BFE')) {
            try {
                $service = Get-Service -Name $serviceName -ErrorAction Stop
                $status["svc_$serviceName"] = "$($service.Status) / $($service.StartType)"
            } catch {
                $status["svc_$serviceName"] = 'not present'
            }
        }
        try {
            $profiles = @(Get-NetFirewallProfile -ErrorAction Stop)
            foreach ($firewallProfile in $profiles) {
                $status["firewall_$($firewallProfile.Name)"] = [bool]$firewallProfile.Enabled
            }
        } catch {
            $status.FirewallQuery = $_.Exception.Message
        }
        [PSCustomObject][ordered]@{
            ComputerName = [string]$env:COMPUTERNAME
            CollectedAt  = (Get-Date).ToString('o')
            Status       = [PSCustomObject]$status
        }
    }

    $records = foreach ($target in $targets) {
        $invoke = @{
            ComputerName = $target
            ScriptBlock  = $remoteProbe
            ErrorAction  = 'Stop'
        }
        if ($Credential) { $invoke.Credential = $Credential }
        if ($Authentication -ne 'Default') { $invoke.Authentication = $Authentication }
        if ($UseSSL) { $invoke.UseSSL = $true }

        try {
            $remote = @(Invoke-Command @invoke)
            if ($remote.Count -eq 0) {
                throw 'WinRM returned no status payload.'
            }
            $payload = $remote[-1]
            [PSCustomObject][ordered]@{
                ComputerName = $target
                Succeeded    = $true
                CollectedAt  = [string]$payload.CollectedAt
                Status       = $payload.Status
                Error        = $null
            }
        } catch {
            [PSCustomObject][ordered]@{
                ComputerName = $target
                Succeeded    = $false
                CollectedAt  = $null
                Status       = $null
                Error        = $_.Exception.Message
            }
        }
    }

    $envelope = [PSCustomObject][ordered]@{
        SchemaVersion = 1
        Mode          = 'FleetStatus'
        Generated     = (Get-Date).ToString('o')
        Summary       = [PSCustomObject][ordered]@{
            Total     = $records.Count
            Succeeded = @($records | Where-Object Succeeded).Count
            Failed    = @($records | Where-Object { -not $_.Succeeded }).Count
        }
        Results       = @($records)
    }
    if ($Json) {
        return ($envelope | ConvertTo-Json -Depth 8)
    }
    return $envelope
}
