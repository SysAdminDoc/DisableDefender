function New-DefenderHealthItem {
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Expected,
        [Parameter(Mandatory)][AllowNull()]$Actual,
        [string]$Detail
    )

    $actualText = if ($null -eq $Actual) { 'unknown' } else { [string]$Actual }
    $status = if ($actualText -eq 'unknown') { 'Unknown' }
              elseif ($actualText -eq $Expected) { 'OK' }
              else { 'Drift' }

    return [PSCustomObject][ordered]@{
        Category = $Category
        Name     = $Name
        Expected = $Expected
        Actual   = $actualText
        Status   = $status
        Detail   = $Detail
    }
}

function Get-RegistryValueForHealth {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    try {
        if (-not (Test-Path -LiteralPath $Path)) { return 'absent' }
        $key = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($key.GetValueNames() -notcontains $Name) { return 'absent' }
        return $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    } catch {
        return $null
    }
}

function Get-ServiceStartForHealth {
    param(
        [Parameter(Mandatory)][string]$Service
    )

    $path = "HKLM:\SYSTEM\CurrentControlSet\Services\$Service"
    $map = @{
        '0' = 'Boot'
        '1' = 'System'
        '2' = 'Automatic'
        '3' = 'Manual'
        '4' = 'Disabled'
    }

    try {
        if (-not (Test-Path -LiteralPath $path)) { return 'missing' }
        $value = (Get-ItemProperty -LiteralPath $path -Name 'Start' -ErrorAction Stop).Start
        $key = [string][int]$value
        if ($map.ContainsKey($key)) { return $map[$key] }
        return [string]$value
    } catch {
        return $null
    }
}

function Get-ExpectedPolicyValues {
    return @(Get-DefenderPolicyCatalog)
}

function Add-FirewallHealthItems {
    param(
        [Parameter(Mandatory)]$Items
    )

    $firewall = Get-DefenderFirewallStatus
    foreach ($service in $firewall.Services) {
        $observed = if ($service.Present) {
            "$($service.Status) / $($service.StartType)"
        } else {
            'Missing or unavailable'
        }
        $actual = if ($service.Healthy) { 'Running / not Disabled' } else { $observed }
        [void]$Items.Add((New-DefenderHealthItem -Category 'FirewallService' `
            -Name $service.Name -Expected 'Running / not Disabled' -Actual $actual `
            -Detail "Observed: $observed"))
    }

    foreach ($firewallProfile in $firewall.Profiles) {
        $observed = if (-not $firewallProfile.Present) {
            'Missing or unavailable'
        } elseif ($firewallProfile.Enabled) {
            'Enabled'
        } else {
            'Off'
        }
        [void]$Items.Add((New-DefenderHealthItem -Category 'FirewallProfile' `
            -Name $firewallProfile.Name -Expected 'Enabled' -Actual $observed `
            -Detail $firewallProfile.QueryError))
    }
}

function Add-PolicyHealthItems {
    param(
        [Parameter(Mandatory)]$Items,
        [Parameter(Mandatory)][ValidateSet('Disable','Remove','Restore')][string]$Target
    )

    foreach ($policy in Get-ExpectedPolicyValues) {
        $actual = Get-RegistryValueForHealth -Path $policy.Path -Name $policy.Name
        $expected = if ($Target -eq 'Restore') { 'absent' } else { [string]$policy.Value }
        [void]$Items.Add((New-DefenderHealthItem -Category 'Policy' -Name "$($policy.Path)\$($policy.Name)" -Expected $expected -Actual $actual))
    }
}

function Add-ServiceHealthItems {
    param(
        [Parameter(Mandatory)]$Items,
        [Parameter(Mandatory)][ValidateSet('Disable','Remove','Restore')][string]$Target,
        [switch]$IncludeMDE
    )

    $restoreDefaults = @{
        WinDefend             = 'Automatic'
        WdFilter              = 'Boot'
        WdBoot                = 'Boot'
        WdNisDrv              = 'Manual'
        WdNisSvc              = 'Manual'
        Sense                 = 'Manual'
        MDCoreSvc             = 'Manual'
        MDDlpSvc              = 'Manual'
        MsSecFlt              = 'System'
        MsSecCore             = 'System'
        SgrmAgent             = 'Manual'
        SgrmBroker            = 'Automatic'
        SecurityHealthService = 'Manual'
        wscsvc                = 'Automatic'
        webthreat             = 'Manual'
        webthreatdefsvc       = 'Manual'
        webthreatdefusersvc   = 'Automatic'
    }

    foreach ($service in ($script:DefenderServices + $script:MDEServices)) {
        $actual = Get-ServiceStartForHealth -Service $service
        if ($Target -eq 'Restore') {
            $expected = $restoreDefaults[$service]
        } elseif ($script:MDEServices -contains $service -and -not $IncludeMDE) {
            $expected = $restoreDefaults[$service]
        } else {
            $expected = 'Disabled'
        }
        [void]$Items.Add((New-DefenderHealthItem -Category 'Service' -Name $service -Expected $expected -Actual $actual))
    }
}

