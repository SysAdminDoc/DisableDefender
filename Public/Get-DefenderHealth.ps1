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
    $loggerRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger'
    $bfpRoot = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Features\BehavioralNetworkBlocks\BruteForceProtection'
    $repRoot = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Features\BehavioralNetworkBlocks\RemoteEncryptionProtection'

    return @(
        @{ Path = $script:PolicyRoot; Name = 'DisableAntiSpyware'; Value = 1 }
        @{ Path = $script:PolicyRoot; Name = 'DisableAntiVirus'; Value = 1 }
        @{ Path = $script:PolicyRoot; Name = 'DisableRoutinelyTakingAction'; Value = 1 }
        @{ Path = $script:PolicyRoot; Name = 'DisableSpecialRunningModes'; Value = 1 }
        @{ Path = $script:PolicyRoot; Name = 'ServiceKeepAlive'; Value = 0 }
        @{ Path = $script:PolicyRoot; Name = 'AllowFastServiceStartup'; Value = 0 }
        @{ Path = $script:PolicyRoot; Name = 'DisableLocalAdminMerge'; Value = 1 }
        @{ Path = $script:PolicyRoot; Name = 'PUAProtection'; Value = 0 }
        @{ Path = $script:RealTimeRoot; Name = 'DisableRealtimeMonitoring'; Value = 1 }
        @{ Path = $script:RealTimeRoot; Name = 'DisableBehaviorMonitoring'; Value = 1 }
        @{ Path = $script:RealTimeRoot; Name = 'DisableOnAccessProtection'; Value = 1 }
        @{ Path = $script:RealTimeRoot; Name = 'DisableScanOnRealtimeEnable'; Value = 1 }
        @{ Path = $script:RealTimeRoot; Name = 'DisableIOAVProtection'; Value = 1 }
        @{ Path = $script:RealTimeRoot; Name = 'DisableRawWriteNotification'; Value = 1 }
        @{ Path = $script:RealTimeRoot; Name = 'DisableIntrusionPreventionSystem'; Value = 1 }
        @{ Path = $script:RealTimeRoot; Name = 'DisableInformationProtectionControl'; Value = 1 }
        @{ Path = $script:RealTimeRoot; Name = 'LocalSettingOverrideDisableRealtimeMonitoring'; Value = 1 }
        @{ Path = $script:SpynetRoot; Name = 'SpyNetReporting'; Value = 0 }
        @{ Path = $script:SpynetRoot; Name = 'SubmitSamplesConsent'; Value = 2 }
        @{ Path = $script:SpynetRoot; Name = 'DisableBlockAtFirstSeen'; Value = 1 }
        @{ Path = $script:SpynetRoot; Name = 'LocalSettingOverrideSpynetReporting'; Value = 0 }
        @{ Path = $script:MpEngineRoot; Name = 'MpEnablePus'; Value = 0 }
        @{ Path = $script:MpEngineRoot; Name = 'EnableFileHashComputation'; Value = 0 }
        @{ Path = $script:MpEngineRoot; Name = 'MpCloudBlockLevel'; Value = 0 }
        @{ Path = $script:MpEngineRoot; Name = 'MpBafsExtendedTimeout'; Value = 0 }
        @{ Path = $script:NISRoot; Name = 'DisableProtocolRecognition'; Value = 1 }
        @{ Path = $script:NISIPSRoot; Name = 'DisableSignatureRetirement'; Value = 1 }
        @{ Path = $script:NISIPSRoot; Name = 'ThrottleDetectionEventsRate'; Value = 10000000 }
        @{ Path = $script:SignatureRoot; Name = 'ForceUpdateFromMU'; Value = 0 }
        @{ Path = $script:SignatureRoot; Name = 'DisableScheduledSignatureUpdateOnBattery'; Value = 1 }
        @{ Path = $script:SignatureRoot; Name = 'RealtimeSignatureDelivery'; Value = 0 }
        @{ Path = $script:SignatureRoot; Name = 'DisableUpdateOnStartupWithoutEngine'; Value = 1 }
        @{ Path = $script:ScanRoot; Name = 'DisableRemovableDriveScanning'; Value = 1 }
        @{ Path = $script:ScanRoot; Name = 'DisableArchiveScanning'; Value = 1 }
        @{ Path = $script:ScanRoot; Name = 'DisableScanningMappedNetworkDrivesForFullScan'; Value = 1 }
        @{ Path = $script:ScanRoot; Name = 'DisableScanningNetworkFiles'; Value = 1 }
        @{ Path = $script:UXRoot; Name = 'Notification_Suppress'; Value = 1 }
        @{ Path = $script:ReportingRoot; Name = 'DisableEnhancedNotifications'; Value = 1 }
        @{ Path = $script:ATPRoot; Name = 'ForceDefenderPassiveMode'; Value = 1 }
        @{ Path = $script:SmartScreen; Name = 'EnableSmartScreen'; Value = 0 }
        @{ Path = $script:MRTRoot; Name = 'DontOfferThroughWUAU'; Value = 1 }
        @{ Path = $script:MRTRoot; Name = 'DontReportInfectionInformation'; Value = 1 }
        @{ Path = $script:MsAntimalware; Name = 'ServiceKeepAlive'; Value = 0 }
        @{ Path = (Join-Path $loggerRoot 'DefenderApiLogger'); Name = 'Start'; Value = 0 }
        @{ Path = (Join-Path $loggerRoot 'DefenderAuditLogger'); Name = 'Start'; Value = 0 }
        @{ Path = $bfpRoot; Name = 'BruteForceProtectionConfiguredState'; Value = 4 }
        @{ Path = $repRoot; Name = 'RemoteEncryptionProtectionConfiguredState'; Value = 4 }
    )
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
    $actual = $null
    try {
        $installed = @(Get-AppxPackage -AllUsers -Name 'Microsoft.SecHealthUI' -ErrorAction SilentlyContinue)
        $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq 'Microsoft.SecHealthUI' })
        $marker = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.SecHealthUI_8wekyb3d8bbwe'
        $deprovisioned = Test-Path -LiteralPath $marker
        $actual = if (($installed.Count -gt 0 -or $provisioned.Count -gt 0) -and -not $deprovisioned) { 'Present' } else { 'Absent' }
    } catch {}
    [void]$Items.Add((New-DefenderHealthItem -Category 'Appx' -Name 'Microsoft.SecHealthUI' -Expected $expected -Actual $actual))
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
    Add-PolicyHealthItems -Items $items -Target $Target
    Add-ServiceHealthItems -Items $items -Target $Target -IncludeMDE:$IncludeMDE
    Add-TaskHealthItems -Items $items -Target $Target
    Add-AppxHealthItems -Items $items -Target $Target
    Add-SafeBootHealthItems -Items $items -Target $Target
    Add-MpPreferenceHealthItems -Items $items -Target $Target

    $ok = @($items | Where-Object { $_.Status -eq 'OK' }).Count
    $drift = @($items | Where-Object { $_.Status -eq 'Drift' }).Count
    $unknown = @($items | Where-Object { $_.Status -eq 'Unknown' }).Count

    $result = [ordered]@{
        Target    = $Target
        Generated = (Get-Date).ToString('o')
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
