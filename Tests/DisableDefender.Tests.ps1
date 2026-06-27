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
}
