function Get-DefenderComponentDefinition {
    $definitions = New-Object System.Collections.ArrayList
    [void]$definitions.Add([ordered]@{ Name = 'MsMpEng'; Service = 'WinDefend'; Kind = 'Process'; Detail = 'Antimalware engine process'; Protection = $true })
    [void]$definitions.Add([ordered]@{ Name = 'WdFilter'; Service = 'WdFilter'; Kind = 'Driver'; Detail = 'Defender minifilter driver'; Protection = $true })
    [void]$definitions.Add([ordered]@{ Name = 'WdBoot'; Service = 'WdBoot'; Kind = 'Driver'; Detail = 'Early-launch antimalware driver'; Protection = $true })
    [void]$definitions.Add([ordered]@{ Name = 'WdNisDrv'; Service = 'WdNisDrv'; Kind = 'Driver'; Detail = 'Network inspection driver'; Protection = $true })

    $remaining = @(
        @{ Name = 'WdNisSvc'; Service = 'WdNisSvc'; Kind = 'Service'; Detail = 'Network inspection service' }
        @{ Name = 'MDCoreSvc'; Service = 'MDCoreSvc'; Kind = 'Service'; Detail = 'Defender core service' }
        @{ Name = 'MDDlpSvc'; Service = 'MDDlpSvc'; Kind = 'Service'; Detail = 'Defender DLP service' }
        @{ Name = 'MsSecFlt'; Service = 'MsSecFlt'; Kind = 'Driver'; Detail = 'Microsoft Security filter' }
        @{ Name = 'MsSecCore'; Service = 'MsSecCore'; Kind = 'Driver'; Detail = 'Microsoft Security core' }
        @{ Name = 'SgrmAgent'; Service = 'SgrmAgent'; Kind = 'Service'; Detail = 'System Guard Runtime Monitor agent' }
        @{ Name = 'SgrmBroker'; Service = 'SgrmBroker'; Kind = 'Service'; Detail = 'System Guard Runtime Monitor broker' }
        @{ Name = 'SecurityHealthService'; Service = 'SecurityHealthService'; Kind = 'Service'; Detail = 'Windows Security UI backend' }
        @{ Name = 'wscsvc'; Service = 'wscsvc'; Kind = 'Service'; Detail = 'Security Center notifications' }
        @{ Name = 'webthreat'; Service = 'webthreat'; Kind = 'Service'; Detail = 'SmartScreen web threat service' }
        @{ Name = 'webthreatdefsvc'; Service = 'webthreatdefsvc'; Kind = 'Service'; Detail = 'Web Threat Defense service' }
        @{ Name = 'webthreatdefusersvc'; Service = 'webthreatdefusersvc'; Kind = 'Service'; Detail = 'Per-user Web Threat Defense service' }
        @{ Name = 'Sense'; Service = 'Sense'; Kind = 'MDE'; Detail = 'Defender for Endpoint sensor' }
    )

    foreach ($item in $remaining) {
        [void]$definitions.Add([ordered]@{
            Name       = $item.Name
            Service    = $item.Service
            Kind       = $item.Kind
            Detail     = $item.Detail
            Protection = $false
        })
    }

    return @($definitions)
}

function Get-ComponentRegistryDword {
    param(
        [Parameter(Mandatory)][string]$Service,
        [Parameter(Mandatory)][string]$ValueName
    )

    $path = "HKLM:\SYSTEM\CurrentControlSet\Services\$Service"
    try {
        if (-not (Test-Path -LiteralPath $path)) { return $null }
        $property = Get-ItemProperty -LiteralPath $path -Name $ValueName -ErrorAction SilentlyContinue
        if ($null -eq $property -or $property.PSObject.Properties.Name -notcontains $ValueName) { return $null }
        return [int]$property.$ValueName
    } catch {
        return $null
    }
}

function Convert-ServiceStartValue {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return 'unknown' }
    switch ([int]$Value) {
        0 { return 'Boot' }
        1 { return 'System' }
        2 { return 'Automatic' }
        3 { return 'Manual' }
        4 { return 'Disabled' }
        default { return [string]$Value }
    }
}