function Add-TaskHealthItems {
    param(
        [Parameter(Mandatory)]$Items,
        [Parameter(Mandatory)][ValidateSet('Disable','Remove','Restore')][string]$Target
    )

    foreach ($taskPath in $script:DefenderTasks) {
        $expected = if ($Target -eq 'Restore') { 'Enabled' } else { 'Disabled' }
        $actual = $null
        try {
            $tn = Split-Path $taskPath -Leaf
            $tp = Split-Path $taskPath -Parent
            $task = Get-ScheduledTask -TaskName $tn -TaskPath "$tp\" -ErrorAction Stop
            $actual = if ($task.State -eq 'Disabled') { 'Disabled' } else { 'Enabled' }
        } catch {
            $actual = 'missing'
        }
        [void]$Items.Add((New-DefenderHealthItem -Category 'Task' -Name $taskPath -Expected $expected -Actual $actual))
    }
}

function Add-AppxHealthItems {
    param(
        [Parameter(Mandatory)]$Items,
        [Parameter(Mandatory)][ValidateSet('Disable','Remove','Restore')][string]$Target
    )

    $expected = if ($Target -eq 'Remove') { 'Absent' } else { 'Present' }
    $catalog = Get-DefenderSecHealthUICatalog
    $state = Get-DefenderSecHealthUIState
    $actual = $null
    $detail = $null
    if (-not $state.Readable) {
        $detail = $state.Error
    } elseif (-not $state.Supported) {
        $actual = 'NotApplicable'
        $detail = 'Appx cmdlets are unavailable on this system.'
    } else {
        $packagePresent = $state.InstalledPackages.Count -gt 0 -or
            $state.ProvisionedPackages.Count -gt 0
        $allMarkersPresent = $state.Markers.Count -eq @($catalog.DeprovisionMarkers).Count
        $noMarkersPresent = $state.Markers.Count -eq 0
        if ($Target -eq 'Remove') {
            $actual = if (-not $packagePresent -and $allMarkersPresent) { 'Absent' }
                elseif ($packagePresent) { 'Present' }
                else { 'Partial' }
        } else {
            $actual = if ($packagePresent -and $noMarkersPresent) { 'Present' }
                elseif ($packagePresent) { 'Partial' }
                else { 'Absent' }
        }
        $detail = "Catalog v$($catalog.CatalogVersion); installed=$($state.InstalledPackages.Count); provisioned=$($state.ProvisionedPackages.Count); markers=$($state.Markers.Count)/$(@($catalog.DeprovisionMarkers).Count)"
    }
    [void]$Items.Add((New-DefenderHealthItem -Category 'Appx' -Name 'Microsoft.SecHealthUI' `
        -Expected $expected -Actual $actual -Detail $detail))
}

function Add-SafeBootHealthItems {
    param(
        [Parameter(Mandatory)]$Items,
        [Parameter(Mandatory)][ValidateSet('Disable','Remove','Restore')][string]$Target
    )

    foreach ($path in @($script:SafeBootMin, $script:SafeBootNet)) {
        $expected = if ($Target -eq 'Remove') { 'Absent' } else { 'Present' }
        $actual = if (Test-Path -LiteralPath $path) { 'Present' } else { 'Absent' }
        [void]$Items.Add((New-DefenderHealthItem -Category 'SafeBoot' -Name $path -Expected $expected -Actual $actual))
    }
}

function Add-MpPreferenceHealthItems {
    param(
        [Parameter(Mandatory)]$Items,
        [Parameter(Mandatory)][ValidateSet('Disable','Remove','Restore')][string]$Target
    )

    try {
        $prefs = Get-MpPreference -ErrorAction Stop
    } catch {
        [void]$Items.Add((New-DefenderHealthItem -Category 'MpPreference' -Name 'Query' -Expected 'Available' -Actual 'unknown' -Detail $_.Exception.Message))
        return
    }

    foreach ($preference in Get-MpRuntimePreferenceCatalog) {
        $expectedValue = if ($Target -eq 'Restore') { $preference.RestoreValue } else { $preference.DisableValue }
        $actual = if ($prefs.PSObject.Properties.Name -contains $preference.Name) { [string]$prefs.($preference.Name) } else { $null }
        [void]$Items.Add((New-DefenderHealthItem -Category 'MpPreference' -Name $preference.Name -Expected ([string]$expectedValue) -Actual $actual))
    }

    foreach ($exclusion in Get-MpRuntimeExclusionCatalog) {
        foreach ($value in $exclusion.Values) {
            $expected = if ($Target -eq 'Restore') { 'Absent' } else { 'Present' }
            $actual = if (@($prefs.($exclusion.Parameter)) -contains $value) { 'Present' } else { 'Absent' }
            [void]$Items.Add((New-DefenderHealthItem -Category 'MpPreference' -Name "$($exclusion.Parameter):$value" -Expected $expected -Actual $actual))
        }
    }
}

function Add-SurfaceHealthItems {
    param(
        [Parameter(Mandatory)]$Items,
        [switch]$IncludeMDE
    )

    $snapshot = Get-DefenderSurfaceSnapshot
    $baseline = Read-DefenderSurfaceBaseline
    $knownServices = @(Get-KnownDefenderServiceNames)
    $knownTasks = @($script:DefenderTasks)
    $secHealthCatalog = Get-DefenderSecHealthUICatalog
    $issueCount = 0

    foreach ($service in @($snapshot.Services | Where-Object { $knownServices -notcontains $_ })) {
        $issueCount++
        [void]$Items.Add((New-DefenderHealthItem -Category 'Surface' -Name "Unknown service $service" -Expected 'Known' -Actual 'Unknown' -Detail 'Review this Defender-like service before reapplying Disable.'))
    }

    foreach ($task in @($snapshot.Tasks | Where-Object { $knownTasks -notcontains $_ })) {
        $issueCount++
        [void]$Items.Add((New-DefenderHealthItem -Category 'Surface' -Name "Unknown task $task" -Expected 'Known' -Actual 'Unknown' -Detail 'Review this Defender-like scheduled task before reapplying Disable.'))
    }

    foreach ($package in @($snapshot.Packages | Where-Object {
        $packageName = [string]$_
        @($secHealthCatalog.PackageNamePatterns |
            Where-Object { $packageName -like [string]$_ }).Count -eq 0
    })) {
        $issueCount++
        [void]$Items.Add((New-DefenderHealthItem -Category 'Surface' -Name "Unknown package $package" -Expected 'Known' -Actual 'Unknown' -Detail 'Review this Defender-like package before reapplying Disable.'))
    }

    if ($baseline -and $baseline.WindowsBuild) {
        $baselineBuild = ConvertTo-DefenderBuildLabel -Build $baseline.WindowsBuild
        $currentBuild = ConvertTo-DefenderBuildLabel -Build $snapshot.WindowsBuild
        if ($baselineBuild -ne $currentBuild) {
            $issueCount++
            [void]$Items.Add((New-DefenderHealthItem -Category 'WindowsBuild' -Name 'Feature update baseline' -Expected $baselineBuild -Actual $currentBuild -Detail 'Windows build changed since the last Disable/Remove baseline; re-check Defender surfaces before reapplying.'))
        }
    }

    $plan = @()
    if ($issueCount -gt 0) {
        $plan = @(Get-DefenderReapplyPlan -IncludeMDE:$IncludeMDE)
        [void]$Items.Add((New-DefenderHealthItem -Category 'ReapplyPlan' -Name 'Feature update reapply' -Expected 'Not needed' -Actual 'Recommended' -Detail ($plan -join ' | ')))
    }

    return [pscustomobject][ordered]@{
        Snapshot = $snapshot
        Baseline = $baseline
        Plan     = $plan
    }
}

function Get-DefenderHealth {
    <#
    .SYNOPSIS
        Lists expected Defender disable/remove/restore state and current drift.
    .PARAMETER Target
        Expected target state to compare against.
    .PARAMETER IncludeMDE
        Expect MDE Sense to be disabled for Disable/Remove targets.
    .PARAMETER Json
        Emit JSON instead of an ordered dictionary.
    .EXAMPLE
        Get-DefenderHealth
    .EXAMPLE
        Get-DefenderHealth -Target Remove -Json
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Disable','Remove','Restore')]
        [string]$Target = 'Disable',
        [switch]$IncludeMDE,
        [switch]$Json
    )

    $items = New-Object System.Collections.ArrayList
    Add-FirewallHealthItems -Items $items
    Add-PolicyHealthItems -Items $items -Target $Target
    Add-ServiceHealthItems -Items $items -Target $Target -IncludeMDE:$IncludeMDE
    Add-TaskHealthItems -Items $items -Target $Target
    Add-AppxHealthItems -Items $items -Target $Target
    Add-SafeBootHealthItems -Items $items -Target $Target
    Add-MpPreferenceHealthItems -Items $items -Target $Target
    $surface = Add-SurfaceHealthItems -Items $items -IncludeMDE:$IncludeMDE

    $ok = @($items | Where-Object { $_.Status -eq 'OK' }).Count
    $drift = @($items | Where-Object { $_.Status -eq 'Drift' }).Count
    $unknown = @($items | Where-Object { $_.Status -eq 'Unknown' }).Count

    $result = [ordered]@{
        Target    = $Target
        Generated = (Get-Date).ToString('o')
        WindowsBuild = $surface.Snapshot.WindowsBuild
        SurfaceBaseline = $surface.Baseline
        ReapplyPlan = @($surface.Plan)
        Summary   = [ordered]@{
            Total   = $items.Count
            OK      = $ok
            Drift   = $drift
            Unknown = $unknown
        }
        Items     = @($items)
    }

    if ($Json) {
        return ([PSCustomObject]$result | ConvertTo-Json -Depth 8)
    }
    return $result
}
