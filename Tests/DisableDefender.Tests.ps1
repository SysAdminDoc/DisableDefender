#Requires -Module Pester

BeforeAll {
    $script:LibraryMode = $true
    $content = Get-Content "$PSScriptRoot\..\DisableDefender.ps1" -Raw
    $content = $content -replace '#Requires -RunAsAdministrator', ''
    $sb = [ScriptBlock]::Create($content)
    . $sb
}

Describe 'Set-RegValue' {
    Context 'Refuse-list guard' {
        It 'Refuses to write to firewall policy paths' {
            Mock New-ItemProperty {}
            Mock New-Item {}
            Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall\DomainProfile' -Name 'Test' -Value 1
            Should -Invoke New-ItemProperty -Times 0 -Exactly
        }

        It 'Refuses to write to firewall service paths' {
            Mock New-ItemProperty {}
            Mock New-Item {}
            Set-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\mpssvc\Parameters' -Name 'Test' -Value 1
            Should -Invoke New-ItemProperty -Times 0 -Exactly
        }

        It 'Allows writing to Defender policy paths' {
            Mock New-ItemProperty {}
            Mock Test-Path { $true }
            Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -Name 'DisableAntiSpyware' -Value 1
            Should -Invoke New-ItemProperty -Times 1 -Exactly
        }
    }
}

Describe 'Set-ServiceStart' {
    Context 'Refuse-list guard' {
        It 'Refuses to modify firewall services' {
            $result = Set-ServiceStart -Service 'mpssvc' -State 'Disabled'
            $result | Should -Be $false
        }

        It 'Refuses to modify BFE' {
            $result = Set-ServiceStart -Service 'BFE' -State 'Disabled'
            $result | Should -Be $false
        }

        It 'Refuses to modify SharedAccess' {
            $result = Set-ServiceStart -Service 'SharedAccess' -State 'Disabled'
            $result | Should -Be $false
        }
    }

    Context 'Absent service' {
        It 'Returns true for services not present on the system' {
            Mock Test-Path { $false }
            $result = Set-ServiceStart -Service 'FakeDefenderService' -State 'Disabled'
            $result | Should -Be $true
        }
    }
}

Describe 'Test-FirewallIntact' {
    Context 'All services running and profiles enabled' {
        It 'Returns empty array when firewall is healthy' {
            Mock Get-Service {
                [PSCustomObject]@{ Name = $Name; Status = 'Running'; StartType = 'Automatic' }
            }
            Mock Get-NetFirewallProfile {
                @(
                    [PSCustomObject]@{ Name = 'Domain';  Enabled = $true },
                    [PSCustomObject]@{ Name = 'Private'; Enabled = $true },
                    [PSCustomObject]@{ Name = 'Public';  Enabled = $true }
                )
            }
            $result = Test-FirewallIntact
            $result.Count | Should -Be 0
        }
    }

    Context 'Critical service disabled' {
        It 'Reports when mpssvc is disabled' {
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
        It 'Reports when a profile is disabled' {
            Mock Get-Service {
                [PSCustomObject]@{ Name = $Name; Status = 'Running'; StartType = 'Automatic' }
            }
            Mock Get-NetFirewallProfile {
                @(
                    [PSCustomObject]@{ Name = 'Domain';  Enabled = $true },
                    [PSCustomObject]@{ Name = 'Private'; Enabled = $false },
                    [PSCustomObject]@{ Name = 'Public';  Enabled = $true }
                )
            }
            $result = Test-FirewallIntact
            $result.Count | Should -BeGreaterThan 0
            $result[0] | Should -Match 'Private'
        }
    }
}

Describe 'Get-TargetServices' {
    Context 'Default (no -IncludeMDE)' {
        It 'Does not include Sense in the default list' {
            $result = Get-TargetServices
            $result | Should -Not -Contain 'Sense'
        }

        It 'Includes WinDefend' {
            $result = Get-TargetServices
            $result | Should -Contain 'WinDefend'
        }
    }

    Context 'With -IncludeMDE' {
        It 'Includes Sense when IncludeMDE is set' {
            $script:IncludeMDE = $true
            try {
                $result = Get-TargetServices
                $result | Should -Contain 'Sense'
            } finally {
                $script:IncludeMDE = $false
            }
        }
    }
}

Describe 'Get-DefenderStatus' {
    It 'Returns an ordered dictionary' {
        Mock Get-MpComputerStatus { throw 'Not available' }
        Mock Get-Service { $null }
        Mock Get-NetFirewallProfile { throw 'Not available' }
        $result = Get-DefenderStatus
        $result | Should -BeOfType [System.Collections.Specialized.OrderedDictionary]
    }

    It 'Includes firewall keys' {
        Mock Get-MpComputerStatus { throw 'Not available' }
        Mock Get-Service { $null }
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
    It 'Does not contain any firewall services' {
        foreach ($s in $script:DefenderServices) {
            $script:RefuseTouchServices | Should -Not -Contain $s
        }
    }

    It 'Does not contain Sense in the base list' {
        $script:DefenderServices | Should -Not -Contain 'Sense'
    }

    It 'Contains Sense in the MDE list' {
        $script:MDEServices | Should -Contain 'Sense'
    }
}
