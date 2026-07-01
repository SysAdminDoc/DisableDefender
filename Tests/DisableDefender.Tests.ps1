#Requires -Module Pester

$moduleManifestForDiscovery = Join-Path $PSScriptRoot '..\DisableDefender.psd1'
Import-Module -Name $moduleManifestForDiscovery -Force

BeforeAll {
    $script:ModuleManifest = Join-Path $PSScriptRoot '..\DisableDefender.psd1'
    Import-Module -Name $script:ModuleManifest -Force
}

Describe 'Module manifest' {
    It 'passes Test-ModuleManifest' {
        { Test-ModuleManifest -Path $script:ModuleManifest -ErrorAction Stop } | Should -Not -Throw
    }

    It 'exports only public commands' {
        $expected = @(
            'Compare-DefenderSnapshots'
            'Export-DefenderHtmlReport'
            'Export-DefenderSupportBundle'
            'Get-DefenderComponentStatus'
            'Get-DefenderHealth'
            'Get-DefenderStatus'
            'Invoke-DisableDefender'
            'Invoke-RemoveDefender'
            'Invoke-RestoreDefender'
            'Invoke-SafeModeRemove'
            'New-OfflineRemoveBundle'
            'Save-DefenderSnapshot'
            'Show-DefenderStatus'
        ) | Sort-Object
        $actual = (Get-Command -Module DisableDefender -CommandType Function).Name | Sort-Object
        $actual | Should -Be $expected
    }
}