function Convert-LaunchProtectedValue {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return 'absent' }
    switch ([int]$Value) {
        0 { return 'None' }
        1 { return 'Windows' }
        2 { return 'WindowsLight' }
        3 { return 'AntimalwareLight' }
        default { return "Unknown($Value)" }
    }
}

function Get-DriverRuntimeText {
    param([Parameter(Mandatory)][string]$Service)

    try {
        $driver = Get-CimInstance -ClassName Win32_SystemDriver -Filter "Name='$Service'" -ErrorAction Stop | Select-Object -First 1
        if ($driver) { return "$($driver.State) / $($driver.StartMode)" }
    } catch {}
    return $null
}

function Get-DefenderComponentStatus {
    <#
    .SYNOPSIS
        Returns Defender service, driver, and protected-launch component state for the GUI dashboard.
    .PARAMETER Json
        Emit JSON instead of objects.
    .EXAMPLE
        Get-DefenderComponentStatus
    .EXAMPLE
        Get-DefenderComponentStatus -Json
    #>
    [CmdletBinding()]
    param(
        [switch]$Json
    )

    $components = New-Object System.Collections.ArrayList
    foreach ($definition in Get-DefenderComponentDefinition) {
        $serviceName = $definition.Service
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        $startValue = Get-ComponentRegistryDword -Service $serviceName -ValueName 'Start'
        $startText = Convert-ServiceStartValue -Value $startValue
        $launchProtected = Convert-LaunchProtectedValue -Value (Get-ComponentRegistryDword -Service $serviceName -ValueName 'LaunchProtected')
        $expectedStart = if ($script:MDEServices -contains $serviceName) { 'Manual' } else { 'Disabled' }
        $status = if ($startText -eq 'unknown') { 'Unknown' } elseif ($startText -eq $expectedStart) { 'OK' } else { 'Drift' }
        $runtime = if ($service) { [string]$service.Status } else { 'missing' }
        $driverRuntime = if ($definition.Kind -eq 'Driver') { Get-DriverRuntimeText -Service $serviceName } else { $null }
        $pplStatus = if ($definition.Protection) {
            if ($launchProtected -eq 'absent') { 'Not configured' } else { $launchProtected }
        } else {
            'N/A'
        }

        [void]$components.Add([PSCustomObject][ordered]@{
            Name              = $definition.Name
            Service           = $serviceName
            Kind              = $definition.Kind
            ExpectedStart     = $expectedStart
            CurrentStart      = $startText
            RuntimeStatus     = $runtime
            DriverRuntime     = $driverRuntime
            PPLStatus         = $pplStatus
            LaunchProtected   = $launchProtected
            DisableTargetDrift = $status
            Detail            = $definition.Detail
        })
    }

    $knownServices = @(Get-KnownDefenderServiceNames)
    foreach ($serviceName in @(Get-DefenderLikeServices | Where-Object { $knownServices -notcontains $_ })) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        $startText = Convert-ServiceStartValue -Value (Get-ComponentRegistryDword -Service $serviceName -ValueName 'Start')
        $runtime = if ($service) { [string]$service.Status } else { 'registry-only' }
        [void]$components.Add([PSCustomObject][ordered]@{
            Name              = $serviceName
            Service           = $serviceName
            Kind              = 'UnknownService'
            ExpectedStart     = 'Review'
            CurrentStart      = $startText
            RuntimeStatus     = $runtime
            DriverRuntime     = $null
            PPLStatus         = 'Unknown'
            LaunchProtected   = Convert-LaunchProtectedValue -Value (Get-ComponentRegistryDword -Service $serviceName -ValueName 'LaunchProtected')
            DisableTargetDrift = 'Drift'
            Detail            = 'Unknown Defender-like service detected; review after Windows feature updates before reapplying Disable.'
        })
    }

    if ($Json) {
        return ($components | ConvertTo-Json -Depth 4)
    }
    return $components
}
