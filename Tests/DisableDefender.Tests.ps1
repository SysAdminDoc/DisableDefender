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
            'Get-DefenderHealth'
            'Get-DefenderStatus'
            'Invoke-DisableDefender'
            'Invoke-RemoveDefender'
            'Invoke-RestoreDefender'
            'Show-DefenderStatus'
        ) | Sort-Object
        $actual = (Get-Command -Module DisableDefender -CommandType Function).Name | Sort-Object
        $actual | Should -Be $expected
    }
}

InModuleScope DisableDefender {
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

    Describe 'Restore replay manifest' {
        BeforeEach {
            $script:RestoreManifestPath = Join-Path $TestDrive 'restore-manifest.jsonl'
            $script:AppDir = $TestDrive
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
