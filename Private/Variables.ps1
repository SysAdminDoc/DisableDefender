# ---------------------------------------------------------------------------
# Module-scoped variables: service lists, policy paths, refuse-lists
# ---------------------------------------------------------------------------

$script:Version = '0.0.37'
$script:AppName = 'DisableDefender'
$script:AppDir  = Join-Path $env:ProgramData $script:AppName

# ---------------------------------------------------------------------------
# Firewall preservation
#   CriticalFirewallServices  = must stay non-Disabled; abort if disabled after op
#   RefuseTouchFirewall       = we will never write to these (services or reg paths)
#   NOTE: SharedAccess (ICS) is OFF by default on stock Windows and is not firewall core.
#         Only mpssvc + BFE are actually required for firewall to function.
# ---------------------------------------------------------------------------
$script:CriticalFirewallServices = @('mpssvc','BFE')

$script:RefuseTouchServices = @(
    'mpssvc','BFE','SharedAccess','MpsDrv','mpsdrv','MsSecWfp',
    'IKEEXT','PolicyAgent','Dnscache','Dhcp','Wlansvc','NetSetupSvc'
)

$script:RefuseTouchRegPaths = @(
    'HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall',
    'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy',
    'HKLM:\SYSTEM\CurrentControlSet\Services\mpssvc',
    'HKLM:\SYSTEM\CurrentControlSet\Services\BFE',
    'HKLM:\SYSTEM\CurrentControlSet\Services\MpsDrv',
    'HKLM:\SYSTEM\CurrentControlSet\Services\mpsdrv',
    'HKLM:\SYSTEM\CurrentControlSet\Services\MsSecWfp'
)

# ---------------------------------------------------------------------------
# Defender service surface (NO firewall entries).
# Expanded with privacy.sexy findings: MsSecFlt, MsSecCore, SgrmAgent/Broker,
# webthreatdefsvc, webthreatdefusersvc, MDDlpSvc
# ---------------------------------------------------------------------------
$script:DefenderServices = @(
    'WinDefend',                # Main AV engine
    'WdFilter',                 # Minifilter driver
    'WdBoot',                   # Early launch AM driver
    'WdNisDrv',                 # Network inspection driver
    'WdNisSvc',                 # Network inspection service
    'MDCoreSvc',                # MpDefenderCoreService (newer Windows)
    'MDDlpSvc',                 # Defender DLP
    'MsSecFlt',                 # Microsoft Security Filter
    'MsSecCore',                # Microsoft Security Core
    'SgrmAgent',                # System Guard Runtime Monitor Agent
    'SgrmBroker',               # System Guard Runtime Monitor Broker
    'SecurityHealthService',    # Windows Security UI backend
    'wscsvc',                   # Security Center (non-firewall notifications)
    'webthreat',                # SmartScreen web threat
    'webthreatdefsvc',          # Web Threat Defense Service
    'webthreatdefusersvc'       # Web Threat Defense per-user
)

# MDE/EDR services -- only disabled when -IncludeMDE is passed.
# Disabling Sense blinds the enterprise SOC; require explicit opt-in.
$script:MDEServices = @(
    'Sense'                     # Defender for Endpoint EDR sensor
)

$script:DefenderTasks = @(
    '\Microsoft\Windows\Windows Defender\Windows Defender Cache Maintenance',
    '\Microsoft\Windows\Windows Defender\Windows Defender Cleanup',
    '\Microsoft\Windows\Windows Defender\Windows Defender Scheduled Scan',
    '\Microsoft\Windows\Windows Defender\Windows Defender Verification',
    '\Microsoft\Windows\ExploitGuard\ExploitGuard MDM policy Refresh'
)

$script:PolicyRoot    = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
$script:RealTimeRoot  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection'
$script:SpynetRoot    = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet'
$script:SignatureRoot = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Signature Updates'
$script:ReportingRoot = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Reporting'
$script:MpEngineRoot  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\MpEngine'
$script:ScanRoot      = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Scan'
$script:UXRoot        = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\UX Configuration'
$script:NISRoot       = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\NIS'
$script:NISIPSRoot    = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\NIS\Consumers\IPS'
$script:ATPRoot       = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection'
$script:MRTRoot       = 'HKLM:\SOFTWARE\Policies\Microsoft\MRT'
$script:SmartScreen   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
$script:MsAntimalware = 'HKLM:\SOFTWARE\Policies\Microsoft\Microsoft Antimalware'      # legacy
$script:SafeBootMin   = 'HKLM:\SYSTEM\CurrentControlSet\Control\SafeBoot\Minimal\WinDefend'
$script:SafeBootNet   = 'HKLM:\SYSTEM\CurrentControlSet\Control\SafeBoot\Network\WinDefend'

