# ---------------------------------------------------------------------------
# Module-scoped variables: service lists, policy paths, refuse-lists
# ---------------------------------------------------------------------------

$script:Version = '0.0.14'
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