Describe 'Local release build' {
    It 'builds an unsigned release zip with hash and metadata' {
        $version = [string](Test-ModuleManifest -Path $script:ModuleManifest).Version
        $output = Join-Path $TestDrive 'release'
        $scriptPath = Join-Path $PSScriptRoot '..\tools\New-DisableDefenderRelease.ps1'

        $metadata = & $scriptPath -Version $version -OutputDirectory $output -SkipSigning

        Test-Path -LiteralPath $metadata.ZipPath | Should -Be $true
        Test-Path -LiteralPath "$($metadata.ZipPath).sha256" | Should -Be $true
        Test-Path -LiteralPath (Join-Path $output "DisableDefender-v$version.release.json") | Should -Be $true
        $metadata.SignatureStatus | Should -Be 'Unsigned'

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($metadata.ZipPath)
        try {
            $entries = @($zip.Entries | ForEach-Object { $_.FullName.Replace('\','/') })
            $entries | Should -Contain 'tools/New-DisableDefenderRelease.ps1'
            $entries | Should -Not -Contain 'ROADMAP.md'
            $entries | Should -Not -Contain 'RESEARCH.md'
        } finally {
            $zip.Dispose()
        }
    }
}

InModuleScope DisableDefender {
    Describe 'Runtime directory preflight' {
        BeforeAll {
            function New-TestRuntimeDirectoryAcl {
                param([switch]$Weak)

                $acl = New-Object System.Security.AccessControl.DirectorySecurity
                $acl.SetAccessRuleProtection($true, $false)
                foreach ($sidValue in @('S-1-5-32-544','S-1-5-18')) {
                    $identity = New-Object System.Security.Principal.SecurityIdentifier($sidValue)
                    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                        $identity,
                        [System.Security.AccessControl.FileSystemRights]::FullControl,
                        [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',
                        [System.Security.AccessControl.PropagationFlags]::None,
                        [System.Security.AccessControl.AccessControlType]::Allow)
                    $acl.AddAccessRule($rule)
                }
                if ($Weak) {
                    $users = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')
                    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                        $users,
                        [System.Security.AccessControl.FileSystemRights]::Modify,
                        [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',
                        [System.Security.AccessControl.PropagationFlags]::None,
                        [System.Security.AccessControl.AccessControlType]::Allow)
                    $acl.AddAccessRule($rule)
                }
                return $acl
            }
        }

        It 'accepts a safe runtime directory' {
            $dir = Join-Path $TestDrive 'runtime-safe'
            Mock Test-Path { $true }
            Mock Get-Item {
                [pscustomobject]@{
                    PSIsContainer = $true
                    Attributes    = [System.IO.FileAttributes]::Directory
                }
            }
            $script:SafeRuntimeAcl = New-TestRuntimeDirectoryAcl
            Mock Get-DefenderRuntimeDirectoryAcl { return $script:SafeRuntimeAcl }
            Mock Set-DefenderRuntimeDirectoryAcl {}

            $result = Initialize-DefenderRuntimeDirectory -Path $dir

            $result.Created | Should -Be $false
            $result.Repaired | Should -Be $false
            Should -Invoke Set-DefenderRuntimeDirectoryAcl -Times 0 -Exactly
        }

        It 'refuses a runtime directory that is a reparse point' {
            $dir = Join-Path $TestDrive 'runtime-link'
            Mock Test-Path { $true }
            Mock Get-Item {
                [pscustomobject]@{
                    PSIsContainer = $true
                    Attributes    = ([System.IO.FileAttributes]::Directory -bor [System.IO.FileAttributes]::ReparsePoint)
                }
            }
            Mock Get-DefenderRuntimeDirectoryAcl { throw 'should not inspect ACL for reparse point' }

            { Initialize-DefenderRuntimeDirectory -Path $dir } | Should -Throw -ExpectedMessage '*reparse point*'
            Should -Invoke Get-DefenderRuntimeDirectoryAcl -Times 0 -Exactly
        }

        It 'repairs a runtime directory with non-admin write access' {
            $dir = Join-Path $TestDrive 'runtime-weak'
            $script:WeakRuntimeAcl = New-TestRuntimeDirectoryAcl -Weak
            $script:SafeRuntimeAcl = New-TestRuntimeDirectoryAcl
            @(Get-DefenderRuntimeDirectoryWeakWriteRules -Acl $script:WeakRuntimeAcl).Count | Should -BeGreaterThan 0
            $script:RuntimeAclReads = 0
            Mock Test-Path { $true }
            Mock Get-Item {
                [pscustomobject]@{
                    PSIsContainer = $true
                    Attributes    = [System.IO.FileAttributes]::Directory
                }
            }
            Mock Get-DefenderRuntimeDirectoryAcl {
                $script:RuntimeAclReads++
                if ($script:RuntimeAclReads -eq 1) { return $script:WeakRuntimeAcl }
                return $script:SafeRuntimeAcl
            }
            Mock Set-DefenderRuntimeDirectoryAcl {}

            $result = Initialize-DefenderRuntimeDirectory -Path $dir

            $result.Repaired | Should -Be $true
            Should -Invoke Set-DefenderRuntimeDirectoryAcl -Times 1 -Exactly
        }
    }

    Describe 'Set-RegValue' {
        Context 'Refuse-list guard' {
            It 'refuses to write to firewall policy paths' {
                Mock New-ItemProperty {}
                Mock New-Item {}
                Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall\DomainProfile' -Name 'Test' -Value 1
                Should -Invoke New-ItemProperty -Times 0 -Exactly
            }

            It 'refuses to write to firewall service paths' {
                Mock New-ItemProperty {}
                Mock New-Item {}
                Set-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\mpssvc\Parameters' -Name 'Test' -Value 1
                Should -Invoke New-ItemProperty -Times 0 -Exactly
            }

            It 'allows writing to Defender policy paths' {
                Mock New-ItemProperty {}
                Mock Test-Path { $true }
                Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -Name 'DisableAntiSpyware' -Value 1
                Should -Invoke New-ItemProperty -Times 1 -Exactly
            }
        }
    }

    Describe 'Set-ServiceStart' {
        Context 'Refuse-list guard' {
            It 'refuses to modify firewall services' {
                $result = Set-ServiceStart -Service 'mpssvc' -State 'Disabled'
                $result | Should -Be $false
            }

            It 'refuses to modify BFE' {
                $result = Set-ServiceStart -Service 'BFE' -State 'Disabled'
                $result | Should -Be $false
            }

            It 'refuses to modify SharedAccess' {
                $result = Set-ServiceStart -Service 'SharedAccess' -State 'Disabled'
                $result | Should -Be $false
            }
        }

        Context 'Absent service' {
            It 'returns true for services not present on the system' {
                Mock Test-Path { $false }
                $result = Set-ServiceStart -Service 'FakeDefenderService' -State 'Disabled'
                $result | Should -Be $true
            }
        }

        Context 'Target verification' {
            It 'returns false when SYSTEM fallback reports success but Start value does not change' {
                Mock Test-Path { $true }
                Mock Set-ItemProperty { throw 'denied' }
                Mock Grant-RegKeyControl { $false }
                Mock Invoke-AsSystem { return $true }
                Mock Get-ItemProperty { [PSCustomObject]@{ Start = 3 } }
                Mock Write-Log {}

                $result = Set-ServiceStart -Service 'WinDefend' -State 'Disabled'

                $result | Should -Be $false
                Should -Invoke Invoke-AsSystem -Times 1 -Exactly
            }
        }
    }

    Describe 'Test-FirewallIntact' {
        Context 'All services running and profiles enabled' {
            It 'returns empty array when firewall is healthy' {
                Mock Get-Service {
                    [PSCustomObject]@{ Name = $Name; Status = 'Running'; StartType = 'Automatic' }
                }
                Mock Get-NetFirewallProfile {
                    @(
                        [PSCustomObject]@{ Name = 'Domain'; Enabled = $true },
                        [PSCustomObject]@{ Name = 'Private'; Enabled = $true },
                        [PSCustomObject]@{ Name = 'Public'; Enabled = $true }
                    )
                }
                $result = Test-FirewallIntact
                $result.Count | Should -Be 0
            }
        }

        Context 'Critical service disabled' {
            It 'reports when mpssvc is disabled' {
                Mock Get-Service {
                    [PSCustomObject]@{ Name = $Name; Status = 'Stopped'; StartType = 'Disabled' }
                }
                Mock Get-NetFirewallProfile {
                    @([PSCustomObject]@{ Name = 'Domain'; Enabled = $true })
                }
                $result = Test-FirewallIntact
                $result.Count | Should -BeGreaterThan 0
                $result[0] | Should -Match 'mpssvc'
            }
        }

        Context 'Firewall profile off' {
            It 'reports when a profile is disabled' {
                Mock Get-Service {
                    [PSCustomObject]@{ Name = $Name; Status = 'Running'; StartType = 'Automatic' }
                }
                Mock Get-NetFirewallProfile {
                    @(
                        [PSCustomObject]@{ Name = 'Domain'; Enabled = $true },
                        [PSCustomObject]@{ Name = 'Private'; Enabled = $false },
                        [PSCustomObject]@{ Name = 'Public'; Enabled = $true }
                    )
                }
                $result = Test-FirewallIntact
                $result.Count | Should -BeGreaterThan 0
                $result[0] | Should -Match 'Private'
            }
        }
    }

    Describe 'Assert-FirewallSafety' {
        BeforeEach {
            Mock Write-Log {}
        }

        It 'does not throw when firewall is healthy' {
            Mock Get-Service {
                [PSCustomObject]@{ Name = $Name; Status = 'Running'; StartType = 'Automatic' }
            }
            Mock Get-NetFirewallProfile {
                @(
                    [PSCustomObject]@{ Name = 'Domain'; Enabled = $true },
                    [PSCustomObject]@{ Name = 'Private'; Enabled = $true },
                    [PSCustomObject]@{ Name = 'Public'; Enabled = $true }
                )
            }

            { Assert-FirewallSafety -Stage pre } | Should -Not -Throw
        }

        It 'fails closed during preflight when firewall is already broken' {
            Mock Get-Service {
                [PSCustomObject]@{ Name = $Name; Status = 'Stopped'; StartType = 'Disabled' }
            }
            Mock Get-NetFirewallProfile {
                @([PSCustomObject]@{ Name = 'Domain'; Enabled = $true })
            }

            { Assert-FirewallSafety -Stage pre } | Should -Throw -ExpectedMessage '*pre stage*'
        }

        It 'fails closed during per-phase before boundaries even when Force is active' {
            $script:ForceMode = $true
            try {
                Mock Get-Service {
                    [PSCustomObject]@{ Name = $Name; Status = 'Running'; StartType = 'Automatic' }
                }
                Mock Get-NetFirewallProfile {
                    @([PSCustomObject]@{ Name = 'Private'; Enabled = $false })
                }

                { Assert-FirewallSafety -Stage 'before:Services' } | Should -Throw -ExpectedMessage '*before:Services stage*'
            } finally {
                $script:ForceMode = $false
            }
        }
    }

    Describe 'Get-TargetServices' {
        Context 'Default' {
            It 'does not include Sense in the default list' {
                $script:IncludeMDEMode = $false
                $result = Get-TargetServices
                $result | Should -Not -Contain 'Sense'
            }

            It 'includes WinDefend' {
                $script:IncludeMDEMode = $false
                $result = Get-TargetServices
                $result | Should -Contain 'WinDefend'
            }
        }

        Context 'With -IncludeMDE' {
            It 'includes Sense when IncludeMDE is set' {
                $script:IncludeMDEMode = $true
                try {
                    $result = Get-TargetServices
                    $result | Should -Contain 'Sense'
                } finally {
                    $script:IncludeMDEMode = $false
                }
            }
        }
    }

    Describe 'Get-DefenderStatus' {
        It 'returns an ordered dictionary' {
            Mock Get-MpComputerStatus { throw 'Not available' }
            Mock Get-Service { $null }
            Mock Get-NetFirewallProfile { throw 'Not available' }
            Mock Get-CimInstance { throw 'Not available' }
            $result = Get-DefenderStatus
            $result | Should -BeOfType [System.Collections.Specialized.OrderedDictionary]
        }

        It 'includes firewall keys' {
            Mock Get-MpComputerStatus { throw 'Not available' }
            Mock Get-Service { $null }
            Mock Get-CimInstance { throw 'Not available' }
            Mock Get-NetFirewallProfile {
                @([PSCustomObject]@{ Name = 'Domain'; Enabled = $true })
            }
            $result = Get-DefenderStatus
            $result.Keys | Should -Contain 'firewall_Domain'
        }
    }

    Describe 'Get-DefenderHealth' {
        It 'returns summary and drift items for the default target' {
            Mock Get-MpPreference {
                [PSCustomObject]@{
                    DisableRealtimeMonitoring = $true
                    DisableBehaviorMonitoring = $true
                    DisableBlockAtFirstSeen = $true
                    DisableIOAVProtection = $true
                    DisableScriptScanning = $true
                    DisableArchiveScanning = $true
                    DisableIntrusionPreventionSystem = $true
                    DisableRemovableDriveScanning = $true
                    DisableScanningMappedNetworkDrivesForFullScan = $true
                    DisableScanningNetworkFiles = $true
                    ExclusionPath = @('C:\','D:\','E:\')
                }
            }
            Mock Get-ScheduledTask { [PSCustomObject]@{ State = 'Disabled' } }
            Mock Get-AppxPackage { @([PSCustomObject]@{ PackageFullName = 'Microsoft.SecHealthUI_1.0.0.0_x64__8wekyb3d8bbwe' }) }
            Mock Get-AppxProvisionedPackage { @([PSCustomObject]@{ DisplayName = 'Microsoft.SecHealthUI'; PackageName = 'Microsoft.SecHealthUI_1.0.0.0_neutral__8wekyb3d8bbwe' }) }

            $result = Get-DefenderHealth

            $result.Keys | Should -Contain 'Summary'
            $result.Keys | Should -Contain 'Items'
            $result.Target | Should -Be 'Disable'
            $result.Items.Count | Should -BeGreaterThan 0
            ($result.Items | Where-Object { $_.Category -eq 'Appx' }).Expected | Should -Contain 'Present'
            ($result.Items | Where-Object { $_.Category -eq 'Service' -and $_.Name -eq 'Sense' }).Expected | Should -Contain 'Manual'
        }

        It 'emits JSON health output' {
            Mock Get-MpPreference { throw 'Not available' }
            Mock Get-ScheduledTask { throw 'Not available' }
            Mock Get-AppxPackage { @() }
            Mock Get-AppxProvisionedPackage { @() }

            $json = Get-DefenderHealth -Target Remove -Json
            $parsed = $json | ConvertFrom-Json

            $parsed.Target | Should -Be 'Remove'
            $parsed.Summary.Total | Should -BeGreaterThan 0
        }

        It 'defines restore values for every runtime MpPreference write' {
            $catalog = @(Get-MpRuntimePreferenceCatalog)

            $catalog.Count | Should -BeGreaterThan 0
            foreach ($preference in $catalog) {
                $preference.Name | Should -Not -BeNullOrEmpty
                $preference.PSObject.Properties.Name | Should -Contain 'DisableValue'
                $preference.PSObject.Properties.Name | Should -Contain 'RestoreValue'
            }
        }

        It 'reports health for every runtime MpPreference and exclusion entry' {
            $prefData = [ordered]@{}
            foreach ($preference in Get-MpRuntimePreferenceCatalog) {
                $prefData[$preference.Name] = $preference.DisableValue
            }
            foreach ($exclusion in Get-MpRuntimeExclusionCatalog) {
                $prefData[$exclusion.Parameter] = $exclusion.Values
            }
            Mock Get-MpPreference { [PSCustomObject]$prefData }
            Mock Get-ScheduledTask { throw 'Not available' }
            Mock Get-AppxPackage { @() }
            Mock Get-AppxProvisionedPackage { @() }

            $result = Get-DefenderHealth -Target Disable
            $healthNames = @($result.Items | Where-Object { $_.Category -eq 'MpPreference' } | ForEach-Object { $_.Name })

            foreach ($preference in Get-MpRuntimePreferenceCatalog) {
                $healthNames | Should -Contain $preference.Name
            }
            foreach ($exclusion in Get-MpRuntimeExclusionCatalog) {
                foreach ($value in $exclusion.Values) {
                    $healthNames | Should -Contain "$($exclusion.Parameter):$value"
                }
            }
        }

        It 'flags unknown Defender surfaces and changed Windows build with a reapply plan' {
            $previousAppDir = $script:AppDir
            $script:AppDir = $TestDrive
            try {
                $baseline = [ordered]@{
                    SchemaVersion = 1
                    WindowsBuild  = [ordered]@{
                        Caption        = 'Microsoft Windows 11'
                        Version        = '10.0.26100'
                        BuildNumber    = '26100'
                        DisplayVersion = '24H2'
                    }
                    Services = @('WinDefend')
                    Tasks    = @()
                    Packages = @('Microsoft.SecHealthUI')
                }
                $baseline | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $TestDrive 'surface-baseline.json') -Encoding UTF8

                $prefData = [ordered]@{}
                foreach ($preference in Get-MpRuntimePreferenceCatalog) {
                    $prefData[$preference.Name] = $preference.DisableValue
                }
                foreach ($exclusion in Get-MpRuntimeExclusionCatalog) {
                    $prefData[$exclusion.Parameter] = $exclusion.Values
                }
                Mock Get-MpPreference { [PSCustomObject]$prefData }
                Mock Get-ScheduledTask {
                    if ($PSBoundParameters.ContainsKey('TaskName')) { return [PSCustomObject]@{ State = 'Disabled' } }
                    return @(
                        [PSCustomObject]@{ TaskPath = '\Microsoft\Windows\Windows Defender\'; TaskName = 'Windows Defender Scheduled Scan' },
                        [PSCustomObject]@{ TaskPath = '\Microsoft\Windows\Windows Defender\'; TaskName = 'Windows Defender Future Scan' }
                    )
                }
                Mock Get-AppxPackage {
                    @(
                        [PSCustomObject]@{ Name = 'Microsoft.SecHealthUI'; PackageFullName = 'Microsoft.SecHealthUI_1.0.0.0_x64__8wekyb3d8bbwe' },
                        [PSCustomObject]@{ Name = 'Microsoft.DefenderFuture'; PackageFullName = 'Microsoft.DefenderFuture_1.0.0.0_x64__8wekyb3d8bbwe' }
                    )
                }
                Mock Get-AppxProvisionedPackage { @() }
                Mock Get-CimInstance {
                    [PSCustomObject]@{ Caption = 'Microsoft Windows 11'; Version = '10.0.29999'; BuildNumber = '29999' }
                } -ParameterFilter { $ClassName -eq 'Win32_OperatingSystem' }
                Mock Get-ItemProperty {
                    [PSCustomObject]@{ DisplayVersion = '26H1' }
                } -ParameterFilter { $LiteralPath -eq 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' }
                Mock Get-ChildItem {
                    @(
                        [PSCustomObject]@{ PSChildName = 'WinDefend' },
                        [PSCustomObject]@{ PSChildName = 'WdFutureSvc' }
                    )
                } -ParameterFilter { $LiteralPath -eq 'HKLM:\SYSTEM\CurrentControlSet\Services' }

                $result = Get-DefenderHealth -Target Disable

                $surfaceNames = @($result.Items | Where-Object { $_.Category -eq 'Surface' } | ForEach-Object { $_.Name })
                $surfaceNames | Should -Contain 'Unknown service WdFutureSvc'
                $surfaceNames | Should -Contain 'Unknown task \Microsoft\Windows\Windows Defender\Windows Defender Future Scan'
                $surfaceNames | Should -Contain 'Unknown package Microsoft.DefenderFuture'
                ($result.Items | Where-Object { $_.Category -eq 'WindowsBuild' }).Status | Should -Contain 'Drift'
                ($result.Items | Where-Object { $_.Category -eq 'ReapplyPlan' }).Status | Should -Contain 'Drift'
                ($result.ReapplyPlan -join ' ') | Should -Match 'MDE Sense is preserved'
            } finally {
                $script:AppDir = $previousAppDir
            }
        }
    }

    Describe 'Get-DefenderComponentStatus' {
        It 'includes the core process and driver protection components' {
            Mock Get-Service {
                [PSCustomObject]@{
                    Name      = $Name
                    Status    = 'Stopped'
                    StartType = 'Disabled'
                }
            }
            Mock Test-Path { $true }
            Mock Get-ItemProperty {
                if ($Name -eq 'LaunchProtected') {
                    return [PSCustomObject]@{ LaunchProtected = 3 }
                }
                [PSCustomObject]@{ Start = 4 }
            }
            Mock Get-CimInstance {
                [PSCustomObject]@{ State = 'Stopped'; StartMode = 'Disabled' }
            } -ParameterFilter { $ClassName -eq 'Win32_SystemDriver' }

            $result = @(Get-DefenderComponentStatus)

            $result.Name | Should -Contain 'MsMpEng'
            $result.Name | Should -Contain 'WdFilter'
            $result.Name | Should -Contain 'WdBoot'
            $result.Name | Should -Contain 'WdNisDrv'
            ($result | Where-Object { $_.Name -eq 'MsMpEng' }).PPLStatus | Should -Be 'AntimalwareLight'
            ($result | Where-Object { $_.Name -eq 'WdFilter' }).DriverRuntime | Should -Be 'Stopped / Disabled'
        }

        It 'emits JSON component output' {
            Mock Get-Service { $null }
            Mock Test-Path { $false }
            Mock Get-CimInstance { $null } -ParameterFilter { $ClassName -eq 'Win32_SystemDriver' }

            $json = Get-DefenderComponentStatus -Json
            $parsed = $json | ConvertFrom-Json

            $parsed.Name | Should -Contain 'MsMpEng'
            ($parsed | Where-Object { $_.Name -eq 'Sense' }).ExpectedStart | Should -Be 'Manual'
        }

        It 'flags unknown Defender-like services as drift rows' {
            Mock Get-ChildItem {
                @(
                    [PSCustomObject]@{ PSChildName = 'WinDefend' },
                    [PSCustomObject]@{ PSChildName = 'WdFutureSvc' }
                )
            } -ParameterFilter { $LiteralPath -eq 'HKLM:\SYSTEM\CurrentControlSet\Services' }
            Mock Get-Service {
                if ($Name -eq 'WdFutureSvc') {
                    return [PSCustomObject]@{ Name = 'WdFutureSvc'; Status = 'Running'; StartType = 'Automatic' }
                }
                return $null
            }
            Mock Test-Path {
                return ($LiteralPath -like '*\WdFutureSvc')
            }
            Mock Get-ItemProperty {
                [PSCustomObject]@{ Start = 2; LaunchProtected = 0 }
            } -ParameterFilter { $LiteralPath -like '*\WdFutureSvc' }
            Mock Get-CimInstance { $null } -ParameterFilter { $ClassName -eq 'Win32_SystemDriver' }

            $result = @(Get-DefenderComponentStatus)
            $unknown = $result | Where-Object { $_.Service -eq 'WdFutureSvc' }

            $unknown.Kind | Should -Be 'UnknownService'
            $unknown.DisableTargetDrift | Should -Be 'Drift'
            $unknown.ExpectedStart | Should -Be 'Review'
        }
    }

    Describe 'WhatIf behavior' {
        It 'Grant-RegKeyControl returns true without modifying registry under WhatIf' {
            $WhatIfPreference = $true
            try {
                $result = Grant-RegKeyControl -SubKey 'SYSTEM\CurrentControlSet\Services\WinDefend'
                $result | Should -Be $true
            } finally {
                $WhatIfPreference = $false
            }
        }

        It 'Invoke-AsSystem returns true without creating a task under WhatIf' {
            $WhatIfPreference = $true
            try {
                $result = Invoke-AsSystem -Execute 'reg.exe' -Argument 'query HKLM /ve'
                $result | Should -Be $true
            } finally {
                $WhatIfPreference = $false
            }
        }
    }

    Describe 'Invoke-AsSystem result handling' {
        BeforeEach {
            $script:AppDir = $TestDrive
            $script:SystemTaskLogs = @()
            Mock Register-ScheduledTask {}
            Mock Start-ScheduledTask {}
            Mock Unregister-ScheduledTask {}
            Mock Remove-Item {}
            Mock Test-Path { $false }
            Mock Write-Log {
                param($Message, $Level)
                $script:SystemTaskLogs += "$Level|$Message"
            }
        }

        It 'returns true when the scheduled task reports success' {
            Mock Get-ScheduledTaskInfo { [PSCustomObject]@{ LastTaskResult = 0 } }

            Invoke-AsSystem -Execute 'reg.exe' -Argument 'query HKLM /ve' | Should -Be $true

            ($script:SystemTaskLogs -join "`n") | Should -Match 'DEBUG\|SYSTEM task completed:'
        }

        It 'returns false and logs the result when the scheduled task fails' {
            Mock Get-ScheduledTaskInfo { [PSCustomObject]@{ LastTaskResult = 1 } }

            Invoke-AsSystem -Execute 'reg.exe' -Argument 'query HKLM /ve' | Should -Be $false

            ($script:SystemTaskLogs -join "`n") | Should -Match 'WARN\|SYSTEM task failed:'
            ($script:SystemTaskLogs -join "`n") | Should -Match 'LastTaskResult=1'
        }
    }

    Describe 'Remove known-bad safety gate' {
        BeforeEach {
            $script:AppDir = $TestDrive
            $script:ForceMode = $false
            $script:AllowRemotingMode = $false
            Mock Write-Log {}
            Remove-Item -LiteralPath (Join-Path $TestDrive 'tripwire.jsonl') -Force -ErrorAction SilentlyContinue
        }

        It 'refuses Remove on a domain-joined machine and writes a blocked tripwire' {
            Mock Get-CimInstance {
                [PSCustomObject]@{
                    PartOfDomain = $true
                    Domain       = 'corp.example'
                }
            } -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' }

            { Confirm-RemoveKnownBadOverrides } | Should -Throw -ExpectedMessage '*DomainJoined*'

            $tripwire = Get-Content -LiteralPath (Join-Path $TestDrive 'tripwire.jsonl') | Select-Object -Last 1 | ConvertFrom-Json
            $tripwire.Name | Should -Be 'DomainJoined'
            $tripwire.Mode | Should -Be 'Remove'
            $tripwire.Blocked | Should -Be $true
            $tripwire.Details.Domain | Should -Be 'corp.example'
        }

        It 'allows Force override while logging an unblocked tripwire' {
            $script:ForceMode = $true
            Mock Get-CimInstance {
                [PSCustomObject]@{
                    PartOfDomain = $true
                    Domain       = 'corp.example'
                }
            } -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' }

            { Confirm-RemoveKnownBadOverrides } | Should -Not -Throw

            $tripwire = Get-Content -LiteralPath (Join-Path $TestDrive 'tripwire.jsonl') | Select-Object -Last 1 | ConvertFrom-Json
            $tripwire.Blocked | Should -Be $false
            $tripwire.Force | Should -Be $true
        }

        It 'refuses PSRemoting sessions unless explicitly allowed' {
            Mock Test-PSRemotingSession { $true }

            { Confirm-LocalSession -Mode Disable } | Should -Throw -ExpectedMessage '*AllowRemoting*'

            $tripwire = Get-Content -LiteralPath (Join-Path $TestDrive 'tripwire.jsonl') | Select-Object -Last 1 | ConvertFrom-Json
            $tripwire.Name | Should -Be 'PSRemotingSession'
            $tripwire.Blocked | Should -Be $true
        }

        It 'allows PSRemoting sessions when override is set' {
            $script:AllowRemotingMode = $true
            Mock Test-PSRemotingSession { $true }

            { Confirm-LocalSession -Mode Restore } | Should -Not -Throw

            $tripwire = Get-Content -LiteralPath (Join-Path $TestDrive 'tripwire.jsonl') | Select-Object -Last 1 | ConvertFrom-Json
            $tripwire.Name | Should -Be 'PSRemotingSession'
            $tripwire.Mode | Should -Be 'Restore'
            $tripwire.Blocked | Should -Be $false
        }
    }

    Describe 'System Restore checkpoint throttling' {
        BeforeEach {
            $script:NoRestorePointMode = $false
            $script:RestorePointLogs = @()
            Mock Enable-ComputerRestore {}
            Mock Write-Log {
                param($Message, $Level)
                $script:RestorePointLogs += "$Level|$Message"
            }
        }

        It 'logs throttle-aware messaging when Windows refuses due to restore point frequency' {
            Mock Checkpoint-Computer { throw 'A new system restore point cannot be created because one has already been created within the past 1440 minutes.' }
            Mock Get-ItemProperty {
                [PSCustomObject]@{ SystemRestorePointCreationFrequency = 720 }
            } -ParameterFilter { $Name -eq 'SystemRestorePointCreationFrequency' }

            New-SafetyRestorePoint

            ($script:RestorePointLogs -join "`n") | Should -Match 'WARN\|System Restore point skipped by Windows throttle interval \(720 minutes\)'
        }

        It 'recognizes SystemRestorePointCreationFrequency errors' {
            Test-SystemRestoreThrottleError -Message 'SystemRestorePointCreationFrequency policy blocked this request.' | Should -Be $true
        }
    }

    Describe 'DefenderServices configuration' {
        It 'does not contain any firewall services' {
            foreach ($s in $script:DefenderServices) {
                $script:RefuseTouchServices | Should -Not -Contain $s
            }
        }

        It 'does not contain Sense in the base list' {
            $script:DefenderServices | Should -Not -Contain 'Sense'
        }

        It 'contains Sense in the MDE list' {
            $script:MDEServices | Should -Contain 'Sense'
        }
    }

    Describe 'SafeBoot removal verification' {
        BeforeEach {
            $script:SafeBootMin = 'HKLM:\SYSTEM\CurrentControlSet\Control\SafeBoot\Minimal\WinDefend'
            $script:SafeBootNet = 'HKLM:\SYSTEM\CurrentControlSet\Control\SafeBoot\Network\WinDefend'
            $script:SafeBootPresent = @{
                $script:SafeBootMin = $true
                $script:SafeBootNet = $false
            }
            Mock Test-Path { [bool]$script:SafeBootPresent[$LiteralPath] }
            Mock Register-RegistryTreeUndo {}
            Mock Remove-Item { throw 'denied' }
            Mock Grant-RegKeyControl { $false }
            Mock Invoke-AsSystem { return $true }
            Mock Write-Log {}
        }

        It 'throws when a SafeBoot WinDefend key remains after SYSTEM fallback' {
            { Remove-SafeBootWinDefend } | Should -Throw -ExpectedMessage '*SafeBoot WinDefend removal failed*'

            Should -Invoke Invoke-AsSystem -Times 1 -Exactly
        }
    }

    Describe 'Restore replay manifest' {
        BeforeEach {
            $script:RestoreManifestPath = Join-Path $TestDrive 'restore-manifest.jsonl'
            $script:AppDir = $TestDrive
            Get-ChildItem -Path $TestDrive -Filter 'restore-manifest*.jsonl' -ErrorAction SilentlyContinue | Remove-Item -Force
            $script:RestoreManifestActive = $false
            $script:RestoreManifestReplayMode = $false
            $script:RestoreManifestRunId = $null
            $script:RestoreManifestSequence = 0
            $script:RestoreManifestMode = $null
        }

        It 'writes JSONL undo entries with sequence numbers' {
            Start-RestoreManifest -Mode Disable
            Write-RestoreManifestEntry -Phase 'Services' -Action 'SetServiceStart' -Target 'WinDefend' -Data ([ordered]@{
                Service = 'WinDefend'
                State   = 'Automatic'
            })
            Stop-RestoreManifest

            $entries = @(Read-RestoreManifestEntries)
            $entries.Count | Should -Be 1
            $entries[0].Sequence | Should -Be 1
            $entries[0].Action | Should -Be 'SetServiceStart'
            $entries[0].Data.Service | Should -Be 'WinDefend'
        }

        It 'replays entries in reverse order and archives the manifest' {
            Start-RestoreManifest -Mode Disable
            Write-RestoreManifestEntry -Phase 'Services' -Action 'SetServiceStart' -Target 'FirstService' -Data ([ordered]@{
                Service = 'FirstService'
                State   = 'Manual'
            })
            Write-RestoreManifestEntry -Phase 'Services' -Action 'SetServiceStart' -Target 'SecondService' -Data ([ordered]@{
                Service = 'SecondService'
                State   = 'Automatic'
            })
            Stop-RestoreManifest

            $script:ReplayOrder = @()
            Mock Set-ServiceStart {
                param($Service, $State)
                $script:ReplayOrder += "$Service=$State"
                return $true
            }

            Invoke-RestoreManifest | Should -Be $true
            $script:ReplayOrder | Should -Be @('SecondService=Automatic','FirstService=Manual')
            Test-Path -LiteralPath $script:RestoreManifestPath | Should -Be $false
            Get-ChildItem -Path $TestDrive -Filter 'restore-manifest.restored.*.jsonl' | Should -Not -BeNullOrEmpty
        }

        It 'records absent registry values as remove-value undo entries' {
            Start-RestoreManifest -Mode Disable
            Register-RegistryValueUndo -Path 'HKCU:\Software\DisableDefenderMissingTestKey' -Name 'MissingValue' -Phase 'Policies'
            Stop-RestoreManifest

            $entries = @(Read-RestoreManifestEntries)
            $entries.Count | Should -Be 1
            $entries[0].Action | Should -Be 'RemoveRegistryValue'
            $entries[0].Data.Name | Should -Be 'MissingValue'
        }

        It 'logs manifest integrity markers before replay and when archiving' {
            Start-RestoreManifest -Mode Disable
            Write-RestoreManifestEntry -Phase 'Services' -Action 'SetServiceStart' -Target 'WinDefend' -Data ([ordered]@{
                Service = 'WinDefend'
                State   = 'Automatic'
            })
            Stop-RestoreManifest

            $script:ManifestReplayLogs = @()
            Mock Set-ServiceStart { return $true }
            Mock Write-Log {
                param($Message, $Level)
                $script:ManifestReplayLogs += "$Level|$Message"
            }

            Invoke-RestoreManifest | Should -Be $true

            $joined = $script:ManifestReplayLogs -join "`n"
            $joined | Should -Match 'INFO\|Restore manifest integrity: RunIds=[0-9a-f-]+ Entries=1 SHA256=[0-9a-f]{64}'
            $joined | Should -Match 'INFO\|Archived replayed restore manifest .+RunIds=[0-9a-f-]+; Entries=1; SHA256=[0-9a-f]{64}'
        }

        It 'warns when newest selection leaves older archived manifests' {
            Start-RestoreManifest -Mode Disable
            Write-RestoreManifestEntry -Phase 'Services' -Action 'SetServiceStart' -Target 'WinDefend' -Data ([ordered]@{
                Service = 'WinDefend'
                State   = 'Automatic'
            })
            Stop-RestoreManifest

            Start-RestoreManifest -Mode Disable
            Write-RestoreManifestEntry -Phase 'Services' -Action 'SetServiceStart' -Target 'WinDefend' -Data ([ordered]@{
                Service = 'WinDefend'
                State   = 'Disabled'
            })
            Stop-RestoreManifest

            $archived = @(Get-ChildItem -Path $TestDrive -Filter 'restore-manifest.*.jsonl' | Where-Object { $_.Name -match '^restore-manifest\.\d{14}(?:\.\d+)?\.jsonl$' })
            $archived.Count | Should -Be 1
            $archived[0].LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(-10)
            (Get-Item -LiteralPath $script:RestoreManifestPath).LastWriteTimeUtc = [datetime]::UtcNow

            $script:ReplayOrder = @()
            $script:ManifestReplayLogs = @()
            Mock Set-ServiceStart {
                param($Service, $State)
                $script:ReplayOrder += "$Service=$State"
                return $true
            }
            Mock Write-Log {
                param($Message, $Level)
                $script:ManifestReplayLogs += "$Level|$Message"
            }

            Invoke-RestoreManifest | Should -Be $true

            $script:ReplayOrder | Should -Be @('WinDefend=Disabled')
            Test-Path -LiteralPath $script:RestoreManifestPath | Should -Be $false
            Test-Path -LiteralPath $archived[0].FullName | Should -Be $true
            ($script:ManifestReplayLogs -join "`n") | Should -Match 'WARN\|1 archived restore manifest\(s\) were not selected\..*-ManifestSelection All'
        }

        It 'replays active and archived manifests newest first when selection is All' {
            Start-RestoreManifest -Mode Disable
            Write-RestoreManifestEntry -Phase 'Services' -Action 'SetServiceStart' -Target 'WinDefend' -Data ([ordered]@{
                Service = 'WinDefend'
                State   = 'Automatic'
            })
            Stop-RestoreManifest

            Start-RestoreManifest -Mode Disable
            Write-RestoreManifestEntry -Phase 'Services' -Action 'SetServiceStart' -Target 'WinDefend' -Data ([ordered]@{
                Service = 'WinDefend'
                State   = 'Disabled'
            })
            Stop-RestoreManifest

            $archived = @(Get-ChildItem -Path $TestDrive -Filter 'restore-manifest.*.jsonl' | Where-Object { $_.Name -match '^restore-manifest\.\d{14}(?:\.\d+)?\.jsonl$' })
            $archived.Count | Should -Be 1
            $archived[0].LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(-10)
            (Get-Item -LiteralPath $script:RestoreManifestPath).LastWriteTimeUtc = [datetime]::UtcNow

            $script:ReplayOrder = @()
            Mock Set-ServiceStart {
                param($Service, $State)
                $script:ReplayOrder += "$Service=$State"
                return $true
            }
            Mock Write-Log {}

            Invoke-RestoreManifest -Selection All | Should -Be $true

            $script:ReplayOrder | Should -Be @('WinDefend=Disabled','WinDefend=Automatic')
            Test-Path -LiteralPath $script:RestoreManifestPath | Should -Be $false
            @(Get-ChildItem -Path $TestDrive -Filter 'restore-manifest.*.jsonl' | Where-Object { $_.Name -match '^restore-manifest\.\d{14}(?:\.\d+)?\.jsonl$' }).Count | Should -Be 0
            @(Get-ChildItem -Path $TestDrive -Filter 'restore-manifest.restored.*.jsonl').Count | Should -Be 2
        }

        It 'refuses unexpected actions before replay' {
            $entry = [ordered]@{
                SchemaVersion = 1
                RunId         = [guid]::NewGuid().ToString()
                Sequence      = 1
                Timestamp     = (Get-Date).ToString('o')
                Mode          = 'Disable'
                Phase         = 'Services'
                Action        = 'UnexpectedAction'
                Target        = 'WinDefend'
                Data          = [ordered]@{ Service = 'WinDefend' }
            }
            $entry | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $script:RestoreManifestPath
            Mock Set-ServiceStart { throw 'should not replay' }

            { Invoke-RestoreManifest } | Should -Throw -ExpectedMessage '*unexpected action*'
            Should -Invoke Set-ServiceStart -Times 0 -Exactly
        }

        It 'refuses manifest entries missing required action fields' {
            $entry = [ordered]@{
                SchemaVersion = 1
                RunId         = [guid]::NewGuid().ToString()
                Sequence      = 1
                Timestamp     = (Get-Date).ToString('o')
                Mode          = 'Disable'
                Phase         = 'Services'
                Action        = 'SetServiceStart'
                Target        = 'WinDefend'
                Data          = [ordered]@{ Service = 'WinDefend' }
            }
            $entry | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $script:RestoreManifestPath
            Mock Set-ServiceStart { throw 'should not replay' }

            { Invoke-RestoreManifest } | Should -Throw -ExpectedMessage '*missing Data.State*'
            Should -Invoke Set-ServiceStart -Times 0 -Exactly
        }
    }

    Describe 'Restore verification' {
        BeforeEach {
            $script:RestoreVerificationLogs = @()
            $script:SilentMode = $false
            Mock Write-Log {
                param($Message, $Level)
                $script:RestoreVerificationLogs += "$Level|$Message"
            }
        }

        It 'logs an OK summary when Restore target health is clean' {
            Mock Get-DefenderHealth {
                [ordered]@{
                    Summary = [ordered]@{ OK = 3; Drift = 0; Unknown = 0; Total = 3 }
                    Items = @(
                        [PSCustomObject]@{ Category = 'Service'; Name = 'WinDefend'; Expected = 'Automatic'; Actual = 'Automatic'; Status = 'OK' }
                    )
                }
            }

            { Invoke-RestoreVerification } | Should -Not -Throw

            ($script:RestoreVerificationLogs -join "`n") | Should -Match 'OK\|Restore verification: OK=3 Drift=0 Unknown=0 Total=3'
        }

        It 'logs service and Appx repair commands for failed Restore checks' {
            Mock Get-DefenderHealth {
                [ordered]@{
                    Summary = [ordered]@{ OK = 1; Drift = 2; Unknown = 0; Total = 3 }
                    Items = @(
                        [PSCustomObject]@{ Category = 'Service'; Name = 'WinDefend'; Expected = 'Automatic'; Actual = 'Disabled'; Status = 'Drift' },
                        [PSCustomObject]@{ Category = 'Appx'; Name = 'Microsoft.SecHealthUI'; Expected = 'Present'; Actual = 'Absent'; Status = 'Drift' }
                    )
                }
            }

            { Invoke-RestoreVerification } | Should -Not -Throw

            $joined = $script:RestoreVerificationLogs -join "`n"
            $joined | Should -Match 'WARN\|Restore verification: OK=1 Drift=2 Unknown=0 Total=3'
            $joined | Should -Match 'Repair command: sc\.exe config WinDefend start= auto'
            $joined | Should -Match 'Repair command: sfc /scannow'
            $joined | Should -Match 'Repair command: DISM /Online /Cleanup-Image /RestoreHealth'
        }

        It 'throws in silent mode when Restore verification fails' {
            $script:SilentMode = $true
            try {
                Mock Get-DefenderHealth {
                    [ordered]@{
                        Summary = [ordered]@{ OK = 0; Drift = 1; Unknown = 0; Total = 1 }
                        Items = @(
                            [PSCustomObject]@{ Category = 'Service'; Name = 'WinDefend'; Expected = 'Automatic'; Actual = 'Disabled'; Status = 'Drift' }
                        )
                    }
                }

                { Invoke-RestoreVerification } | Should -Throw -ExpectedMessage '*Restore verification failed*'
            } finally {
                $script:SilentMode = $false
            }
        }
    }

    Describe 'Atomic phase runner' {
        BeforeEach {
            $script:PhaseStatePath = Join-Path $TestDrive 'phase-state.json'
            $script:AppDir = $TestDrive
            Mock Assert-FirewallSafety {}
        }

        It 'records completed phase boundaries' {
            $phases = @(
                New-DefenderPhase -Name 'First' -Action { $script:PhaseTestValue = 1 }
                New-DefenderPhase -Name 'Second' -Action { $script:PhaseTestValue = 2 }
            )

            Invoke-DefenderPhasePlan -Mode Disable -Phases $phases

            $state = Get-Content -Raw -LiteralPath $script:PhaseStatePath | ConvertFrom-Json
            $state.Status | Should -Be 'Completed'
            $state.Phases.Count | Should -Be 2
            $state.Phases[0].Status | Should -Be 'Completed'
            $state.Phases[1].Status | Should -Be 'Completed'
            $script:PhaseTestValue | Should -Be 2
            Should -Invoke Assert-FirewallSafety -Times 4 -Exactly
        }

        It 'records failed phase, partial state, and rethrows' {
            Mock Get-DefenderStatus {
                [ordered]@{
                    firewall_Domain = $true
                    svc_WinDefend   = 'Running / Automatic'
                }
            }
            $phases = @(
                New-DefenderPhase -Name 'First' -Action { $script:PhaseFailureReached = $true }
                New-DefenderPhase -Name 'Broken' -Action { throw 'boom' }
            )

            { Invoke-DefenderPhasePlan -Mode Remove -Phases $phases } | Should -Throw 'boom'

            $state = Get-Content -Raw -LiteralPath $script:PhaseStatePath | ConvertFrom-Json
            $state.Status | Should -Be 'Failed'
            $state.FailedPhase | Should -Be 'Broken'
            $state.Phases[1].Status | Should -Be 'Failed'
            $state.PartialState.firewall_Domain | Should -Be $true
            $state.PartialState.svc_WinDefend | Should -Be 'Running / Automatic'
            Should -Invoke Assert-FirewallSafety -Times 3 -Exactly
        }

        It 'runs only matching phase keys and records skipped phases' {
            $script:FilterRun = @()
            $phases = @(
                New-DefenderPhase -Name 'Policy keys' -Key 'Policies' -Action { $script:FilterRun += 'Policies' }
                New-DefenderPhase -Name 'Services' -Key 'Services' -Action { $script:FilterRun += 'Services' }
                New-DefenderPhase -Name 'Tasks' -Key 'Tasks' -Action { $script:FilterRun += 'Tasks' }
            )

            Invoke-DefenderPhasePlan -Mode Disable -Phases $phases -Only Services

            $script:FilterRun | Should -Be @('Services')
            $state = Get-Content -Raw -LiteralPath $script:PhaseStatePath | ConvertFrom-Json
            $state.Status | Should -Be 'Completed'
            $state.Only | Should -Be @('Services')
            $state.Phases[0].Status | Should -Be 'Skipped'
            $state.Phases[0].SkipReason | Should -Be 'Only'
            $state.Phases[1].Status | Should -Be 'Completed'
            $state.Phases[2].Status | Should -Be 'Skipped'
            Should -Invoke Assert-FirewallSafety -Times 2 -Exactly
        }

        It 'skips matching phase keys and fails when filters select nothing' {
            $phases = @(
                New-DefenderPhase -Name 'Services' -Key 'Services' -Action { $script:SkipRun = $true }
            )

            { Invoke-DefenderPhasePlan -Mode Disable -Phases $phases -Skip Services } | Should -Throw 'Phase filters selected no runnable phases.'

            $state = Get-Content -Raw -LiteralPath $script:PhaseStatePath | ConvertFrom-Json
            $state.Status | Should -Be 'Failed'
            $state.Phases[0].Status | Should -Be 'Skipped'
            $state.Phases[0].SkipReason | Should -Be 'Skip'
        }
    }
}

InModuleScope DisableDefender {
    Describe 'New-OfflineRemoveBundle' {
        BeforeAll {
            $script:BundleDir = Join-Path $TestDrive 'offline-bundle'
        }

        It 'generates a valid PowerShell script' {
            $result = New-OfflineRemoveBundle -OutputDirectory $script:BundleDir

            $result.ScriptPath | Should -Not -BeNullOrEmpty
            Test-Path -LiteralPath $result.ScriptPath | Should -Be $true
            $result.Version | Should -Be (Test-ModuleManifest -Path (Join-Path $PSScriptRoot '..\DisableDefender.psd1')).Version.ToString()

            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($result.ScriptPath, [ref]$null, [ref]$errors)
            $errors.Count | Should -Be 0
        }

        It 'embeds the firewall refuse-list in the generated script' {
            $result = New-OfflineRemoveBundle -OutputDirectory $script:BundleDir
            $content = Get-Content -LiteralPath $result.ScriptPath -Raw

            $content | Should -Match 'mpssvc'
            $content | Should -Match 'BFE'
            $content | Should -Match 'SharedAccess'
            $content | Should -Match 'REFUSED firewall'
        }

        It 'embeds the full Defender service list' {
            $result = New-OfflineRemoveBundle -OutputDirectory $script:BundleDir
            $content = Get-Content -LiteralPath $result.ScriptPath -Raw

            $content | Should -Match 'WinDefend'
            $content | Should -Match 'WdFilter'
            $content | Should -Match 'WdBoot'
            $content | Should -Match 'MDCoreSvc'
            $content | Should -Match 'Sense'
        }

        It 'includes live system drive refusal logic' {
            $result = New-OfflineRemoveBundle -OutputDirectory $script:BundleDir
            $content = Get-Content -LiteralPath $result.ScriptPath -Raw

            $content | Should -Match 'live system drive'
            $content | Should -Match 'SystemDrive'
            $content | Should -Match 'offline volumes only'
        }

        It 'includes all major policy key paths' {
            $result = New-OfflineRemoveBundle -OutputDirectory $script:BundleDir
            $content = Get-Content -LiteralPath $result.ScriptPath -Raw

            $content | Should -Match 'DisableAntiSpyware'
            $content | Should -Match 'DisableRealtimeMonitoring'
            $content | Should -Match 'DisableBehaviorMonitoring'
            $content | Should -Match 'SpyNetReporting'
            $content | Should -Match 'ForceDefenderPassiveMode'
            $content | Should -Match 'EnableSmartScreen'
        }

        It 'documents offline limitations' {
            $result = New-OfflineRemoveBundle -OutputDirectory $script:BundleDir
            $content = Get-Content -LiteralPath $result.ScriptPath -Raw

            $content | Should -Match 'Set-MpPreference'
            $content | Should -Match 'Task Scheduler'
            $content | Should -Match 'Appx'
            $content | Should -Match 'DISM'
        }
    }
}

InModuleScope DisableDefender {
    Describe 'Compare-DefenderSnapshots' {
        It 'detects changes between two snapshots' {
            $baseline = [ordered]@{
                SchemaVersion = 1
                Timestamp = '2026-06-01T00:00:00.0000000-04:00'
                Version = '0.0.39'
                HealthItems = @(
                    [ordered]@{ Category = 'Service'; Name = 'WinDefend'; Expected = 'Disabled'; Actual = 'Disabled'; Status = 'OK' },
                    [ordered]@{ Category = 'Policy'; Name = 'DisableAntiSpyware'; Expected = '1'; Actual = '1'; Status = 'OK' }
                )
            }
            $current = [ordered]@{
                SchemaVersion = 1
                Timestamp = '2026-06-30T00:00:00.0000000-04:00'
                Version = '0.0.39'
                HealthItems = @(
                    [ordered]@{ Category = 'Service'; Name = 'WinDefend'; Expected = 'Disabled'; Actual = 'Automatic'; Status = 'Drift' },
                    [ordered]@{ Category = 'Policy'; Name = 'DisableAntiSpyware'; Expected = '1'; Actual = '1'; Status = 'OK' },
                    [ordered]@{ Category = 'Policy'; Name = 'NewPolicy'; Expected = '1'; Actual = 'absent'; Status = 'Drift' }
                )
            }

            $baseFile = Join-Path $TestDrive 'baseline.json'
            $currFile = Join-Path $TestDrive 'current.json'
            $baseline | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $baseFile -Encoding UTF8
            $current | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $currFile -Encoding UTF8

            $result = Compare-DefenderSnapshots -BaselinePath $baseFile -CurrentPath $currFile

            $result.ChangedCount | Should -Be 2
            $changed = $result.Diffs | Where-Object { $_.Change -eq 'Changed' }
            $changed.Name | Should -Contain 'WinDefend'
            $added = $result.Diffs | Where-Object { $_.Change -eq 'Added' }
            $added.Name | Should -Contain 'NewPolicy'
        }
    }
}

InModuleScope DisableDefender {
    Describe 'Export-DefenderHtmlReport' {
        It 'produces a valid HTML file with health data' {
            Mock Get-DefenderHealth {
                [ordered]@{
                    Target  = 'Disable'
                    Summary = [ordered]@{ OK = 2; Drift = 1; Unknown = 0; Total = 3 }
                    Items   = @(
                        [PSCustomObject]@{ Category = 'Service'; Name = 'WinDefend'; Expected = 'Disabled'; Actual = 'Disabled'; Status = 'OK' },
                        [PSCustomObject]@{ Category = 'Policy'; Name = 'DisableAntiSpyware'; Expected = '1'; Actual = '1'; Status = 'OK' },
                        [PSCustomObject]@{ Category = 'Task'; Name = 'Scheduled Scan'; Expected = 'Disabled'; Actual = 'Ready'; Status = 'Drift' }
                    )
                }
            }
            Mock Get-DefenderComponentStatus {
                @([PSCustomObject]@{ Name = 'MsMpEng'; Service = 'WinDefend'; Status = 'Stopped'; PPLStatus = 'None' })
            }

            $reportPath = Join-Path $TestDrive 'report.html'
            $result = Export-DefenderHtmlReport -OutputPath $reportPath

            $result.ReportPath | Should -Be $reportPath
            Test-Path -LiteralPath $reportPath | Should -Be $true

            $content = Get-Content -LiteralPath $reportPath -Raw
            $content | Should -Match '<!DOCTYPE html>'
            $content | Should -Match 'DisableDefender Report'
            $content | Should -Match 'OK=2'
            $content | Should -Match 'Drift=1'
            $content | Should -Match 'WinDefend'
            $content | Should -Match 'MsMpEng'
        }
    }
}

InModuleScope DisableDefender {
    Describe 'Data-driven policy catalog' {
        It 'catalog is the single source for both write and health' {
            $catalog = @(Get-DefenderPolicyCatalog)
            $health  = @(Get-ExpectedPolicyValues)

            $catalog.Count | Should -BeGreaterThan 30
            $catalog.Count | Should -Be $health.Count

            for ($i = 0; $i -lt $catalog.Count; $i++) {
                $catalog[$i].Path | Should -Be $health[$i].Path
                $catalog[$i].Name | Should -Be $health[$i].Name
                $catalog[$i].Value | Should -Be $health[$i].Value
            }
        }

        It 'every catalog entry has Path, Name, and Value' {
            foreach ($entry in Get-DefenderPolicyCatalog) {
                $entry.Path | Should -Not -BeNullOrEmpty
                $entry.Name | Should -Not -BeNullOrEmpty
                $entry.ContainsKey('Value') | Should -Be $true
            }
        }
    }
}

InModuleScope DisableDefender {
    Describe 'Third-party AV detection' {
        It 'returns empty when only Windows Defender is registered' {
            Mock Get-CimInstance {
                @([PSCustomObject]@{ displayName = 'Windows Defender' })
            } -ParameterFilter { $ClassName -eq 'AntiVirusProduct' }

            $result = @(Get-RegisteredAntiVirusProducts)
            $result.Count | Should -Be 0
        }

        It 'returns third-party AV products' {
            Mock Get-CimInstance {
                @(
                    [PSCustomObject]@{ displayName = 'Windows Defender' },
                    [PSCustomObject]@{ displayName = 'Norton Security' }
                )
            } -ParameterFilter { $ClassName -eq 'AntiVirusProduct' }

            $result = @(Get-RegisteredAntiVirusProducts)
            $result.Count | Should -Be 1
            $result[0].displayName | Should -Be 'Norton Security'
        }
    }

    Describe 'MDE passive-mode detection' {
        It 'returns true when ForceDefenderPassiveMode policy is set' {
            Mock Test-Path { $true }
            Mock Get-ItemProperty { [PSCustomObject]@{ ForceDefenderPassiveMode = 1 } }

            Test-MdePassiveMode | Should -Be $true
        }

        It 'returns false when no passive-mode indicators exist' {
            Mock Test-Path { $false }
            Mock Get-MpComputerStatus { throw 'Not available' }

            Test-MdePassiveMode | Should -Be $false
        }
    }
}

InModuleScope DisableDefender {
    Describe 'Export-DefenderSupportBundle' {
        It 'produces a zip with summary and health data' {
            Mock Get-DefenderHealth {
                [ordered]@{
                    Target  = 'Disable'
                    Summary = [ordered]@{ OK = 1; Drift = 0; Unknown = 0; Total = 1 }
                    Items   = @([PSCustomObject]@{ Category = 'Service'; Name = 'WinDefend'; Expected = 'Disabled'; Actual = 'Disabled'; Status = 'OK' })
                }
            }
            Mock Get-DefenderComponentStatus {
                @([PSCustomObject]@{ Name = 'MsMpEng'; Service = 'WinDefend'; Status = 'Stopped' })
            }

            $result = Export-DefenderSupportBundle -OutputDirectory $TestDrive

            $result.ZipPath | Should -Not -BeNullOrEmpty
            Test-Path -LiteralPath $result.ZipPath | Should -Be $true

            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [System.IO.Compression.ZipFile]::OpenRead($result.ZipPath)
            try {
                $entries = @($zip.Entries | ForEach-Object { $_.Name })
                $entries | Should -Contain 'summary.json'
                $entries | Should -Contain 'health.json'
                $entries | Should -Contain 'components.json'
            } finally {
                $zip.Dispose()
            }
        }

        It 'excludes restore manifests and ACL backups from the bundle' {
            Mock Get-DefenderHealth { [ordered]@{ Target = 'Disable'; Summary = [ordered]@{ OK = 0; Drift = 0; Unknown = 0; Total = 0 }; Items = @() } }
            Mock Get-DefenderComponentStatus { @() }

            $result = Export-DefenderSupportBundle -OutputDirectory $TestDrive

            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [System.IO.Compression.ZipFile]::OpenRead($result.ZipPath)
            try {
                $entries = @($zip.Entries | ForEach-Object { $_.Name })
                $entries | Should -Not -Contain 'restore-manifest.jsonl'
                $entries | Should -Not -Contain 'acl-backup.clixml'
            } finally {
                $zip.Dispose()
            }
        }
    }
}

InModuleScope DisableDefender {
    Describe 'Language mode and App Control preflight' {
        BeforeEach {
            $script:ForceMode = $false
            Mock Write-Log {}
        }

        It 'passes in FullLanguage mode' {
            Mock Test-LanguageMode { 'FullLanguage' }
            Mock Test-AppControlPolicy { 'Off' }

            { Confirm-LanguageAndAppControl } | Should -Not -Throw
        }

        It 'blocks ConstrainedLanguage mode without Force' {
            Mock Test-LanguageMode { 'ConstrainedLanguage' }
            Mock Test-AppControlPolicy { 'Off' }

            { Confirm-LanguageAndAppControl } | Should -Throw -ExpectedMessage '*ConstrainedLanguage*'
        }

        It 'allows ConstrainedLanguage mode with Force' {
            $script:ForceMode = $true
            Mock Test-LanguageMode { 'ConstrainedLanguage' }
            Mock Test-AppControlPolicy { 'Off' }

            { Confirm-LanguageAndAppControl } | Should -Not -Throw
        }

        It 'blocks unknown language modes without Force' {
            Mock Test-LanguageMode { 'RestrictedLanguage' }
            Mock Test-AppControlPolicy { 'Off' }

            { Confirm-LanguageAndAppControl } | Should -Throw -ExpectedMessage '*RestrictedLanguage*'
        }

        It 'logs Smart App Control status when present' {
            $script:LangLogs = @()
            Mock Test-LanguageMode { 'FullLanguage' }
            Mock Test-AppControlPolicy { 'Enforcing' }
            Mock Write-Log {
                param($Message, $Level)
                $script:LangLogs += "$Level|$Message"
            }

            { Confirm-LanguageAndAppControl } | Should -Not -Throw

            ($script:LangLogs -join "`n") | Should -Match 'WARN\|Smart App Control / App Control: Enforcing'
        }
    }
}

InModuleScope DisableDefender {
    Describe 'Error contract exit-code table' {
        It 'maps Tamper Protection errors to exit code 2' {
            $mapping = Get-DefenderErrorMapping -Message 'Tamper Protection blocks changes. Disable it manually, then retry.'
            $mapping.ExitCode | Should -Be 2
            $mapping.Code | Should -Be 'TAMPER_PROTECTION'
            $mapping.Repair.Count | Should -BeGreaterThan 0
        }

        It 'maps Safe Mode errors to exit code 3' {
            $mapping = Get-DefenderErrorMapping -Message 'Remove mode requires Safe Mode or -Force.'
            $mapping.ExitCode | Should -Be 3
            $mapping.Code | Should -Be 'SAFE_MODE_REQUIRED'
        }

        It 'maps Firewall errors to exit code 4' {
            $mapping = Get-DefenderErrorMapping -Message 'Firewall integrity check failed at pre stage.'
            $mapping.ExitCode | Should -Be 4
            $mapping.Code | Should -Be 'FIREWALL_INTEGRITY'
        }

        It 'maps managed device errors to exit code 5' {
            $mapping = Get-DefenderErrorMapping -Message 'This device is managed (Intune/MDM enrolled). Use -Force to proceed anyway.'
            $mapping.ExitCode | Should -Be 5
            $mapping.Code | Should -Be 'MANAGED_DEVICE'
        }

        It 'maps Restore verification errors to exit code 6' {
            $mapping = Get-DefenderErrorMapping -Message 'Restore verification failed: Drift=3'
            $mapping.ExitCode | Should -Be 6
            $mapping.Code | Should -Be 'RESTORE_FAILED'
        }

        It 'maps phase filter errors to exit code 7' {
            $mapping = Get-DefenderErrorMapping -Message 'Phase filters selected no runnable phases.'
            $mapping.ExitCode | Should -Be 7
            $mapping.Code | Should -Be 'PHASE_FILTER_EMPTY'
        }

        It 'maps remoting errors to exit code 8' {
            $mapping = Get-DefenderErrorMapping -Message 'Execution refused in PSRemoting context. Use -AllowRemoting.'
            $mapping.ExitCode | Should -Be 8
            $mapping.Code | Should -Be 'REMOTING_BLOCKED'
        }

        It 'maps unknown errors to exit code 1' {
            $mapping = Get-DefenderErrorMapping -Message 'Something unexpected happened.'
            $mapping.ExitCode | Should -Be 1
            $mapping.Code | Should -Be 'UNKNOWN'
        }

        It 'produces a stable JSON error envelope' {
            $envelope = New-DefenderErrorEnvelope -Message 'Tamper Protection blocks changes.' -Mode 'Disable' -FailedPhase 'Prerequisites'
            $envelope.Ok | Should -Be $false
            $envelope.Mode | Should -Be 'Disable'
            $envelope.ExitCode | Should -Be 2
            $envelope.ErrorCode | Should -Be 'TAMPER_PROTECTION'
            $envelope.Message | Should -Be 'Tamper Protection blocks changes.'
            $envelope.FailedPhase | Should -Be 'Prerequisites'
            $envelope.RepairCommands.Count | Should -BeGreaterThan 0
            $envelope.Timestamp | Should -Not -BeNullOrEmpty

            $json = $envelope | ConvertTo-Json -Depth 4
            $parsed = $json | ConvertFrom-Json
            $parsed.Ok | Should -Be $false
            $parsed.ErrorCode | Should -Be 'TAMPER_PROTECTION'
        }
    }
}

Describe 'DisableDefender GUI safety wiring' {
    BeforeAll {
        $script:GuiSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\DisableDefender.GUI.ps1') -Raw
    }

    It 'does not force Disable or Remove from the GUI by default' {
        $script:GuiSource | Should -Not -Match "Invoke-DisableDefender\s+-Force\s"
        $script:GuiSource | Should -Not -Match "Invoke-RemoveDefender\s+-Force\s"
    }

    It 'passes force only through the explicit override checkbox state' {
        $script:GuiSource | Should -Match 'confirmForceOverride'
        $script:GuiSource | Should -Match 'Start-ModeAsync\s+-ActionMode ''Disable''\s+-ForceOverride:\$script:ConfirmForceOverride'
        $script:GuiSource | Should -Match 'Invoke-DisableDefender\s+-Force:\$ForceOverride'
        $script:GuiSource | Should -Match 'Invoke-RemoveDefender\s+-Force:\$ForceOverride'
    }
}