# ---------------------------------------------------------------------------
# Canonical policy catalog -- single source of truth for writes and health.
# ---------------------------------------------------------------------------
function Get-DefenderPolicyCatalog {
    $loggerRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger'
    $bfpRoot = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Features\BehavioralNetworkBlocks\BruteForceProtection'
    $repRoot = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Features\BehavioralNetworkBlocks\RemoteEncryptionProtection'

    return @(
        @{ Path = $script:PolicyRoot;    Name = 'DisableAntiSpyware';            Value = 1 }
        @{ Path = $script:PolicyRoot;    Name = 'DisableAntiVirus';              Value = 1 }
        @{ Path = $script:PolicyRoot;    Name = 'DisableRoutinelyTakingAction';  Value = 1 }
        @{ Path = $script:PolicyRoot;    Name = 'DisableSpecialRunningModes';    Value = 1 }
        @{ Path = $script:PolicyRoot;    Name = 'ServiceKeepAlive';              Value = 0 }
        @{ Path = $script:PolicyRoot;    Name = 'AllowFastServiceStartup';       Value = 0 }
        @{ Path = $script:PolicyRoot;    Name = 'DisableLocalAdminMerge';        Value = 1 }
        @{ Path = $script:PolicyRoot;    Name = 'PUAProtection';                 Value = 0 }
        @{ Path = $script:RealTimeRoot;  Name = 'DisableRealtimeMonitoring';                    Value = 1 }
        @{ Path = $script:RealTimeRoot;  Name = 'DisableBehaviorMonitoring';                    Value = 1 }
        @{ Path = $script:RealTimeRoot;  Name = 'DisableOnAccessProtection';                    Value = 1 }
        @{ Path = $script:RealTimeRoot;  Name = 'DisableScanOnRealtimeEnable';                  Value = 1 }
        @{ Path = $script:RealTimeRoot;  Name = 'DisableIOAVProtection';                        Value = 1 }
        @{ Path = $script:RealTimeRoot;  Name = 'DisableRawWriteNotification';                  Value = 1 }
        @{ Path = $script:RealTimeRoot;  Name = 'DisableIntrusionPreventionSystem';             Value = 1 }
        @{ Path = $script:RealTimeRoot;  Name = 'DisableInformationProtectionControl';          Value = 1 }
        @{ Path = $script:RealTimeRoot;  Name = 'LocalSettingOverrideDisableRealtimeMonitoring'; Value = 1 }
        @{ Path = $script:SpynetRoot;    Name = 'SpyNetReporting';                              Value = 0 }
        @{ Path = $script:SpynetRoot;    Name = 'SubmitSamplesConsent';                         Value = 2 }
        @{ Path = $script:SpynetRoot;    Name = 'DisableBlockAtFirstSeen';                      Value = 1 }
        @{ Path = $script:SpynetRoot;    Name = 'LocalSettingOverrideSpynetReporting';          Value = 0 }
        @{ Path = $script:MpEngineRoot;  Name = 'MpEnablePus';                Value = 0 }
        @{ Path = $script:MpEngineRoot;  Name = 'EnableFileHashComputation';   Value = 0 }
        @{ Path = $script:MpEngineRoot;  Name = 'MpCloudBlockLevel';           Value = 0 }
        @{ Path = $script:MpEngineRoot;  Name = 'MpBafsExtendedTimeout';       Value = 0 }
        @{ Path = $script:NISRoot;       Name = 'DisableProtocolRecognition';   Value = 1 }
        @{ Path = $script:NISIPSRoot;    Name = 'DisableSignatureRetirement';   Value = 1 }
        @{ Path = $script:NISIPSRoot;    Name = 'ThrottleDetectionEventsRate';  Value = 10000000 }
        @{ Path = $script:SignatureRoot; Name = 'ForceUpdateFromMU';                            Value = 0 }
        @{ Path = $script:SignatureRoot; Name = 'DisableScheduledSignatureUpdateOnBattery';     Value = 1 }
        @{ Path = $script:SignatureRoot; Name = 'RealtimeSignatureDelivery';                    Value = 0 }
        @{ Path = $script:SignatureRoot; Name = 'DisableUpdateOnStartupWithoutEngine';          Value = 1 }
        @{ Path = $script:ScanRoot;      Name = 'DisableRemovableDriveScanning';                Value = 1 }
        @{ Path = $script:ScanRoot;      Name = 'DisableArchiveScanning';                       Value = 1 }
        @{ Path = $script:ScanRoot;      Name = 'DisableScanningMappedNetworkDrivesForFullScan'; Value = 1 }
        @{ Path = $script:ScanRoot;      Name = 'DisableScanningNetworkFiles';                  Value = 1 }
        @{ Path = $script:UXRoot;        Name = 'Notification_Suppress';                        Value = 1 }
        @{ Path = $script:ReportingRoot; Name = 'DisableEnhancedNotifications'; Value = 1 }
        @{ Path = $script:ATPRoot;       Name = 'ForceDefenderPassiveMode';     Value = 1 }
        @{ Path = $script:SmartScreen;   Name = 'EnableSmartScreen';            Value = 0 }
        @{ Path = $script:MRTRoot;       Name = 'DontOfferThroughWUAU';         Value = 1 }
        @{ Path = $script:MRTRoot;       Name = 'DontReportInfectionInformation'; Value = 1 }
        @{ Path = $script:MsAntimalware; Name = 'ServiceKeepAlive';             Value = 0 }
        @{ Path = (Join-Path $loggerRoot 'DefenderApiLogger');    Name = 'Start'; Value = 0 }
        @{ Path = (Join-Path $loggerRoot 'DefenderAuditLogger');  Name = 'Start'; Value = 0 }
        @{ Path = $bfpRoot; Name = 'BruteForceProtectionConfiguredState';         Value = 4 }
        @{ Path = $repRoot; Name = 'RemoteEncryptionProtectionConfiguredState';   Value = 4 }
    )
}
