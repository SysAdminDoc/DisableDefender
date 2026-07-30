function Get-DefenderFirewallStatus {
    <#
    .SYNOPSIS
        Returns the read-only Windows Firewall integrity state used by every guard.
    .DESCRIPTION
        Verifies that mpssvc and BFE exist, are not disabled, and are running,
        and that the Domain, Private, and Public Firewall profiles exist and
        are enabled. This command never repairs or changes Firewall state.
    .EXAMPLE
        Get-DefenderFirewallStatus
    #>
    [CmdletBinding()]
    param()

    $issues = New-Object System.Collections.ArrayList
    $services = New-Object System.Collections.ArrayList
    foreach ($serviceName in $script:CriticalFirewallServices) {
        $service = $null
        $queryError = $null
        try {
            $service = Get-Service -Name $serviceName -ErrorAction Stop
        } catch {
            $queryError = $_.Exception.Message
        }

        if ($null -eq $service) {
            [void]$issues.Add("$serviceName is missing or unavailable")
            [void]$services.Add([PSCustomObject][ordered]@{
                Name       = $serviceName
                Present    = $false
                Status     = 'Unknown'
                StartType  = 'Unknown'
                Healthy    = $false
                QueryError = $queryError
            })
            continue
        }

        $status = [string]$service.Status
        $startType = [string]$service.StartType
        $serviceIssues = New-Object System.Collections.ArrayList
        if ([string]::IsNullOrWhiteSpace($startType)) {
            [void]$serviceIssues.Add('start type is unavailable')
        } elseif ($startType -eq 'Disabled') {
            [void]$serviceIssues.Add('is Disabled')
        }
        if ($status -ne 'Running') {
            [void]$serviceIssues.Add("is not running (Status=$status)")
        }
        foreach ($issue in $serviceIssues) {
            [void]$issues.Add("$serviceName $issue")
        }

        [void]$services.Add([PSCustomObject][ordered]@{
            Name       = $serviceName
            Present    = $true
            Status     = $status
            StartType  = $startType
            Healthy    = $serviceIssues.Count -eq 0
            QueryError = $null
        })
    }

    $profiles = New-Object System.Collections.ArrayList
    $profileQuery = @()
    $profileQueryError = $null
    try {
        $profileQuery = @(Get-NetFirewallProfile -ErrorAction Stop)
    } catch {
        $profileQueryError = $_.Exception.Message
    }

    foreach ($profileName in $script:CriticalFirewallProfiles) {
        $profileMatch = @($profileQuery | Where-Object { [string]$_.Name -eq $profileName } |
            Select-Object -First 1)
        if ($profileMatch.Count -eq 0) {
            $issue = if ($profileQueryError) {
                "Firewall profile $profileName could not be queried"
            } else {
                "Firewall profile $profileName is missing"
            }
            [void]$issues.Add($issue)
            [void]$profiles.Add([PSCustomObject][ordered]@{
                Name       = $profileName
                Present    = $false
                Enabled    = $null
                Healthy    = $false
                QueryError = $profileQueryError
            })
            continue
        }

        $enabled = [bool]$profileMatch[0].Enabled
        if (-not $enabled) {
            [void]$issues.Add("Firewall profile $profileName is off")
        }
        [void]$profiles.Add([PSCustomObject][ordered]@{
            Name       = $profileName
            Present    = $true
            Enabled    = $enabled
            Healthy    = $enabled
            QueryError = $null
        })
    }

    return [PSCustomObject][ordered]@{
        Healthy  = $issues.Count -eq 0
        Services = @($services)
        Profiles = @($profiles)
        Issues   = @($issues)
    }
}
