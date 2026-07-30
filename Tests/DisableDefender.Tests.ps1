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
                $result = Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall\DomainProfile' -Name 'Test' -Value 1

                $result.Succeeded | Should -Be $false
                $result.Effects[0].Verified | Should -Be $false
                Should -Invoke New-ItemProperty -Times 0 -Exactly
            }

            It 'refuses to write to firewall service paths' {
                Mock New-ItemProperty {}
                Mock New-Item {}
                $result = Set-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\mpssvc\Parameters' -Name 'Test' -Value 1

                $result.Succeeded | Should -Be $false
                Should -Invoke New-ItemProperty -Times 0 -Exactly
            }

            It 'allows writing to Defender policy paths' {
                Mock New-ItemProperty {}
                Mock Test-Path { $true }
                Mock Get-ItemProperty { [PSCustomObject]@{ DisableAntiSpyware = 0 } }
                Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -Name 'DisableAntiSpyware' -Value 1
                Should -Invoke New-ItemProperty -Times 1 -Exactly
            }
        }

        Context 'Postcondition verification' {
            BeforeEach {
                Mock Test-Path { $true }
                Mock Register-RegistryValueUndo {}
                Mock Write-Log {}
            }

            It 'does not write an already-correct value and records a verified no-op' {
                Mock Get-ItemProperty { [PSCustomObject]@{ Test = 1 } }
                Mock New-ItemProperty {}

                $result = Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' `
                    -Name 'Test' -Value 1

                $result.Succeeded | Should -Be $true
                $result.Attempted | Should -Be 0
                $result.Changed | Should -Be 0
                $result.Verified | Should -Be 1
                Should -Invoke New-ItemProperty -Times 0 -Exactly
            }

            It 'reports a changed value only after the readback matches' {
                $script:RegistryTestValue = 0
                Mock Get-ItemProperty { [PSCustomObject]@{ Test = $script:RegistryTestValue } }
                Mock New-ItemProperty { $script:RegistryTestValue = $Value }

                $result = Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' `
                    -Name 'Test' -Value 1

                $result.Succeeded | Should -Be $true
                $result.Attempted | Should -Be 1
                $result.Changed | Should -Be 1
                $result.Verified | Should -Be 1
                $result.Effects[0].Evidence.Actual | Should -Be 1
            }

            It 'fails when a write returns without reaching the requested value' {
                Mock Get-ItemProperty { [PSCustomObject]@{ Test = 0 } }
                Mock New-ItemProperty {}

                $result = Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' `
                    -Name 'Test' -Value 1

                $result.Succeeded | Should -Be $false
                $result.Attempted | Should -Be 1
                $result.Changed | Should -Be 0
                $result.Verified | Should -Be 0
                $result.Errors[0] | Should -Match 'did not converge'
            }

            It 'fails closed without writing when the original value cannot be read' {
                Mock Get-ItemProperty { throw [System.UnauthorizedAccessException]::new('denied') }
                Mock New-ItemProperty {}

                $result = Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' `
                    -Name 'Test' -Value 1

                $result.Succeeded | Should -Be $false
                $result.Attempted | Should -Be 0
                Should -Invoke New-ItemProperty -Times 0 -Exactly
                Should -Invoke Register-RegistryValueUndo -Times 0 -Exactly
            }
        }
    }

    Describe 'MpPreference effect verification' {
        BeforeEach {
            Mock Get-MpRuntimeExclusionCatalog { @() }
            Mock Test-RestoreManifestRecording { $false }
            Mock Write-Log {}
        }

        It 'verifies a preference after changing it' {
            $script:MpRealtimeValue = $false
            Mock Get-MpRuntimePreferenceCatalog {
                @([PSCustomObject]@{
                    Name = 'DisableRealtimeMonitoring'
                    DisableValue = $true
                    RestoreValue = $false
                })
            }
            Mock Get-MpPreference {
                [PSCustomObject]@{ DisableRealtimeMonitoring = $script:MpRealtimeValue }
            }
            Mock Set-MpPreference { $script:MpRealtimeValue = $DisableRealtimeMonitoring }

            $result = Set-MpRuntimePrefs

            $result.Succeeded | Should -Be $true
            $result.Attempted | Should -Be 1
            $result.Changed | Should -Be 1
            $result.Verified | Should -Be 1
            Should -Invoke Get-MpPreference -Times 2 -Exactly
        }

        It 'records an already-correct preference without calling the mutator' {
            Mock Get-MpRuntimePreferenceCatalog {
                @([PSCustomObject]@{
                    Name = 'DisableRealtimeMonitoring'
                    DisableValue = $true
                    RestoreValue = $false
                })
            }
            Mock Get-MpPreference {
                [PSCustomObject]@{ DisableRealtimeMonitoring = $true }
            }
            Mock Set-MpPreference {}

            $result = Set-MpRuntimePrefs

            $result.Succeeded | Should -Be $true
            $result.Attempted | Should -Be 0
            $result.Changed | Should -Be 0
            $result.Verified | Should -Be 1
            Should -Invoke Set-MpPreference -Times 0 -Exactly
        }

        It 'reports partial convergence as failure' {
            $script:MpRealtimeValue = $false
            $script:MpBehaviorValue = $false
            $script:MpSetCall = 0
            Mock Get-MpRuntimePreferenceCatalog {
                @(
                    [PSCustomObject]@{ Name = 'DisableRealtimeMonitoring'; DisableValue = $true; RestoreValue = $false }
                    [PSCustomObject]@{ Name = 'DisableBehaviorMonitoring'; DisableValue = $true; RestoreValue = $false }
                )
            }
            Mock Get-MpPreference {
                [PSCustomObject]@{
                    DisableRealtimeMonitoring = $script:MpRealtimeValue
                    DisableBehaviorMonitoring = $script:MpBehaviorValue
                }
            }
            Mock Set-MpPreference {
                $script:MpSetCall++
                if ($script:MpSetCall -eq 1) {
                    $script:MpRealtimeValue = $true
                }
            }

            $result = Set-MpRuntimePrefs

            $result.Succeeded | Should -Be $false
            $result.Attempted | Should -Be 2
            $result.Changed | Should -Be 1
            $result.Verified | Should -Be 1
            ($result.Effects | Where-Object Target -eq 'DisableBehaviorMonitoring').Errors[0] |
                Should -Match 'did not converge'
        }

        It 'fails without mutation when preferences cannot be queried' {
            Mock Get-MpRuntimePreferenceCatalog {
                @([PSCustomObject]@{
                    Name = 'DisableRealtimeMonitoring'
                    DisableValue = $true
                    RestoreValue = $false
                })
            }
            Mock Get-MpPreference { throw 'Defender provider unavailable' }
            Mock Set-MpPreference {}

            $result = Set-MpRuntimePrefs

            $result.Succeeded | Should -Be $false
            $result.Effects[0].Target | Should -Be 'Get-MpPreference'
            Should -Invoke Set-MpPreference -Times 0 -Exactly
        }

        It 'verifies exclusions are removed during restore' {
            $script:MpExclusionPaths = @('C:\')
            Mock Get-MpRuntimePreferenceCatalog { @() }
            Mock Get-MpRuntimeExclusionCatalog {
                @([PSCustomObject]@{ Parameter = 'ExclusionPath'; Values = @('C:\') })
            }
            Mock Get-MpPreference {
                [PSCustomObject]@{ ExclusionPath = @($script:MpExclusionPaths) }
            }
            Mock Remove-MpPreference { $script:MpExclusionPaths = @() }

            $result = Clear-MpRuntimePrefs

            $result.Succeeded | Should -Be $true
            $result.Attempted | Should -Be 1
            $result.Changed | Should -Be 1
            $result.Effects[0].Evidence.Actual | Should -Be 'Absent'
        }
    }

    Describe 'Scheduled task effect verification' {
        BeforeEach {
            $script:OriginalDefenderTasks = $script:DefenderTasks
            $script:DefenderTasks = @('\Microsoft\Windows\Windows Defender\Test Task')
            Mock Test-RestoreManifestRecording { $false }
            Mock Write-Log {}
        }

        AfterEach {
            $script:DefenderTasks = $script:OriginalDefenderTasks
        }

        It 'verifies a task after disabling it' {
            $script:TaskTestState = 'Ready'
            Mock Get-ScheduledTask { [PSCustomObject]@{ State = $script:TaskTestState } }
            Mock Disable-ScheduledTask { $script:TaskTestState = 'Disabled' }
            Mock Invoke-DefenderScheduledTaskFallback { 0 }

            $result = Disable-DefenderTasks

            $result.Succeeded | Should -Be $true
            $result.Attempted | Should -Be 1
            $result.Changed | Should -Be 1
            $result.Verified | Should -Be 1
            Should -Invoke Invoke-DefenderScheduledTaskFallback -Times 0 -Exactly
        }

        It 'records an absent task as a verified not-applicable effect' {
            Mock Get-ScheduledTask { throw 'task not found' }
            Mock Disable-ScheduledTask {}
            Mock Invoke-DefenderScheduledTaskFallback { 1 }

            $result = Disable-DefenderTasks

            $result.Succeeded | Should -Be $true
            $result.Attempted | Should -Be 0
            $result.Effects[0].Required | Should -Be $false
            $result.Effects[0].Evidence.Actual | Should -Be 'Absent'
            Should -Invoke Disable-ScheduledTask -Times 0 -Exactly
        }

        It 'uses the native fallback when the cmdlet does not converge' {
            $script:TaskTestState = 'Ready'
            Mock Get-ScheduledTask { [PSCustomObject]@{ State = $script:TaskTestState } }
            Mock Disable-ScheduledTask {}
            Mock Invoke-DefenderScheduledTaskFallback {
                $script:TaskTestState = 'Disabled'
                return 0
            }

            $result = Disable-DefenderTasks

            $result.Succeeded | Should -Be $true
            $result.Effects[0].Evidence.NativeExitCode | Should -Be 0
            Should -Invoke Invoke-DefenderScheduledTaskFallback -Times 1 -Exactly
        }

        It 'fails when neither mutation path reaches the requested state' {
            Mock Get-ScheduledTask { [PSCustomObject]@{ State = 'Ready' } }
            Mock Disable-ScheduledTask { throw 'access denied' }
            Mock Invoke-DefenderScheduledTaskFallback { 5 }

            $result = Disable-DefenderTasks

            $result.Succeeded | Should -Be $false
            $result.Verified | Should -Be 0
            $result.Errors[0] | Should -Match 'exited 5'
        }
    }

    Describe 'Set-ServiceStart' {
        Context 'Refuse-list guard' {
            It 'refuses to modify firewall services' {
                $result = Set-ServiceStart -Service 'mpssvc' -State 'Disabled'
                $result.Succeeded | Should -Be $false
                $result.Effects[0].Verified | Should -Be $false
            }

            It 'refuses to modify BFE' {
                $result = Set-ServiceStart -Service 'BFE' -State 'Disabled'
                $result.Succeeded | Should -Be $false
            }

            It 'refuses to modify SharedAccess' {
                $result = Set-ServiceStart -Service 'SharedAccess' -State 'Disabled'
                $result.Succeeded | Should -Be $false
            }
        }

        Context 'Absent service' {
            It 'returns a verified not-applicable result for services not present on the system' {
                Mock Test-Path { $false }
                $result = Set-ServiceStart -Service 'FakeDefenderService' -State 'Disabled'
                $result.Succeeded | Should -Be $true
                $result.Attempted | Should -Be 0
                $result.Effects[0].Required | Should -Be $false
                $result.Effects[0].Evidence.Actual | Should -Be 'Absent'
            }
        }

        Context 'Target verification' {
            It 'returns a failed result when SYSTEM fallback reports success but Start value does not change' {
                Mock Test-Path { $true }
                Mock Set-ItemProperty { throw 'denied' }
                Mock Grant-RegKeyControl { $false }
                Mock Invoke-AsSystem { return $true }
                Mock Get-ItemProperty { [PSCustomObject]@{ Start = 3 } }
                Mock Write-Log {}

                $result = Set-ServiceStart -Service 'WinDefend' -State 'Disabled'

                $result.Succeeded | Should -Be $false
                $result.Verified | Should -Be 0
                Should -Invoke Invoke-AsSystem -Times 1 -Exactly
            }

            It 'returns a verified no-op when the Start value is already correct' {
                Mock Test-Path { $true }
                Mock Get-ItemProperty { [PSCustomObject]@{ Start = 4 } }
                Mock Set-ItemProperty {}

                $result = Set-ServiceStart -Service 'WinDefend' -State 'Disabled'

                $result.Succeeded | Should -Be $true
                $result.Attempted | Should -Be 0
                $result.Verified | Should -Be 1
                Should -Invoke Set-ItemProperty -Times 0 -Exactly
            }

            It 'verifies the direct Start-value write before reporting success' {
                $script:ServiceStartTestValue = 3
                Mock Test-Path { $true }
                Mock Get-ItemProperty { [PSCustomObject]@{ Start = $script:ServiceStartTestValue } }
                Mock Set-ItemProperty { $script:ServiceStartTestValue = $Value }

                $result = Set-ServiceStart -Service 'WinDefend' -State 'Disabled'

                $result.Succeeded | Should -Be $true
                $result.Changed | Should -Be 1
                $result.Verified | Should -Be 1
                $result.Effects[0].Evidence.Method | Should -Be 'Direct'
            }
        }
    }

    Describe 'Service phase effect verification' {
        BeforeEach {
            $script:OriginalDefenderServices = $script:DefenderServices
            $script:DefenderServices = @('WinDefend')
            $script:IncludeMDEMode = $false
            Mock Test-RestoreManifestRecording { $false }
            Mock Save-AclBackup {
                $backup = New-DefenderActionResult -Name 'RegistryAclBackup'
                Add-DefenderEffect -Result $backup -Target 'acl-backup.clixml' -Required $false `
                    -Attempted $false -Changed $false -Verified $true -Evidence 'NoAclChanges'
                Complete-DefenderActionResult -Result $backup
            }
            Mock Write-Log {}
            Mock Set-ServiceStart {
                $child = New-DefenderActionResult -Name "ServiceStart:$Service"
                Add-DefenderEffect -Result $child -Target "Service:${Service}:Start" `
                    -Attempted $true -Changed $true -Verified $true -Evidence @{ Expected = $State; Actual = $State }
                Complete-DefenderActionResult -Result $child
            }
        }

        AfterEach {
            $script:DefenderServices = $script:OriginalDefenderServices
        }

        It 'verifies both runtime stop and disabled start state' {
            $script:ServiceRuntimeTestState = 'Running'
            Mock Get-Service {
                [PSCustomObject]@{
                    Status = $script:ServiceRuntimeTestState
                    CanStop = $true
                }
            }
            Mock Invoke-DefenderServiceStop {
                $script:ServiceRuntimeTestState = 'Stopped'
                return 0
            }

            $result = Disable-DefenderServices

            $result.Succeeded | Should -Be $true
            $result.Attempted | Should -Be 2
            $result.Changed | Should -Be 2
            $result.Verified | Should -Be 3
        }

        It 'fails when a stoppable service remains running' {
            Mock Get-Service {
                [PSCustomObject]@{
                    Status = 'Running'
                    CanStop = $true
                }
            }
            Mock Invoke-DefenderServiceStop { 5 }

            $result = Disable-DefenderServices

            $result.Succeeded | Should -Be $false
            ($result.Effects | Where-Object Target -eq 'Service:WinDefend:Runtime').Verified |
                Should -Be $false
            $result.Errors[0] | Should -Match 'exited 5'
        }

        It 'marks non-stoppable runtime state as reboot-deferred while still verifying Start' {
            Mock Get-Service {
                [PSCustomObject]@{
                    Status = 'Running'
                    CanStop = $false
                }
            }
            Mock Invoke-DefenderServiceStop { throw 'should not stop' }

            $result = Disable-DefenderServices

            $result.Succeeded | Should -Be $true
            $runtimeEffect = $result.Effects | Where-Object Target -eq 'Service:WinDefend:Runtime'
            $runtimeEffect.Required | Should -Be $false
            $runtimeEffect.Verified | Should -Be $false
            Should -Invoke Invoke-DefenderServiceStop -Times 0 -Exactly
        }
    }

    Describe 'Registry ACL effect verification' {
        BeforeEach {
            $script:AppDir = $TestDrive
            Remove-Item -LiteralPath (Join-Path $TestDrive 'acl-backup.clixml') `
                -Force -ErrorAction SilentlyContinue
            Mock Assert-DefenderRuntimeDirectory {}
            Mock Initialize-Priv {}
            Mock Write-Log {}
        }

        It 'records an absent backup as not applicable' {
            $result = Restore-RegKeyACLs

            $result.Succeeded | Should -Be $true
            $result.Attempted | Should -Be 0
            $result.Effects[0].Required | Should -Be $false
        }

        It 'removes the backup only after every ACL is verified' {
            $path = Join-Path $TestDrive 'acl-backup.clixml'
            @{
                'SYSTEM\Example' = @{
                    OwnerSid = 'S-1-5-18'
                    Dacl = 'D:'
                }
            } | Export-Clixml -Path $path
            Mock Restore-DefenderRegistryAclEntry {
                [PSCustomObject]@{
                    Exists = $true
                    Verified = $true
                    OwnerSid = $Entry.OwnerSid
                    Dacl = $Entry.Dacl
                    Error = $null
                }
            }

            $result = Restore-RegKeyACLs

            $result.Succeeded | Should -Be $true
            $result.Verified | Should -Be 1
            Test-Path -LiteralPath $path | Should -Be $false
        }

        It 'retains the backup when any ACL fails verification' {
            $path = Join-Path $TestDrive 'acl-backup.clixml'
            @{
                'SYSTEM\Example' = @{
                    OwnerSid = 'S-1-5-18'
                    Dacl = 'D:'
                }
            } | Export-Clixml -Path $path
            Mock Restore-DefenderRegistryAclEntry {
                [PSCustomObject]@{
                    Exists = $true
                    Verified = $false
                    OwnerSid = 'S-1-5-32-544'
                    Dacl = 'D:(A;;KA;;;BA)'
                    Error = 'readback mismatch'
                }
            }

            $result = Restore-RegKeyACLs

            $result.Succeeded | Should -Be $false
            $result.Errors | Should -Contain 'readback mismatch'
            Test-Path -LiteralPath $path | Should -Be $true
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
            Mock Get-ComputerRestorePoint {
                [PSCustomObject]@{
                    SequenceNumber = 10
                    Description = 'Existing restore point'
                }
            }
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

            $result = New-SafetyRestorePoint

            $result.Succeeded | Should -Be $true
            $result.Effects[0].Evidence.ThrottleMinutes | Should -Be 720
            ($script:RestorePointLogs -join "`n") | Should -Match 'WARN\|System Restore point skipped by Windows throttle interval \(720 minutes\)'
        }

        It 'recognizes SystemRestorePointCreationFrequency errors' {
            Test-SystemRestoreThrottleError -Message 'SystemRestorePointCreationFrequency policy blocked this request.' | Should -Be $true
        }

        It 'verifies a newly created restore point by sequence and description' {
            $script:RestorePointQuery = 0
            Mock Get-ComputerRestorePoint {
                $script:RestorePointQuery++
                if ($script:RestorePointQuery -eq 1) {
                    return [PSCustomObject]@{
                        SequenceNumber = 10
                        Description = 'Existing restore point'
                    }
                }
                return [PSCustomObject]@{
                    SequenceNumber = 11
                    Description = "$script:AppName v$script:Version pre-op"
                }
            }
            Mock Checkpoint-Computer {}

            $result = New-SafetyRestorePoint

            $result.Succeeded | Should -Be $true
            $result.Changed | Should -Be 1
            $result.Verified | Should -Be 1
        }

        It 'returns a failed effect for an unthrottled checkpoint error' {
            Mock Checkpoint-Computer { throw 'Volume Shadow Copy service failed' }

            $result = New-SafetyRestorePoint

            $result.Succeeded | Should -Be $false
            $result.Errors[0] | Should -Match 'Volume Shadow Copy'
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

        It 'returns a failed effect when a SafeBoot WinDefend key remains after SYSTEM fallback' {
            $result = Remove-SafeBootWinDefend

            $result.Succeeded | Should -Be $false
            $result.Verified | Should -Be 1
            $result.Errors[0] | Should -Match 'SafeBoot WinDefend removal failed'

            Should -Invoke Invoke-AsSystem -Times 1 -Exactly
        }

        It 'returns verified effects when present keys are removed' {
            $script:SafeBootTestPathCall = 0
            Mock Test-Path {
                if ($LiteralPath -eq $script:SafeBootMin) {
                    $script:SafeBootTestPathCall++
                    return ($script:SafeBootTestPathCall -eq 1)
                }
                return $false
            }
            Mock Remove-Item {}

            $result = Remove-SafeBootWinDefend

            $result.Succeeded | Should -Be $true
            $result.Attempted | Should -Be 1
            $result.Changed | Should -Be 1
            $result.Verified | Should -Be 2
            Should -Invoke Invoke-AsSystem -Times 0 -Exactly
        }
    }

    Describe 'Context-menu effect verification' {
        BeforeEach {
            $script:ContextMenuState = @{}
            foreach ($path in @(
                'HKLM:\SOFTWARE\Classes\*\shellex\ContextMenuHandlers\EPP',
                'HKLM:\SOFTWARE\Classes\Directory\shellex\ContextMenuHandlers\EPP',
                'HKLM:\SOFTWARE\Classes\Drive\shellex\ContextMenuHandlers\EPP'
            )) {
                $script:ContextMenuState[$path] = $true
            }
            Mock Test-Path { [bool]$script:ContextMenuState[$LiteralPath] }
            Mock Register-RegistryTreeUndo {}
            Mock Write-Log {}
        }

        It 'verifies every context-menu key was removed' {
            $script:ContextMenuPathCalls = @{}
            Mock Test-Path {
                $key = [string]$LiteralPath
                if (-not $script:ContextMenuPathCalls.ContainsKey($key)) {
                    $script:ContextMenuPathCalls[$key] = 0
                }
                $callCount = [int]$script:ContextMenuPathCalls[$key] + 1
                $script:ContextMenuPathCalls[$key] = $callCount
                return ($callCount -eq 1)
            }
            Mock Remove-Item {}

            $result = Remove-DefenderContextMenu

            $result.Succeeded | Should -Be $true
            $result.Attempted | Should -Be 3
            $result.Changed | Should -Be 3
            $result.Verified | Should -Be 3
        }

        It 'fails when removal returns but a key remains' {
            Mock Remove-Item {}

            $result = Remove-DefenderContextMenu

            $result.Succeeded | Should -Be $false
            $result.Verified | Should -Be 0
            $result.Errors.Count | Should -Be 3
        }
    }

    Describe 'DISM package effect verification' {
        BeforeEach {
            Mock Write-RestoreManifestEntry {}
            Mock Write-Log {}
        }

        It 'verifies enumerated packages are absent after removal' {
            $script:DismStateCall = 0
            Mock Get-DefenderPlatformPackageState {
                $script:DismStateCall++
                if ($script:DismStateCall -eq 1) {
                    return [PSCustomObject]@{
                        Readable = $true
                        ExitCode = 0
                        Packages = @('Microsoft-Windows-Defender-Package')
                        Error = $null
                    }
                }
                return [PSCustomObject]@{
                    Readable = $true
                    ExitCode = 0
                    Packages = @()
                    Error = $null
                }
            }
            Mock Invoke-DefenderDismPackageRemoval {
                [PSCustomObject]@{ ExitCode = 0; Output = @() }
            }

            $result = Remove-DefenderPlatformPackages

            $result.Succeeded | Should -Be $true
            $result.Attempted | Should -Be 1
            $result.Changed | Should -Be 1
            $result.Effects[0].Evidence.RemovalExitCode | Should -Be 0
        }

        It 'fails when DISM reports failure and the package remains' {
            Mock Get-DefenderPlatformPackageState {
                [PSCustomObject]@{
                    Readable = $true
                    ExitCode = 0
                    Packages = @('Microsoft-Windows-Defender-Package')
                    Error = $null
                }
            }
            Mock Invoke-DefenderDismPackageRemoval {
                [PSCustomObject]@{ ExitCode = 5; Output = @('Access denied') }
            }

            $result = Remove-DefenderPlatformPackages

            $result.Succeeded | Should -Be $false
            $result.Verified | Should -Be 0
            $result.Errors[0] | Should -Match 'exited 5'
        }

        It 'fails before mutation when package enumeration fails' {
            Mock Get-DefenderPlatformPackageState {
                [PSCustomObject]@{
                    Readable = $false
                    ExitCode = 87
                    Packages = @()
                    Error = 'DISM package enumeration exited 87.'
                }
            }
            Mock Invoke-DefenderDismPackageRemoval { throw 'should not remove' }

            $result = Remove-DefenderPlatformPackages

            $result.Succeeded | Should -Be $false
            $result.Effects[0].Target | Should -Be 'DISM:Get-Packages'
            Should -Invoke Invoke-DefenderDismPackageRemoval -Times 0 -Exactly
        }
    }

    Describe 'SecHealthUI effect verification' {
        BeforeEach {
            Mock Test-RestoreManifestRecording { $false }
            Mock Write-Log {}
        }

        It 'verifies installed packages and deprovision markers after removal' {
            $markerPaths = @(Get-SecHealthUIDeprovisionPaths)
            $script:SecHealthStateCall = 0
            Mock Get-DefenderSecHealthUIState {
                $script:SecHealthStateCall++
                if ($script:SecHealthStateCall -eq 1) {
                    return [PSCustomObject]@{
                        Supported = $true
                        Readable = $true
                        InstalledPackages = @([PSCustomObject]@{ PackageFullName = 'SecHealthUI_1'; Name = 'Microsoft.SecHealthUI' })
                        ProvisionedPackages = @()
                        Markers = @()
                        Error = $null
                    }
                }
                return [PSCustomObject]@{
                    Supported = $true
                    Readable = $true
                    InstalledPackages = @()
                    ProvisionedPackages = @()
                    Markers = $markerPaths
                    Error = $null
                }
            }
            Mock Remove-AppxPackage {}
            Mock New-Item {}

            $result = Remove-SecHealthUI

            $result.Succeeded | Should -Be $true
            $result.Verified | Should -Be 3
            ($result.Effects | Where-Object Target -eq 'SecHealthUI:Installed').Changed | Should -Be $true
        }

        It 'fails when an installed package remains after removal' {
            $markerPaths = @(Get-SecHealthUIDeprovisionPaths)
            Mock Get-DefenderSecHealthUIState {
                [PSCustomObject]@{
                    Supported = $true
                    Readable = $true
                    InstalledPackages = @([PSCustomObject]@{ PackageFullName = 'SecHealthUI_1'; Name = 'Microsoft.SecHealthUI' })
                    ProvisionedPackages = @()
                    Markers = $markerPaths
                    Error = $null
                }
            }
            Mock Remove-AppxPackage {}

            $result = Remove-SecHealthUI

            $result.Succeeded | Should -Be $false
            ($result.Effects | Where-Object Target -eq 'SecHealthUI:Installed').Verified | Should -Be $false
        }

        It 'records Appx-unavailable systems as not applicable' {
            Mock Get-DefenderSecHealthUIState {
                [PSCustomObject]@{
                    Supported = $false
                    Readable = $true
                    InstalledPackages = @()
                    ProvisionedPackages = @()
                    Markers = @()
                    Error = $null
                }
            }

            $result = Remove-SecHealthUI

            $result.Succeeded | Should -Be $true
            $result.Effects[0].Required | Should -Be $false
            $result.Effects[0].Evidence.Actual | Should -Be 'AppxUnsupported'
        }
    }

    function script:New-TestRestoreActionResult {
        param(
            [string]$Target = 'TestRestoreTarget',
            [bool]$Verified = $true,
            [string]$ErrorMessage
        )

        return (New-DefenderSingleEffectResult -Name 'TestRestoreAction' -Target $Target `
            -Attempted $true -Changed $Verified -Verified $Verified -Evidence 'Test' `
            -Errors $(if ($Verified) { @() } else { @($ErrorMessage) }))
    }

    Describe 'Restore replay manifest' {
        BeforeEach {
            $script:RestoreManifestPath = Join-Path $TestDrive 'restore-manifest.jsonl'
            $script:AppDir = $TestDrive
            Get-ChildItem -Path $TestDrive -Filter 'restore-manifest*.jsonl' -ErrorAction SilentlyContinue | Remove-Item -Force
            Remove-Item -LiteralPath (Join-Path $TestDrive 'restore-replay-state.json') `
                -Force -ErrorAction SilentlyContinue
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

        It 'replays entries in reverse order and archives only after exact verification' {
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
            Mock Invoke-RestoreManifestEntry {
                $script:ReplayOrder += "$($Entry.Data.Service)=$($Entry.Data.State)"
                New-TestRestoreActionResult -Target $Entry.Target
            }

            Invoke-RestoreManifest | Should -Be $true
            $script:ReplayOrder | Should -Be @('SecondService=Automatic','FirstService=Manual')
            Test-Path -LiteralPath $script:RestoreManifestPath | Should -Be $true
            (Read-RestoreReplayState).Status | Should -Be 'AwaitingVerification'

            Mock Test-RestoreManifestEntryBaseline {
                New-TestRestoreActionResult -Target $Entry.Target
            }
            $verification = Test-RestoreManifestBaseline

            $verification.Succeeded | Should -Be $true
            Test-Path -LiteralPath $script:RestoreManifestPath | Should -Be $false
            Test-Path -LiteralPath (Get-RestoreReplayStatePath) | Should -Be $false
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
            Mock Invoke-RestoreManifestEntry {
                New-TestRestoreActionResult -Target $Entry.Target
            }
            Mock Test-RestoreManifestEntryBaseline {
                New-TestRestoreActionResult -Target $Entry.Target
            }
            Mock Write-Log {
                param($Message, $Level)
                $script:ManifestReplayLogs += "$Level|$Message"
            }

            Invoke-RestoreManifest | Should -Be $true
            Test-RestoreManifestBaseline | Out-Null

            $joined = $script:ManifestReplayLogs -join "`n"
            $joined | Should -Match 'INFO\|Restore manifest integrity: RunIds=[0-9a-f-]+ Entries=1 SHA256=[0-9a-f]{64}'
            $joined | Should -Match 'INFO\|Archived verified restore manifest .+RunIds=[0-9a-f-]+; Entries=1; SHA256=[0-9a-f]{64}'
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
            Mock Invoke-RestoreManifestEntry {
                $script:ReplayOrder += "$($Entry.Data.Service)=$($Entry.Data.State)"
                New-TestRestoreActionResult -Target $Entry.Target
            }
            Mock Test-RestoreManifestEntryBaseline {
                New-TestRestoreActionResult -Target $Entry.Target
            }
            Mock Write-Log {
                param($Message, $Level)
                $script:ManifestReplayLogs += "$Level|$Message"
            }

            Invoke-RestoreManifest | Should -Be $true

            $script:ReplayOrder | Should -Be @('WinDefend=Disabled')
            Test-Path -LiteralPath $script:RestoreManifestPath | Should -Be $true
            Test-RestoreManifestBaseline | Out-Null
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
            Mock Invoke-RestoreManifestEntry {
                $script:ReplayOrder += "$($Entry.Data.Service)=$($Entry.Data.State)"
                New-TestRestoreActionResult -Target $Entry.Target
            }
            Mock Test-RestoreManifestEntryBaseline {
                New-TestRestoreActionResult -Target $Entry.Target
            }
            Mock Write-Log {}

            $finalExpectations = @(Get-RestoreManifestFinalExpectations `
                -Plan (Get-RestoreManifestReplayPlan -Selection All))
            $finalExpectations.Count | Should -Be 1
            $finalExpectations[0].Data.State | Should -Be 'Automatic'

            Invoke-RestoreManifest -Selection All | Should -Be $true

            $script:ReplayOrder | Should -Be @('WinDefend=Disabled','WinDefend=Automatic')
            Test-RestoreManifestBaseline -Selection All | Out-Null
            Test-Path -LiteralPath $script:RestoreManifestPath | Should -Be $false
            @(Get-ChildItem -Path $TestDrive -Filter 'restore-manifest.*.jsonl' | Where-Object { $_.Name -match '^restore-manifest\.\d{14}(?:\.\d+)?\.jsonl$' }).Count | Should -Be 0
            @(Get-ChildItem -Path $TestDrive -Filter 'restore-manifest.restored.*.jsonl').Count | Should -Be 2
        }

        It 'preserves the manifest and resumes from the first failed entry' {
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

            $script:ReplayAttempts = @()
            $script:FailFirstService = $true
            Mock Invoke-RestoreManifestEntry {
                $script:ReplayAttempts += $Entry.Data.Service
                if ($Entry.Data.Service -eq 'FirstService' -and $script:FailFirstService) {
                    return (New-TestRestoreActionResult -Target $Entry.Target -Verified $false `
                        -ErrorMessage 'injected replay failure')
                }
                return (New-TestRestoreActionResult -Target $Entry.Target)
            }

            Invoke-RestoreManifest | Should -Be $false

            Test-Path -LiteralPath $script:RestoreManifestPath | Should -Be $true
            $failedState = Read-RestoreReplayState
            $failedState.Status | Should -Be 'Failed'
            $failedState.CompletedKeys.Count | Should -Be 1
            $failedState.NextEntryKey | Should -Match ':1$'

            $script:FailFirstService = $false
            Invoke-RestoreManifest | Should -Be $true

            $script:ReplayAttempts | Should -Be @('SecondService','FirstService','FirstService')
            (Read-RestoreReplayState).Status | Should -Be 'AwaitingVerification'
            Test-Path -LiteralPath $script:RestoreManifestPath | Should -Be $true
        }

        It 'preserves replay artifacts when exact verification fails' {
            Start-RestoreManifest -Mode Disable
            Write-RestoreManifestEntry -Phase 'Services' -Action 'SetServiceStart' -Target 'WinDefend' -Data ([ordered]@{
                Service = 'WinDefend'
                State   = 'Automatic'
            })
            Stop-RestoreManifest

            Mock Invoke-RestoreManifestEntry {
                New-TestRestoreActionResult -Target $Entry.Target
            }
            $script:FailBaselineVerification = $true
            Mock Test-RestoreManifestEntryBaseline {
                New-TestRestoreActionResult -Target $Entry.Target `
                    -Verified (-not $script:FailBaselineVerification) `
                    -ErrorMessage $(if ($script:FailBaselineVerification) { 'injected drift' } else { $null })
            }

            Invoke-RestoreManifest | Should -Be $true
            $failedVerification = Test-RestoreManifestBaseline

            $failedVerification.Succeeded | Should -Be $false
            Test-Path -LiteralPath $script:RestoreManifestPath | Should -Be $true
            (Read-RestoreReplayState).Status | Should -Be 'VerificationFailed'
            @(Get-ChildItem -Path $TestDrive -Filter 'restore-manifest.restored.*.jsonl').Count |
                Should -Be 0

            $script:FailBaselineVerification = $false
            Invoke-RestoreManifest | Should -Be $true
            (Test-RestoreManifestBaseline).Succeeded | Should -Be $true
            Test-Path -LiteralPath (Get-RestoreReplayStatePath) | Should -Be $false
        }

        It 'resumes finalization after one manifest archive move is interrupted' {
            Start-RestoreManifest -Mode Disable
            Write-RestoreManifestEntry -Phase 'Services' -Action 'SetServiceStart' -Target 'FirstService' -Data ([ordered]@{
                Service = 'FirstService'
                State   = 'Automatic'
            })
            Stop-RestoreManifest
            Start-Sleep -Milliseconds 1100
            Start-RestoreManifest -Mode Disable
            Write-RestoreManifestEntry -Phase 'Services' -Action 'SetServiceStart' -Target 'SecondService' -Data ([ordered]@{
                Service = 'SecondService'
                State   = 'Manual'
            })
            Stop-RestoreManifest

            Mock Invoke-RestoreManifestEntry {
                New-TestRestoreActionResult -Target $Entry.Target
            }
            Mock Test-RestoreManifestEntryBaseline {
                New-TestRestoreActionResult -Target $Entry.Target
            }
            $script:ArchiveMoveCount = 0
            $script:InjectArchiveFailure = $true
            Mock Move-RestoreManifestToArchive {
                $script:ArchiveMoveCount++
                if ($script:InjectArchiveFailure -and $script:ArchiveMoveCount -eq 2) {
                    throw 'injected archive interruption'
                }
                [System.IO.File]::Move($Source, $Destination)
            }

            Invoke-RestoreManifest -Selection All | Should -Be $true
            (Test-RestoreManifestBaseline -Selection All).Succeeded | Should -Be $false

            (Read-RestoreReplayState).Status | Should -Be 'FinalizeFailed'
            @(Get-ChildItem -Path $TestDrive -Filter 'restore-manifest.restored.*.jsonl').Count |
                Should -Be 1
            @(Get-RestoreManifestCandidates).Count | Should -Be 1

            $script:InjectArchiveFailure = $false
            Invoke-RestoreManifest -Selection All | Should -Be $true
            (Test-RestoreManifestBaseline -Selection All).Succeeded | Should -Be $true

            Test-Path -LiteralPath (Get-RestoreReplayStatePath) | Should -Be $false
            @(Get-RestoreManifestCandidates).Count | Should -Be 0
            @(Get-ChildItem -Path $TestDrive -Filter 'restore-manifest.restored.*.jsonl').Count |
                Should -Be 2
        }

        It 'refuses to encode an unreadable registry pre-state as absent' {
            Start-RestoreManifest -Mode Disable
            Mock Get-RestoreRegistryValueState {
                [PSCustomObject]@{
                    Readable = $false
                    Exists = $null
                    Kind = $null
                    Value = $null
                    Error = 'access denied'
                }
            }

            { Register-RegistryValueUndo -Path 'HKLM:\SOFTWARE\Example' -Name 'Value' -Phase 'Policies' } |
                Should -Throw -ExpectedMessage '*mutation refused*'

            Stop-RestoreManifest
            @(Read-RestoreManifestEntries).Count | Should -Be 0
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
            Mock Invoke-RestoreManifestEntry { throw 'should not replay' }

            { Invoke-RestoreManifest } | Should -Throw -ExpectedMessage '*unexpected action*'
            Should -Invoke Invoke-RestoreManifestEntry -Times 0 -Exactly
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
            Mock Invoke-RestoreManifestEntry { throw 'should not replay' }

            { Invoke-RestoreManifest } | Should -Throw -ExpectedMessage '*missing Data.State*'
            Should -Invoke Invoke-RestoreManifestEntry -Times 0 -Exactly
        }
    }

    Describe 'Restore entry exact postconditions' {
        It 'restores a non-default registry value with its original kind' {
            $script:RestoreRegistryKind = 'DWord'
            $script:RestoreRegistryValue = 0
            Mock Set-RegistryValueFromManifest {
                $script:RestoreRegistryKind = $Kind
                $script:RestoreRegistryValue = $Value
            }
            Mock Get-RestoreRegistryValueState {
                [PSCustomObject]@{
                    Readable = $true
                    Exists = $true
                    Kind = $script:RestoreRegistryKind
                    Value = $script:RestoreRegistryValue
                    Error = $null
                }
            }
            $entry = [PSCustomObject]@{
                Action = 'RestoreRegistryValue'
                Target = 'HKLM:\SOFTWARE\Example\NonDefault'
                Data = [PSCustomObject]@{
                    Path = 'HKLM:\SOFTWARE\Example'
                    Name = 'NonDefault'
                    Kind = 'QWord'
                    Value = [int64]4294967297
                }
            }

            $result = Invoke-RestoreManifestEntry -Entry $entry

            $result.Succeeded | Should -Be $true
            $result.Effects[0].Evidence.ActualKind | Should -Be 'QWord'
            $result.Effects[0].Evidence.ActualValue | Should -Be 4294967297
        }

        It 'replaces a registry tree before importing the recorded tree' {
            $expectedTree = [PSCustomObject]@{
                Name = 'EPP'
                Values = @([PSCustomObject]@{
                    Name = ''
                    Kind = 'String'
                    Value = '{non-default-handler}'
                })
                Children = @([PSCustomObject]@{
                    Name = 'Child'
                    Values = @([PSCustomObject]@{ Name = 'Enabled'; Kind = 'DWord'; Value = 0 })
                    Children = @()
                })
            }
            $script:RestoredTree = $null
            Mock Test-Path { $true }
            Mock Remove-Item {}
            Mock Import-RegistryTree { $script:RestoredTree = $Tree }
            Mock Export-RegistryTree { $script:RestoredTree }
            $entry = [PSCustomObject]@{
                Action = 'RestoreRegistryTree'
                Target = 'HKLM:\SOFTWARE\Classes\Example'
                Data = [PSCustomObject]@{
                    Path = 'HKLM:\SOFTWARE\Classes\Example'
                    Tree = $expectedTree
                }
            }

            $result = Invoke-RestoreManifestEntry -Entry $entry

            $result.Succeeded | Should -Be $true
            Should -Invoke Remove-Item -Times 1 -Exactly
            Should -Invoke Import-RegistryTree -Times 1 -Exactly
        }

        It 'routes recorded service and task states through verified mutators' {
            Mock Set-ServiceStart {
                New-TestRestoreActionResult -Target "Service:${Service}:Start"
            }
            Mock Invoke-DefenderScheduledTaskPlan {
                New-TestRestoreActionResult -Target $TaskPaths[0]
            }
            Mock Invoke-DefenderRestoreServiceRuntime {
                New-TestRestoreActionResult -Target "Service:${Service}:Runtime"
            }
            $entries = @(
                [PSCustomObject]@{
                    Action = 'SetServiceStart'
                    Target = 'WinDefend'
                    Data = [PSCustomObject]@{ Service = 'WinDefend'; State = 'Manual' }
                }
                [PSCustomObject]@{
                    Action = 'StartService'
                    Target = 'WinDefend'
                    Data = [PSCustomObject]@{ Service = 'WinDefend' }
                }
                [PSCustomObject]@{
                    Action = 'SetScheduledTaskState'
                    Target = '\Microsoft\Windows\Windows Defender\Custom'
                    Data = [PSCustomObject]@{
                        TaskPath = '\Microsoft\Windows\Windows Defender\Custom'
                        Enabled = $false
                    }
                }
            )

            $results = @($entries | ForEach-Object { Invoke-RestoreManifestEntry -Entry $_ })

            @($results | Where-Object { -not $_.Succeeded }).Count | Should -Be 0
            Should -Invoke Set-ServiceStart -ParameterFilter { $State -eq 'Manual' } -Times 1 -Exactly
            Should -Invoke Invoke-DefenderScheduledTaskPlan `
                -ParameterFilter { $Mode -eq 'Disable' } -Times 1 -Exactly
        }

        It 'restores non-default MpPreference and exclusion baselines' {
            $script:RestoreMapsValue = 'Disabled'
            $script:RestoreExclusions = @('C:\')
            Mock Set-MpPreference { $script:RestoreMapsValue = $MAPSReporting }
            Mock Remove-MpPreference { $script:RestoreExclusions = @() }
            Mock Get-MpPreference {
                [PSCustomObject]@{
                    MAPSReporting = $script:RestoreMapsValue
                    ExclusionPath = @($script:RestoreExclusions)
                }
            }
            $preferenceEntry = [PSCustomObject]@{
                Action = 'SetMpPreference'
                Target = 'MAPSReporting'
                Data = [PSCustomObject]@{ Name = 'MAPSReporting'; Value = 'Advanced' }
            }
            $exclusionEntry = [PSCustomObject]@{
                Action = 'RemoveMpPreferenceValue'
                Target = 'ExclusionPath:C:\'
                Data = [PSCustomObject]@{ Parameter = 'ExclusionPath'; Value = 'C:\' }
            }

            $preferenceResult = Invoke-RestoreManifestEntry -Entry $preferenceEntry
            $exclusionResult = Invoke-RestoreManifestEntry -Entry $exclusionEntry

            $preferenceResult.Succeeded | Should -Be $true
            $preferenceResult.Effects[0].Evidence.Actual | Should -Be 'Advanced'
            $exclusionResult.Succeeded | Should -Be $true
            $exclusionResult.Effects[0].Evidence.Actual | Should -Be 'Absent'
        }

        It 'verifies the exact recorded SecHealthUI package and marker sets' {
            $marker = (Get-SecHealthUIDeprovisionPaths)[1]
            $baseline = [PSCustomObject]@{
                InstalledPackages = @([PSCustomObject]@{
                    Name = 'Microsoft.Windows.SecHealthUI'
                    PackageFullName = 'Microsoft.Windows.SecHealthUI_9.9.9.9_x64__cw5n1h2txyewy'
                })
                ProvisionedPackages = @([PSCustomObject]@{
                    DisplayName = 'Microsoft.Windows.SecHealthUI'
                    PackageName = 'Microsoft.Windows.SecHealthUI_9.9.9.9_neutral__cw5n1h2txyewy'
                })
                DeprovisionMarkers = @($marker)
            }
            Mock Get-DefenderSecHealthUIState {
                [PSCustomObject]@{
                    Supported = $true
                    Readable = $true
                    InstalledPackages = @([PSCustomObject]@{
                        Name = 'Microsoft.Windows.SecHealthUI'
                        PackageFullName = 'Microsoft.Windows.SecHealthUI_9.9.9.9_x64__cw5n1h2txyewy'
                    })
                    ProvisionedPackages = @([PSCustomObject]@{
                        DisplayName = 'Microsoft.Windows.SecHealthUI'
                        PackageName = 'Microsoft.Windows.SecHealthUI_9.9.9.9_neutral__cw5n1h2txyewy'
                    })
                    Markers = @($marker)
                    Error = $null
                }
            }
            Mock Test-Path { return ($LiteralPath -eq $marker) }
            Mock New-Item {}
            Mock Remove-Item {}

            $result = Restore-SecHealthUI -Baseline $baseline

            $result.Succeeded | Should -Be $true
            $result.Attempted | Should -Be 0
            $result.Verified | Should -Be 3
            Should -Invoke New-Item -Times 0 -Exactly
            Should -Invoke Remove-Item -Times 0 -Exactly
        }

        It 'removes unexpected SecHealthUI packages to match an absent baseline' {
            $script:InstalledSecHealthPackages = @([PSCustomObject]@{
                Name = 'Microsoft.Windows.SecHealthUI'
                PackageFullName = 'Microsoft.Windows.SecHealthUI_10.0.0.0_x64__cw5n1h2txyewy'
            })
            $script:ProvisionedSecHealthPackages = @([PSCustomObject]@{
                DisplayName = 'Microsoft.Windows.SecHealthUI'
                PackageName = 'Microsoft.Windows.SecHealthUI_10.0.0.0_neutral__cw5n1h2txyewy'
            })
            Mock Get-DefenderSecHealthUIState {
                [PSCustomObject]@{
                    Supported = $true
                    Readable = $true
                    InstalledPackages = @($script:InstalledSecHealthPackages)
                    ProvisionedPackages = @($script:ProvisionedSecHealthPackages)
                    Markers = @()
                    Error = $null
                }
            }
            Mock Remove-AppxPackage {
                $script:InstalledSecHealthPackages = @()
            }
            Mock Remove-AppxProvisionedPackage {
                $script:ProvisionedSecHealthPackages = @()
            }
            Mock Test-Path { $false }
            $baseline = [PSCustomObject]@{
                InstalledPackages = @()
                ProvisionedPackages = @()
                DeprovisionMarkers = @()
            }

            $result = Restore-SecHealthUI -Baseline $baseline

            $result.Succeeded | Should -Be $true
            $result.Attempted | Should -Be 2
            Should -Invoke Remove-AppxPackage -Times 1 -Exactly
            Should -Invoke Remove-AppxProvisionedPackage -Times 1 -Exactly
        }

        It 'requires a removed DISM package to return before replay succeeds' {
            Mock Invoke-DefenderDismRestoreHealth {
                [PSCustomObject]@{ ExitCode = 0; Output = @() }
            }
            Mock Get-DefenderPlatformPackageState {
                [PSCustomObject]@{
                    Readable = $true
                    ExitCode = 0
                    Packages = @('Microsoft-Windows-Defender-Package')
                    Error = $null
                }
            }
            $entry = [PSCustomObject]@{
                Action = 'DismRestoreHealth'
                Target = 'Microsoft-Windows-Defender-Package'
                Data = [PSCustomObject]@{ PackageName = 'Microsoft-Windows-Defender-Package' }
            }

            $result = Invoke-RestoreManifestEntry -Entry $entry

            $result.Succeeded | Should -Be $true
            $result.Effects[0].Evidence.RestoreExitCode | Should -Be 0
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

            $result = Invoke-RestoreVerification

            $result.Succeeded | Should -Be $true
            $result.Verified | Should -Be 1
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

            $result = Invoke-RestoreVerification

            $result.Succeeded | Should -Be $false
            $result.Verified | Should -Be 0
            $result.RepairCommands | Should -Contain 'sfc /scannow'
            $joined = $script:RestoreVerificationLogs -join "`n"
            $joined | Should -Match 'WARN\|Restore verification: OK=1 Drift=2 Unknown=0 Total=3'
            $joined | Should -Match 'Repair command: sc\.exe config WinDefend start= auto'
            $joined | Should -Match 'Repair command: sfc /scannow'
            $joined | Should -Match 'Repair command: DISM /Online /Cleanup-Image /RestoreHealth'
        }

        It 'returns a failed contract in silent mode when Restore verification fails' {
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

                $result = Invoke-RestoreVerification

                $result.Succeeded | Should -Be $false
                $result.Errors[0] | Should -Match "Expected 'Automatic', actual 'Disabled'"
            } finally {
                $script:SilentMode = $false
            }
        }
    }

    Describe 'Effect result contract' {
        It 'summarizes verified changes and verified no-op effects' {
            $result = New-DefenderActionResult -Name 'Policy'
            Add-DefenderEffect -Result $result -Target 'ChangedValue' -Attempted $true -Changed $true `
                -Verified $true -Evidence @{ Expected = 1; Actual = 1 }
            Add-DefenderEffect -Result $result -Target 'AlreadyCorrect' -Attempted $false -Changed $false `
                -Verified $true -Evidence @{ Expected = 0; Actual = 0 }

            $completed = Complete-DefenderActionResult -Result $result

            $completed.Succeeded | Should -Be $true
            $completed.Attempted | Should -Be 1
            $completed.Changed | Should -Be 1
            $completed.Verified | Should -Be 2
            $completed.Errors | Should -BeNullOrEmpty
            { Assert-DefenderActionResult -Result $completed -Phase 'Policy' } | Should -Not -Throw
        }

        It 'fails when a required effect is unverified' {
            $result = New-DefenderActionResult -Name 'Policy'
            Add-DefenderEffect -Result $result -Target 'HKLM:\Example' -Attempted $true -Changed $false `
                -Verified $false -Evidence @{ Expected = 1; Actual = 0 } -Errors 'value did not converge'

            $completed = Complete-DefenderActionResult -Result $result

            $completed.Succeeded | Should -Be $false
            $completed.Errors | Should -Contain 'value did not converge'
            { Assert-DefenderActionResult -Result $completed -Phase 'Policy' } |
                Should -Throw -ExpectedMessage '*HKLM:\Example*'
        }
    }

    Describe 'Public operation-result orchestration' {
        BeforeEach {
            Mock Set-RunOptions {}
            Mock Confirm-LocalSession {}
            Mock Start-RestoreManifest {}
            Mock Stop-RestoreManifest {}
            Mock Save-DefenderSurfaceBaseline {}
            Mock Write-Log {}
        }

        It 'requires mutation results and saves the baseline after verified success' {
            Mock Invoke-DefenderGuardedPhasePlan {
                $script:CapturedOperationPhases = $Phases
                $script:CapturedPreflightPhases = $PreflightPhases
                $script:CapturedPostflightPhases = $PostflightPhases
                [PSCustomObject]@{
                    Succeeded = $true
                    Simulation = $false
                    Attempted = 4
                    Changed = 4
                    Verified = 4
                    Phases = @([PSCustomObject]@{ Result = [PSCustomObject]@{ Succeeded = $true } })
                }
            }

            $result = Invoke-DisableDefender -NoRestorePoint -Confirm:$false

            $result.Succeeded | Should -Be $true
            foreach ($key in @('Policies','MpPreference','Tasks','Services')) {
                ($script:CapturedOperationPhases | Where-Object Key -eq $key).RequiresResult |
                    Should -Be $true
            }
            ($script:CapturedPreflightPhases | Where-Object Key -eq 'RestorePoint').RequiresResult |
                Should -Be $true
            $script:CapturedPreflightPhases.Key | Should -Be @(
                'Prerequisites','FirewallPreflight','RestorePoint'
            )
            $script:CapturedPostflightPhases.Key | Should -Be @('FirewallPostflight')
            $script:CapturedOperationPhases.Key | Should -Not -Contain 'Prerequisites'
            $script:CapturedOperationPhases.Key | Should -Not -Contain 'FirewallPreflight'
            $script:CapturedOperationPhases.Key | Should -Not -Contain 'FirewallPostflight'
            Should -Invoke Save-DefenderSurfaceBaseline -Times 1 -Exactly
        }

        It 'does not save a baseline when the verified plan fails' {
            Mock Invoke-DefenderGuardedPhasePlan { throw 'effect verification failed' }

            { Invoke-DisableDefender -NoRestorePoint -Confirm:$false } |
                Should -Throw -ExpectedMessage '*effect verification failed*'

            Should -Invoke Save-DefenderSurfaceBaseline -Times 0 -Exactly
            Should -Invoke Stop-RestoreManifest -Times 1 -Exactly
        }

        It 'keeps every Remove safety gate outside the filtered action plan' {
            Mock Invoke-DefenderGuardedPhasePlan {
                $script:CapturedRemovePhases = $Phases
                $script:CapturedRemovePreflight = $PreflightPhases
                $script:CapturedRemovePostflight = $PostflightPhases
                [PSCustomObject]@{
                    Succeeded = $true
                    Simulation = $false
                    Attempted = 1
                    Changed = 1
                    Verified = 1
                    Phases = @([PSCustomObject]@{ Result = [PSCustomObject]@{ Succeeded = $true } })
                }
            }

            Invoke-RemoveDefender -Force -NoRestorePoint -Only Services -Confirm:$false | Out-Null

            $script:CapturedRemovePreflight.Key | Should -Be @(
                'Prerequisites','FirewallPreflight','SafeModeGate','KnownBadGate','RestorePoint'
            )
            $script:CapturedRemovePostflight.Key | Should -Be @('FirewallPostflight')
            $script:CapturedRemovePhases.Key | Should -Contain 'Services'
            foreach ($gate in @(
                'Prerequisites','FirewallPreflight','SafeModeGate',
                'KnownBadGate','RestorePoint','FirewallPostflight'
            )) {
                $script:CapturedRemovePhases.Key | Should -Not -Contain $gate
            }
        }

        It 'allows only action keys in public phase filters' {
            $disableOnly = (Get-Command Invoke-DisableDefender).Parameters['Only'].Attributes |
                Where-Object { $_ -is [Management.Automation.ValidateSetAttribute] }
            $removeOnly = (Get-Command Invoke-RemoveDefender).Parameters['Only'].Attributes |
                Where-Object { $_ -is [Management.Automation.ValidateSetAttribute] }
            $restoreOnly = (Get-Command Invoke-RestoreDefender).Parameters['Only'].Attributes |
                Where-Object { $_ -is [Management.Automation.ValidateSetAttribute] }

            foreach ($values in @(
                @($disableOnly.ValidValues),
                @($removeOnly.ValidValues),
                @($restoreOnly.ValidValues)
            )) {
                $values | Should -Not -Contain 'Prerequisites'
                $values | Should -Not -Contain 'FirewallPreflight'
                $values | Should -Not -Contain 'FirewallPostflight'
                $values | Should -Not -Contain 'RestorePoint'
            }
            @($removeOnly.ValidValues) | Should -Not -Contain 'SafeModeGate'
            @($removeOnly.ValidValues) | Should -Not -Contain 'KnownBadGate'
            @($restoreOnly.ValidValues) | Should -Not -Contain 'ReplayManifest'
        }

        It 'rejects empty action selections before session or manifest side effects' {
            Mock Invoke-DefenderGuardedPhasePlan { throw 'guarded plan should not run' }

            { Invoke-DisableDefender -Skip Policies,MpPreference,Tasks,Services -Confirm:$false } |
                Should -Throw -ExpectedMessage '*no runnable action phases*'
            { Invoke-RemoveDefender -Skip Policies,MpPreference,Tasks,Services,SafeBoot,Appx,DISM,ContextMenu -Confirm:$false } |
                Should -Throw -ExpectedMessage '*no runnable action phases*'

            Should -Invoke Set-RunOptions -Times 0 -Exactly
            Should -Invoke Confirm-LocalSession -Times 0 -Exactly
            Should -Invoke Start-RestoreManifest -Times 0 -Exactly
            Should -Invoke Invoke-DefenderGuardedPhasePlan -Times 0 -Exactly
        }

        It 'returns a simulation result under WhatIf without saving a baseline' {
            Mock Invoke-DefenderGuardedPhasePlan {
                [PSCustomObject]@{
                    Succeeded = $true
                    Simulation = $true
                    Attempted = 0
                    Changed = 0
                    Verified = 0
                    Phases = @([PSCustomObject]@{ Result = [PSCustomObject]@{ Succeeded = $true } })
                }
            }

            $result = Invoke-DisableDefender -NoRestorePoint -Confirm:$false -WhatIf

            $result.Simulation | Should -Be $true
            Should -Invoke Invoke-DefenderGuardedPhasePlan -Times 1 -Exactly
            Should -Invoke Save-DefenderSurfaceBaseline -Times 0 -Exactly
        }

        It 'uses only recorded-baseline phases when a manifest exists' {
            Mock Get-RestoreManifestReplayPlan {
                [PSCustomObject]@{
                    Manifests = @([PSCustomObject]@{ Path = 'restore-manifest.jsonl' })
                }
            }
            Mock Invoke-DefenderGuardedPhasePlan {
                $script:CapturedRestorePhases = $Phases
                $script:CapturedRestorePreflight = $PreflightPhases
                $script:CapturedRestorePostflight = $PostflightPhases
                [PSCustomObject]@{
                    Succeeded = $true
                    Simulation = $false
                    Attempted = 3
                    Changed = 3
                    Verified = 3
                    Phases = @()
                }
            }

            $result = Invoke-RestoreDefender -Confirm:$false

            $result.RestoreStrategy | Should -Be 'RecordedBaseline'
            $script:CapturedRestorePhases.Key | Should -Contain 'ReplayManifest'
            $script:CapturedRestorePhases.Key | Should -Contain 'AclRestore'
            $script:CapturedRestorePhases.Key | Should -Contain 'Verification'
            $script:CapturedRestorePhases.Key | Should -Not -Contain 'Policies'
            $script:CapturedRestorePhases.Key | Should -Not -Contain 'MpPreference'
            $script:CapturedRestorePhases.Key | Should -Not -Contain 'Tasks'
            $script:CapturedRestorePhases.Key | Should -Not -Contain 'Services'
            $script:CapturedRestorePhases.Key | Should -Not -Contain 'Appx'
            $script:CapturedRestorePhases.Key | Should -Not -Contain 'ContextMenu'
            $script:CapturedRestorePreflight.Key | Should -Be @('FirewallPreflight')
            $script:CapturedRestorePostflight.Key | Should -Be @('FirewallPostflight')
        }

        It 'requires an explicit repair switch when no manifest exists' {
            Mock Get-RestoreManifestReplayPlan {
                [PSCustomObject]@{ Manifests = @() }
            }
            Mock Invoke-DefenderGuardedPhasePlan { throw 'should not run' }

            { Invoke-RestoreDefender -Confirm:$false } |
                Should -Throw -ExpectedMessage '*-RepairWithoutManifest*'

            Should -Invoke Invoke-DefenderGuardedPhasePlan -Times 0 -Exactly
        }

        It 'separates the explicit fixed-default repair plan from exact restore' {
            Mock Get-RestoreManifestReplayPlan {
                [PSCustomObject]@{ Manifests = @() }
            }
            Mock Invoke-DefenderGuardedPhasePlan {
                $script:CapturedRestorePhases = $Phases
                [PSCustomObject]@{
                    Succeeded = $true
                    Simulation = $false
                    Attempted = 3
                    Changed = 3
                    Verified = 3
                    Phases = @()
                }
            }

            $result = Invoke-RestoreDefender -RepairWithoutManifest -Confirm:$false

            $result.RestoreStrategy | Should -Be 'FixedDefaultRepair'
            $script:CapturedRestorePhases.Key | Should -Contain 'Policies'
            $script:CapturedRestorePhases.Key | Should -Contain 'MpPreference'
            $script:CapturedRestorePhases.Key | Should -Not -Contain 'ReplayManifest'
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

        It 'returns and persists a verified operation result' {
            $phases = @(
                New-DefenderPhase -Name 'Verified policy' -RequiresResult -Action {
                    $result = New-DefenderActionResult -Name 'Policy'
                    Add-DefenderEffect -Result $result -Target 'PolicyValue' -Attempted $true -Changed $true `
                        -Verified $true -Evidence @{ Expected = 1; Actual = 1 }
                    Complete-DefenderActionResult -Result $result
                }
            )

            $operation = Invoke-DefenderPhasePlan -Mode Disable -Phases $phases

            $operation.Succeeded | Should -Be $true
            $operation.Attempted | Should -Be 1
            $operation.Changed | Should -Be 1
            $operation.Verified | Should -Be 1
            $state = Get-Content -Raw -LiteralPath $script:PhaseStatePath | ConvertFrom-Json
            $state.Result.Succeeded | Should -Be $true
            $state.Phases[0].Result.Effects[0].Target | Should -Be 'PolicyValue'
        }

        It 'rejects a required-result phase that returns no contract' {
            $phases = @(
                New-DefenderPhase -Name 'Silent mutation' -RequiresResult -Action { $null }
            )

            { Invoke-DefenderPhasePlan -Mode Disable -Phases $phases } |
                Should -Throw -ExpectedMessage '*did not return a valid effect result*'

            $state = Get-Content -Raw -LiteralPath $script:PhaseStatePath | ConvertFrom-Json
            $state.Status | Should -Be 'Failed'
            $state.FailedPhase | Should -Be 'Silent mutation'
        }

        It 'rejects and persists a partial action result' {
            $phases = @(
                New-DefenderPhase -Name 'Partial mutation' -RequiresResult -Action {
                    $result = New-DefenderActionResult -Name 'Partial'
                    Add-DefenderEffect -Result $result -Target 'First' -Attempted $true -Changed $true `
                        -Verified $true -Evidence 'verified'
                    Add-DefenderEffect -Result $result -Target 'Second' -Attempted $true -Changed $false `
                        -Verified $false -Evidence 'stale' -Errors 'verification failed'
                    Complete-DefenderActionResult -Result $result
                }
            )

            { Invoke-DefenderPhasePlan -Mode Remove -Phases $phases } |
                Should -Throw -ExpectedMessage '*Second*'

            $state = Get-Content -Raw -LiteralPath $script:PhaseStatePath | ConvertFrom-Json
            $state.Phases[0].Result.Succeeded | Should -Be $false
            $state.Phases[0].Result.Errors | Should -Contain 'verification failed'
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

        It 'runs all mandatory gates for every mode, filter shape, and force choice' {
            $cases = New-Object System.Collections.ArrayList
            foreach ($mode in @('Disable','Remove','Restore')) {
                foreach ($force in @($false,$true)) {
                    foreach ($filter in @('None','Only','Skip')) {
                        [void]$cases.Add([PSCustomObject]@{
                            Mode = $mode
                            Force = $force
                            Filter = $filter
                        })
                    }
                }
            }

            foreach ($case in $cases) {
                $script:ForceMode = $case.Force
                $script:MandatoryRun = @()
                $script:ActionRun = @()
                $preflight = @(
                    New-DefenderPhase -Name 'Prerequisites' -Key 'Prerequisites' -Action {
                        $script:MandatoryRun += "pre:$($script:ForceMode)"
                    }
                    New-DefenderPhase -Name 'Firewall preflight' -Key 'FirewallPreflight' -Action {
                        $script:MandatoryRun += 'firewall-pre'
                    }
                )
                $actions = @(
                    New-DefenderPhase -Name 'Policy keys' -Key 'Policies' -Action {
                        $script:ActionRun += 'Policies'
                    }
                    New-DefenderPhase -Name 'Services' -Key 'Services' -Action {
                        $script:ActionRun += 'Services'
                    }
                )
                $postflight = @(
                    New-DefenderPhase -Name 'Firewall postflight' -Key 'FirewallPostflight' -Action {
                        $script:MandatoryRun += 'firewall-post'
                    }
                )
                $splat = @{
                    Mode = $case.Mode
                    Phases = $actions
                    PreflightPhases = $preflight
                    PostflightPhases = $postflight
                }
                if ($case.Filter -eq 'Only') { $splat.Only = @('Services') }
                if ($case.Filter -eq 'Skip') { $splat.Skip = @('Policies') }

                Invoke-DefenderGuardedPhasePlan @splat | Out-Null

                $script:MandatoryRun | Should -Be @(
                    "pre:$($case.Force)",'firewall-pre','firewall-post'
                )
                $expectedActions = if ($case.Filter -eq 'None') {
                    @('Policies','Services')
                } else {
                    @('Services')
                }
                $script:ActionRun | Should -Be $expectedActions
            }
        }

        It 'runs mandatory postflight after an action failure without masking it' {
            $script:PostflightAfterFailure = $false
            $actions = @(
                New-DefenderPhase -Name 'Broken action' -Key 'Services' -Action {
                    throw 'injected action failure'
                }
            )
            $postflight = @(
                New-DefenderPhase -Name 'Firewall postflight' -Key 'FirewallPostflight' -Action {
                    $script:PostflightAfterFailure = $true
                }
            )

            { Invoke-DefenderGuardedPhasePlan -Mode Remove -Phases $actions `
                -PostflightPhases $postflight } |
                Should -Throw -ExpectedMessage '*injected action failure*'

            $script:PostflightAfterFailure | Should -Be $true
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

        It 'never injects Force into the live completion command' {
            $defaultResult = New-OfflineRemoveBundle -OutputDirectory $script:BundleDir
            $defaultContent = Get-Content -LiteralPath $defaultResult.ScriptPath -Raw

            $defaultResult.Force | Should -Be $false
            $defaultContent | Should -Match '-Mode Remove -Only MpPreference,Tasks,Appx,DISM'
            $defaultContent | Should -Not -Match '-Mode Remove -Force'

            $forcedResult = New-OfflineRemoveBundle -OutputDirectory $script:BundleDir -Force
            $forcedContent = Get-Content -LiteralPath $forcedResult.ScriptPath -Raw

            $forcedResult.Force | Should -Be $true
            $forcedContent | Should -Match '-Mode Remove -Force -Only MpPreference,Tasks,Appx,DISM'
        }
    }
}

InModuleScope DisableDefender {
    Describe 'Invoke-SafeModeRemove force propagation' {
        BeforeEach {
            $script:SafeModeEncodedScripts = @()
            Mock Get-CimInstance {
                [PSCustomObject]@{ BootupState = 'Normal boot' }
            }
            Mock Register-DefenderSafeModeTask {
                $script:SafeModeEncodedScripts += $EncodedScript
            }
            Mock Register-SafeBootWatchdog {}
            Mock Unregister-ScheduledTask {}
            Mock Unregister-SafeBootWatchdog {}
            Mock Write-Log {}
            Mock bcdedit.exe {
                $global:LASTEXITCODE = 0
                'The operation completed successfully.'
            }
            Mock shutdown.exe {}
        }

        It 'omits Force by default and includes it only when explicitly requested' {
            $defaultResult = Invoke-SafeModeRemove -DelaySeconds 0 -Confirm:$false
            $forcedResult = Invoke-SafeModeRemove -DelaySeconds 0 -Force -Confirm:$false

            $decodedScripts = @($script:SafeModeEncodedScripts | ForEach-Object {
                [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($_))
            })
            $decodedScripts.Count | Should -Be 2
            $decodedScripts[0] | Should -Match '-Mode Remove -Silent -NoReboot'
            $decodedScripts[0] | Should -Not -Match '-Mode Remove -Force'
            $decodedScripts[1] | Should -Match '-Mode Remove -Silent -NoReboot -Force'
            $defaultResult.Force | Should -Be $false
            $forcedResult.Force | Should -Be $true
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

            $phaseMapping = Get-DefenderErrorMapping -Message "Phase 'Restore verification' failed effect verification: Service:WinDefend"
            $phaseMapping.ExitCode | Should -Be 6
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
        $xamlMatch = [regex]::Match(
            $script:GuiSource,
            '(?s)\[xml\]\$xaml\s*=\s*@''\r?\n(?<xaml>.*?)\r?\n''@'
        )
        if (-not $xamlMatch.Success) { throw 'GUI XAML here-string was not found.' }
        $script:GuiXaml = [xml]$xamlMatch.Groups['xaml'].Value
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

    It 'gives custom chrome and action controls explicit accessible names' {
        $namedButtons = @(
            'btnMin', 'btnMax', 'btnClose',
            'btnDisable', 'btnRemove', 'btnRestore', 'btnRepair', 'btnRefresh',
            'btnCopyLog', 'btnExportLog', 'btnClearLog',
            'btnConfirmCancel', 'btnConfirmOk'
        )

        foreach ($buttonName in $namedButtons) {
            $node = @($script:GuiXaml.SelectNodes('//*[@*[local-name()="Name"]]')) |
                Where-Object { $_.Attributes['x:Name'].Value -eq $buttonName } |
                Select-Object -First 1
            $node | Should -Not -BeNullOrEmpty
            $node.Attributes['AutomationProperties.Name'].Value | Should -Not -BeNullOrEmpty
        }
    }

    It 'defines keyboard focus, default, cancel, refresh, and maximize semantics' {
        $script:GuiSource | Should -Match 'KeyboardNavigation\.TabNavigation="Cycle"'
        $script:GuiSource | Should -Match 'x:Name="btnConfirmCancel"[^>]*IsCancel="True"'
        $script:GuiSource | Should -Match 'x:Name="btnConfirmOk"[^>]*IsDefault="True"'
        $script:GuiSource | Should -Match '\$e\.Key -eq ''F5'''
        $script:GuiSource | Should -Match '\$ui\.btnMax\.Add_Click'
        $script:GuiSource | Should -Match '\$window\.Add_StateChanged'
    }

    It 'blocks unsafe window close while a phase is busy and does not abruptly stop the worker' {
        $script:GuiSource | Should -Match '(?s)\$window\.Add_Closing\(\{.*?\$script:UIState\.Busy.*?\$closingArgs\.Cancel\s*=\s*\$true'
        $script:GuiSource | Should -Not -Match '\$script:AsyncPS\.Stop\('
    }

    It 'uses the shared verified operation result for completion state' {
        $script:GuiSource | Should -Match '\$UIState\.LastResult\s*=\s*\$operationResult\[0\]'
        $script:GuiSource | Should -Match '\$result\.Succeeded'
        $script:GuiSource | Should -Match '\$result\.Verified'
        $script:GuiSource | Should -Not -Match "LastResult\s*=\s*'ok'"
    }

    It 'keeps exact baseline restore separate from fixed-default repair' {
        $script:GuiSource | Should -Match 'Invoke-RestoreDefender\s+-RepairWithoutManifest:\$RepairWithoutManifest'
        $script:GuiSource | Should -Match "Start-ModeAsync\s+-ActionMode 'Restore'\s+-RepairWithoutManifest"
        $script:GuiSource | Should -Match 'If no undo manifest exists, this action stops without changing the machine'
    }
}

Describe 'DisableDefender CLI result wiring' {
    BeforeAll {
        $script:CliSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\DisableDefender.ps1') -Raw
    }

    It 'serializes one shared success envelope for action-mode JSON output' {
        $script:CliSource | Should -Match '\$operationResult\s*\|\s*ConvertTo-Json\s+-Depth 12'
        $script:CliSource | Should -Match 'Silent\s*=\s*\[bool\]\(\$Silent -or \$Json\)'
        $script:CliSource | Should -Match '\$operationResult\.Succeeded'
        $script:CliSource | Should -Match '(?s)\(\$Mode -eq ''Disable'' -or \$Mode -eq ''Remove''\) -and -not \$Json.*?Show-DefenderStatus'
    }
}
