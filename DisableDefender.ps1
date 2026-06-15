#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
    DisableDefender v0.0.4
    The ultimate Microsoft Defender Antivirus disabler / remover for Windows 10/11.

    DOES NOT touch the Windows Firewall. Firewall services (mpssvc, BFE) and the
    per-profile firewall state are verified before and after every operation.

    Modes:
      -Mode Disable   Reversible. Policy keys, Set-MpPreference, scheduled tasks, passive mode, services.
      -Mode Remove    Aggressive. Adds SecHealthUI deprovision, SafeBoot\WinDefend purge, platform pkgs.
      -Mode Restore   Undo. Clears policy keys, restores services, reprovisions SecHealthUI.
      -Mode Status    Show current Defender + firewall state.

    Prerequisite:
      Tamper Protection must be off. No scripted bypass exists on 24H2+.
#>

[CmdletBinding()]
param(
    [ValidateSet('Disable','Remove','Restore','Status')]
    [string]$Mode,

    [switch]$Silent,
    [switch]$NoRestorePoint,
    [switch]$NoReboot,
    [switch]$Force,
    [switch]$IncludeMDE,
    [string]$LogPath = "$env:APPDATA\DisableDefender\DisableDefender.log"
)

$script:Version = '0.0.4'
$script:AppName = 'DisableDefender'
$script:AppDir  = Join-Path $env:APPDATA $script:AppName
if (-not (Test-Path $script:AppDir)) { New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null }

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

# MDE/EDR services — only disabled when -IncludeMDE is passed.
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
# Logging
# ---------------------------------------------------------------------------
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK','DEBUG')][string]$Level = 'INFO'
    )
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line  = "[$stamp] [$Level] $Message"
    try { Add-Content -LiteralPath $LogPath -Value $line -ErrorAction Stop } catch {}
    if ($Silent) { return }
    $color = switch ($Level) {
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'DEBUG' { 'DarkGray' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
}

function Write-Banner {
    if ($Silent) { return }
    $bar = '=' * 72
    Write-Host ''
    Write-Host $bar -ForegroundColor DarkCyan
    Write-Host " $script:AppName v$script:Version" -ForegroundColor Cyan
    Write-Host "  Microsoft Defender disabler / remover (firewall preserved)" -ForegroundColor Gray
    Write-Host $bar -ForegroundColor DarkCyan
    Write-Host ''
}

# ---------------------------------------------------------------------------
# SeTakeOwnership + registry ACL override (primary method for service keys).
# No TrustedInstaller needed; privacy.sexy avoids TI because it triggers
# Defender alarms. This path works on stock Windows 10/11 with Admin rights.
# ---------------------------------------------------------------------------
$script:PrivType = @'
using System;
using System.Runtime.InteropServices;

public static class Priv {
    [StructLayout(LayoutKind.Sequential)]
    public struct LUID { public uint LowPart; public int HighPart; }
    [StructLayout(LayoutKind.Sequential)]
    public struct LUID_AND_ATTRIBUTES { public LUID Luid; public uint Attributes; }
    [StructLayout(LayoutKind.Sequential)]
    public struct TOKEN_PRIVILEGES { public uint PrivilegeCount; public LUID_AND_ATTRIBUTES Privileges; }

    [DllImport("advapi32.dll", SetLastError=true)]
    public static extern bool OpenProcessToken(IntPtr h, uint acc, out IntPtr tok);
    [DllImport("advapi32.dll", SetLastError=true)]
    public static extern bool LookupPrivilegeValue(string host, string name, out LUID luid);
    [DllImport("advapi32.dll", SetLastError=true)]
    public static extern bool AdjustTokenPrivileges(IntPtr h, bool dis, ref TOKEN_PRIVILEGES np, int len, IntPtr prev, IntPtr rl);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetCurrentProcess();

    public const uint TOKEN_ADJUST_PRIVILEGES = 0x0020;
    public const uint TOKEN_QUERY             = 0x0008;
    public const uint SE_PRIVILEGE_ENABLED    = 0x2;

    public static bool Enable(string priv) {
        IntPtr tok;
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out tok)) return false;
        LUID luid;
        if (!LookupPrivilegeValue(null, priv, out luid)) { CloseHandle(tok); return false; }
        TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
        tp.PrivilegeCount = 1;
        tp.Privileges.Luid = luid;
        tp.Privileges.Attributes = SE_PRIVILEGE_ENABLED;
        bool ok = AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
        CloseHandle(tok);
        return ok;
    }
}
'@

function Initialize-Priv {
    if (-not ('Priv' -as [type])) { Add-Type -TypeDefinition $script:PrivType -ErrorAction Stop }
    [Priv]::Enable('SeTakeOwnershipPrivilege') | Out-Null
    [Priv]::Enable('SeRestorePrivilege')       | Out-Null
    [Priv]::Enable('SeBackupPrivilege')        | Out-Null
    [Priv]::Enable('SeSecurityPrivilege')      | Out-Null
}

function Grant-RegKeyControl {
    <#
      Takes ownership of an HKLM registry subkey and grants BUILTIN\Administrators
      FullControl. Saves original owner + DACL for later restoration by Restore-RegKeyACLs.
      Returns $true on success. Works without TrustedInstaller.
    #>
    param([Parameter(Mandatory)][string]$SubKey)   # e.g. 'SYSTEM\CurrentControlSet\Services\WinDefend'
    Initialize-Priv
    try {
        $admins = New-Object System.Security.Principal.NTAccount('BUILTIN\Administrators')

        # 1. Take ownership — capture original owner first
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            $SubKey,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [System.Security.AccessControl.RegistryRights]::TakeOwnership)
        if ($null -eq $key) { return $false }
        $ownerAcl = $key.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Owner)
        $originalOwnerSid = $ownerAcl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        $ownerAcl.SetOwner($admins)
        $key.SetAccessControl($ownerAcl)
        $key.Close()

        # 2. Read original DACL (now accessible since we own the key) before adding FullControl
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            $SubKey,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [System.Security.AccessControl.RegistryRights]::ChangePermissions -bor
            [System.Security.AccessControl.RegistryRights]::ReadPermissions)
        if ($null -eq $key) { return $false }
        $acl = $key.GetAccessControl()
        $originalDacl = $acl.GetSecurityDescriptorSddlForm(
            [System.Security.AccessControl.AccessControlSections]::Access)

        # Save original ACL for later restoration
        if ($null -eq $script:AclBackups) { $script:AclBackups = @{} }
        if (-not $script:AclBackups.ContainsKey($SubKey)) {
            $script:AclBackups[$SubKey] = @{ OwnerSid = $originalOwnerSid; Dacl = $originalDacl }
        }

        # 3. Grant FullControl
        $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
            $admins,
            [System.Security.AccessControl.RegistryRights]::FullControl,
            [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
        $key.SetAccessControl($acl)
        $key.Close()
        return $true
    } catch {
        Write-Log "Grant-RegKeyControl failed for $SubKey : $_" DEBUG
        return $false
    }
}

function Save-AclBackup {
    if ($null -eq $script:AclBackups -or $script:AclBackups.Count -eq 0) { return }
    $dir = Join-Path $env:ProgramData $script:AppName
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir 'acl-backup.clixml'
    $script:AclBackups | Export-Clixml -Path $path -Force
    Write-Log "ACL backup saved ($($script:AclBackups.Count) keys) to $path" DEBUG
}

function Restore-RegKeyACLs {
    $path = Join-Path (Join-Path $env:ProgramData $script:AppName) 'acl-backup.clixml'
    if (-not (Test-Path $path)) {
        Write-Log "No ACL backup found — skipping ACL restore." DEBUG
        return
    }
    Write-Log "Restoring original registry ACLs..." INFO
    Initialize-Priv
    $backups = Import-Clixml -Path $path
    foreach ($subKey in $backups.Keys) {
        try {
            $entry = $backups[$subKey]
            $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
                $subKey,
                [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
                [System.Security.AccessControl.RegistryRights]::ChangePermissions -bor
                [System.Security.AccessControl.RegistryRights]::TakeOwnership)
            if ($null -eq $key) {
                Write-Log "Cannot open $subKey for ACL restore — key may not exist." WARN
                continue
            }
            $acl = $key.GetAccessControl()
            $acl.SetSecurityDescriptorSddlForm(
                $entry.Dacl, [System.Security.AccessControl.AccessControlSections]::Access)
            $ownerSid = New-Object System.Security.Principal.SecurityIdentifier($entry.OwnerSid)
            $acl.SetOwner($ownerSid)
            $key.SetAccessControl($acl)
            $key.Close()
            Write-Log "Restored ACL for $subKey" DEBUG
        } catch {
            Write-Log "Failed to restore ACL for ${subKey}: $_" WARN
        }
    }
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    Write-Log "Registry ACLs restored." OK
}

# ---------------------------------------------------------------------------
# SYSTEM execution via transient scheduled task (fallback for keys that
# Administrator can't write but SYSTEM can).
# ---------------------------------------------------------------------------
function Invoke-AsSystem {
    param(
        [Parameter(Mandatory)][string]$Execute,
        [Parameter(Mandatory)][string]$Argument
    )
    $taskName = "_dp_{0:N}" -f [guid]::NewGuid()
    try {
        $action = New-ScheduledTaskAction -Execute $Execute -Argument $Argument
        $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
        for ($i=0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 300
            $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
            if ($info -and $info.LastTaskResult -ne 267009) { break }  # 267009 = still running
        }
        return $true
    } catch {
        Write-Log "Invoke-AsSystem failed: $_" DEBUG
        return $false
    } finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Firewall safety guard (critical vs touch-refuse distinction)
# ---------------------------------------------------------------------------
function Test-FirewallIntact {
    $bad = @()
    foreach ($s in $script:CriticalFirewallServices) {
        $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
        if ($null -eq $svc) { continue }
        if ($svc.StartType -eq 'Disabled') { $bad += "$s is Disabled" }
    }
    try {
        $profiles = Get-NetFirewallProfile -ErrorAction Stop
        foreach ($p in $profiles) {
            if (-not $p.Enabled) { $bad += "Firewall profile $($p.Name) is off" }
        }
    } catch { $bad += "Get-NetFirewallProfile failed: $_" }
    return ,$bad
}

function Assert-FirewallSafety {
    param([string]$Stage = 'pre')
    $issues = Test-FirewallIntact
    if ($issues.Count -gt 0) {
        Write-Log "Firewall issues at $Stage stage:" WARN
        foreach ($i in $issues) { Write-Log "  - $i" WARN }
        if ($Stage -eq 'post' -and -not $Force) {
            throw "Firewall integrity broken after operation. Aborting."
        }
    } else {
        Write-Log "Firewall intact at $Stage stage." OK
    }
}

# ---------------------------------------------------------------------------
# Tamper Protection check
# ---------------------------------------------------------------------------
function Test-TamperProtection {
    try {
        $s = Get-MpComputerStatus -ErrorAction Stop
        return [bool]$s.IsTamperProtected
    } catch { return $null }
}

function New-SafetyRestorePoint {
    if ($NoRestorePoint) { return }
    try {
        Enable-ComputerRestore -Drive $env:SystemDrive -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description "$script:AppName v$script:Version pre-op" -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Write-Log "System Restore point created." OK
    } catch {
        Write-Log "Could not create restore point: $_" WARN
    }
}

# ---------------------------------------------------------------------------
# Policy registry writer with refuse-list guard
# ---------------------------------------------------------------------------
function Set-RegValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [ValidateSet('DWord','QWord','String','ExpandString','MultiString','Binary')]
        [string]$Type = 'DWord'
    )
    foreach ($p in $script:RefuseTouchRegPaths) {
        if ($Path -like "$p*") {
            Write-Log "REFUSED firewall path: $Path" ERROR
            return
        }
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    Write-Log "Set $Path\$Name = $Value ($Type)" DEBUG
}

# ---------------------------------------------------------------------------
# Phase: policy keys (expanded w/ privacy.sexy findings)
# ---------------------------------------------------------------------------
function Set-DefenderPolicy {
    Write-Log "Applying Defender policy keys..." INFO

    # Root kill switches
    Set-RegValue $script:PolicyRoot 'DisableAntiSpyware'            1
    Set-RegValue $script:PolicyRoot 'DisableAntiVirus'              1
    Set-RegValue $script:PolicyRoot 'DisableRoutinelyTakingAction'  1
    Set-RegValue $script:PolicyRoot 'DisableSpecialRunningModes'    1
    Set-RegValue $script:PolicyRoot 'ServiceKeepAlive'              0   # privacy.sexy issue #426
    Set-RegValue $script:PolicyRoot 'AllowFastServiceStartup'       0
    Set-RegValue $script:PolicyRoot 'DisableLocalAdminMerge'        1
    Set-RegValue $script:PolicyRoot 'PUAProtection'                 0

    # Real-time
    Set-RegValue $script:RealTimeRoot 'DisableRealtimeMonitoring'        1
    Set-RegValue $script:RealTimeRoot 'DisableBehaviorMonitoring'        1
    Set-RegValue $script:RealTimeRoot 'DisableOnAccessProtection'        1
    Set-RegValue $script:RealTimeRoot 'DisableScanOnRealtimeEnable'      1
    Set-RegValue $script:RealTimeRoot 'DisableIOAVProtection'            1
    Set-RegValue $script:RealTimeRoot 'DisableRawWriteNotification'      1
    Set-RegValue $script:RealTimeRoot 'DisableIntrusionPreventionSystem' 1
    Set-RegValue $script:RealTimeRoot 'DisableInformationProtectionControl' 1   # privacy.sexy
    Set-RegValue $script:RealTimeRoot 'LocalSettingOverrideDisableRealtimeMonitoring' 1

    # Spynet / MAPS
    Set-RegValue $script:SpynetRoot 'SpyNetReporting'                    0
    Set-RegValue $script:SpynetRoot 'SubmitSamplesConsent'               2
    Set-RegValue $script:SpynetRoot 'DisableBlockAtFirstSeen'            1
    Set-RegValue $script:SpynetRoot 'LocalSettingOverrideSpynetReporting' 0   # privacy.sexy

    # MpEngine
    Set-RegValue $script:MpEngineRoot 'MpEnablePus'                 0   # privacy.sexy legacy PUA
    Set-RegValue $script:MpEngineRoot 'EnableFileHashComputation'   0   # privacy.sexy
    Set-RegValue $script:MpEngineRoot 'MpCloudBlockLevel'           0   # privacy.sexy
    Set-RegValue $script:MpEngineRoot 'MpBafsExtendedTimeout'       0   # privacy.sexy

    # NIS (Network Inspection) - privacy.sexy
    Set-RegValue $script:NISRoot    'DisableProtocolRecognition'     1
    Set-RegValue $script:NISIPSRoot 'DisableSignatureRetirement'     1
    Set-RegValue $script:NISIPSRoot 'ThrottleDetectionEventsRate'    10000000

    # Signature updates - stop auto updating
    Set-RegValue $script:SignatureRoot 'ForceUpdateFromMU' 0
    Set-RegValue $script:SignatureRoot 'DisableScheduledSignatureUpdateOnBattery' 1
    Set-RegValue $script:SignatureRoot 'RealtimeSignatureDelivery' 0                       # privacy.sexy
    Set-RegValue $script:SignatureRoot 'DisableUpdateOnStartupWithoutEngine' 1             # privacy.sexy

    # Scan
    Set-RegValue $script:ScanRoot 'DisableRemovableDriveScanning' 1
    Set-RegValue $script:ScanRoot 'DisableArchiveScanning' 1
    Set-RegValue $script:ScanRoot 'DisableScanningMappedNetworkDrivesForFullScan' 1
    Set-RegValue $script:ScanRoot 'DisableScanningNetworkFiles' 1

    # UX - suppress notifications
    Set-RegValue $script:UXRoot 'Notification_Suppress' 1                                   # privacy.sexy

    # Reporting
    Set-RegValue $script:ReportingRoot 'DisableEnhancedNotifications' 1

    # Passive mode for MDE
    Set-RegValue $script:ATPRoot 'ForceDefenderPassiveMode' 1

    # SmartScreen
    Set-RegValue $script:SmartScreen 'EnableSmartScreen' 0

    # MRT - stop malicious software removal tool
    Set-RegValue $script:MRTRoot 'DontOfferThroughWUAU' 1
    Set-RegValue $script:MRTRoot 'DontReportInfectionInformation' 1

    # Legacy Microsoft Antimalware (for older Windows)
    Set-RegValue $script:MsAntimalware 'ServiceKeepAlive' 0

    Write-Log "Policy keys written." OK
}

function Clear-DefenderPolicy {
    Write-Log "Removing Defender policy keys..." INFO
    $roots = @(
        $script:PolicyRoot, $script:RealTimeRoot, $script:SpynetRoot,
        $script:SignatureRoot, $script:ReportingRoot, $script:MpEngineRoot,
        $script:ScanRoot, $script:UXRoot, $script:NISRoot,
        $script:ATPRoot, $script:MRTRoot, $script:MsAntimalware
    )
    foreach ($r in $roots) {
        if (Test-Path -LiteralPath $r) {
            Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Removed $r" DEBUG
        }
    }
    if (Test-Path -LiteralPath $script:SmartScreen) {
        Remove-ItemProperty -LiteralPath $script:SmartScreen -Name 'EnableSmartScreen' -ErrorAction SilentlyContinue
    }
    Write-Log "Policy keys cleared." OK
}

# ---------------------------------------------------------------------------
# Phase: Set-MpPreference (runtime, expanded)
# ---------------------------------------------------------------------------
function Set-MpRuntimePrefs {
    Write-Log "Applying Set-MpPreference flags..." INFO
    $boolPrefs = @(
        'DisableRealtimeMonitoring','DisableBehaviorMonitoring','DisableBlockAtFirstSeen',
        'DisableIOAVProtection','DisableScriptScanning','DisableArchiveScanning',
        'DisableIntrusionPreventionSystem','DisableRemovableDriveScanning',
        'DisableScanningMappedNetworkDrivesForFullScan','DisableScanningNetworkFiles',
        'SignatureDisableUpdateOnStartupWithoutEngine'
    )
    foreach ($p in $boolPrefs) {
        $splat = @{ $p = $true; ErrorAction = 'SilentlyContinue' }
        try { Set-MpPreference @splat } catch {}
    }
    $enumPrefs = @{
        MAPSReporting                = 'Disabled'
        SubmitSamplesConsent         = 'NeverSend'
        PUAProtection                = 'Disabled'
        SignatureScheduleDay         = 'Never'
        ScanScheduleDay              = 'Never'
        EnableControlledFolderAccess = 'Disabled'
        EnableNetworkProtection      = 'Disabled'
        CloudBlockLevel              = 'Default'     # minimum
    }
    foreach ($k in $enumPrefs.Keys) {
        $splat = @{ $k = $enumPrefs[$k]; ErrorAction = 'SilentlyContinue' }
        try { Set-MpPreference @splat } catch {}
    }
    try {
        Add-MpPreference -ExclusionPath @('C:\','D:\','E:\') -ErrorAction SilentlyContinue
        Add-MpPreference -ExclusionExtension @('exe','dll','ps1','bat','cmd','vbs','js','msi') -ErrorAction SilentlyContinue
    } catch {}
    Write-Log "Runtime preferences applied." OK
}

function Clear-MpRuntimePrefs {
    Write-Log "Restoring MpPreference defaults..." INFO
    $prefs = @(
        'DisableRealtimeMonitoring','DisableBehaviorMonitoring','DisableBlockAtFirstSeen',
        'DisableIOAVProtection','DisableScriptScanning','DisableArchiveScanning',
        'DisableIntrusionPreventionSystem','DisableRemovableDriveScanning',
        'DisableScanningMappedNetworkDrivesForFullScan','DisableScanningNetworkFiles'
    )
    foreach ($p in $prefs) {
        $splat = @{ $p = $false; ErrorAction = 'SilentlyContinue' }
        try { Set-MpPreference @splat } catch {}
    }
    try {
        Set-MpPreference -MAPSReporting Advanced -ErrorAction SilentlyContinue
        Set-MpPreference -SubmitSamplesConsent SendSafeSamples -ErrorAction SilentlyContinue
        Set-MpPreference -PUAProtection Enabled -ErrorAction SilentlyContinue
        Remove-MpPreference -ExclusionPath @('C:\','D:\','E:\') -ErrorAction SilentlyContinue
        Remove-MpPreference -ExclusionExtension @('exe','dll','ps1','bat','cmd','vbs','js','msi') -ErrorAction SilentlyContinue
    } catch {}
    Write-Log "MpPreference defaults restored (may require service restart)." OK
}

# ---------------------------------------------------------------------------
# Phase: Scheduled tasks
# ---------------------------------------------------------------------------
function Disable-DefenderTasks {
    Write-Log "Disabling Defender scheduled tasks..." INFO
    foreach ($t in $script:DefenderTasks) {
        $tn = Split-Path $t -Leaf
        $tp = Split-Path $t -Parent
        try {
            Disable-ScheduledTask -TaskName $tn -TaskPath "$tp\" -ErrorAction Stop | Out-Null
            Write-Log "Disabled task: $t" DEBUG
        } catch {
            schtasks.exe /Change /TN $t /Disable 2>&1 | Out-Null
        }
    }
    Write-Log "Scheduled tasks disabled." OK
}

function Enable-DefenderTasks {
    Write-Log "Enabling Defender scheduled tasks..." INFO
    foreach ($t in $script:DefenderTasks) {
        $tn = Split-Path $t -Leaf
        $tp = Split-Path $t -Parent
        try {
            Enable-ScheduledTask -TaskName $tn -TaskPath "$tp\" -ErrorAction SilentlyContinue | Out-Null
        } catch {
            schtasks.exe /Change /TN $t /Enable 2>&1 | Out-Null
        }
    }
    Write-Log "Scheduled tasks enabled." OK
}

# ---------------------------------------------------------------------------
# Phase: Services (multi-strategy fallback)
# ---------------------------------------------------------------------------
function Set-ServiceStart {
    param(
        [Parameter(Mandatory)][string]$Service,
        [Parameter(Mandatory)][ValidateSet('Boot','System','Automatic','Manual','Disabled')][string]$State
    )
    if ($script:RefuseTouchServices -contains $Service) {
        Write-Log "REFUSED firewall/network service: $Service" ERROR
        return $false
    }
    $map = @{ Boot=0; System=1; Automatic=2; Manual=3; Disabled=4 }
    $value = $map[$State]
    $subKey  = "SYSTEM\CurrentControlSet\Services\$Service"
    $regPath = "HKLM:\$subKey"
    if (-not (Test-Path -LiteralPath $regPath)) {
        Write-Log "Service $Service not present, skipping." DEBUG
        return $true
    }
    # 1. Direct write
    try {
        Set-ItemProperty -LiteralPath $regPath -Name 'Start' -Value $value -Type DWord -ErrorAction Stop
        Write-Log "Service $Service Start=$State (direct)." DEBUG
        return $true
    } catch {}
    # 2. ACL takeover -> direct write
    if (Grant-RegKeyControl -SubKey $subKey) {
        try {
            Set-ItemProperty -LiteralPath $regPath -Name 'Start' -Value $value -Type DWord -ErrorAction Stop
            Write-Log "Service $Service Start=$State (ACL takeover)." DEBUG
            return $true
        } catch {}
    }
    # 3. SYSTEM via scheduled task
    if (Invoke-AsSystem -Execute 'reg.exe' -Argument "add `"HKLM\$subKey`" /v Start /t REG_DWORD /d $value /f") {
        Start-Sleep -Milliseconds 500
        $actual = (Get-ItemProperty -LiteralPath $regPath -Name 'Start' -ErrorAction SilentlyContinue).Start
        if ($actual -eq $value) {
            Write-Log "Service $Service Start=$State (SYSTEM task)." DEBUG
            return $true
        }
    }
    Write-Log "Service $Service could not be set to $State. Boot to Safe Mode for full effect." WARN
    return $false
}

function Get-TargetServices {
    $list = [System.Collections.ArrayList]::new($script:DefenderServices)
    if ($script:IncludeMDE -or $IncludeMDE) {
        foreach ($s in $script:MDEServices) { [void]$list.Add($s) }
        Write-Log "MDE services included in target list (Sense)." WARN
    }
    return $list.ToArray()
}

function Stop-DefenderServices {
    Write-Log "Stopping Defender services..." INFO
    $targets = Get-TargetServices
    foreach ($s in $targets) {
        if ($script:RefuseTouchServices -contains $s) { continue }
        sc.exe stop $s 2>&1 | Out-Null
    }
    Write-Log "Stop signals sent." OK
}

function Disable-DefenderServices {
    Stop-DefenderServices
    $targets = Get-TargetServices
    foreach ($s in $targets) {
        Set-ServiceStart -Service $s -State Disabled | Out-Null
    }
    Save-AclBackup
    Write-Log "Defender services disabled." OK
}

function Restore-DefenderServices {
    Write-Log "Restoring default Defender service start types..." INFO
    $defaults = @{
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
    foreach ($k in $defaults.Keys) {
        Set-ServiceStart -Service $k -State $defaults[$k] | Out-Null
    }
    Write-Log "Services restored." OK
}

# ---------------------------------------------------------------------------
# Phase: SafeBoot trap (Remove mode only)
# Removing SafeBoot\WinDefend prevents the service from loading even in Safe Mode.
# ---------------------------------------------------------------------------
function Remove-SafeBootWinDefend {
    Write-Log "Removing SafeBoot\WinDefend entries..." INFO
    foreach ($path in @($script:SafeBootMin, $script:SafeBootNet)) {
        if (Test-Path -LiteralPath $path) {
            try {
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
                Write-Log "Removed $path" DEBUG
            } catch {
                $sub = $path -replace '^HKLM:\\',''
                if (Grant-RegKeyControl -SubKey (Split-Path $sub -Parent)) {
                    Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
                    Write-Log "Removed $path (ACL takeover)" DEBUG
                } else {
                    Invoke-AsSystem -Execute 'reg.exe' -Argument "delete `"$($path -replace '^HKLM:\\','HKLM\')`" /f" | Out-Null
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Phase: Appx (SecHealthUI)
# ---------------------------------------------------------------------------
function Remove-SecHealthUI {
    Write-Log "Removing Windows Security (SecHealthUI) app..." INFO
    try {
        $pkgs = Get-AppxPackage -AllUsers -Name 'Microsoft.SecHealthUI' -ErrorAction SilentlyContinue
        foreach ($p in $pkgs) {
            Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction SilentlyContinue
            Write-Log "Removed AppxPackage $($p.PackageFullName)" DEBUG
        }
        $prov = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq 'Microsoft.SecHealthUI' }
        foreach ($pp in $prov) {
            try {
                & dism.exe /Online /Set-NonRemovableAppPolicy /PackageFamily:$($pp.PackageName) /NonRemovable:0 2>&1 | Out-Null
            } catch {}
            Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName -AllUsers -ErrorAction SilentlyContinue | Out-Null
            Write-Log "Deprovisioned $($pp.PackageName)" DEBUG
        }
        $allUser = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.SecHealthUI_8wekyb3d8bbwe'
        if (-not (Test-Path -LiteralPath $allUser)) { New-Item -Path $allUser -Force | Out-Null }
        Write-Log "Windows Security app removed." OK
    } catch {
        Write-Log "SecHealthUI removal issue: $_" WARN
    }
}

function Restore-SecHealthUI {
    Write-Log "Re-provisioning Windows Security (SecHealthUI)..." INFO
    try {
        $allUser = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.SecHealthUI_8wekyb3d8bbwe'
        if (Test-Path -LiteralPath $allUser) { Remove-Item -LiteralPath $allUser -Recurse -Force -ErrorAction SilentlyContinue }
        $manifest = Get-ChildItem "$env:ProgramFiles\WindowsApps" -Filter 'Microsoft.SecHealthUI_*' -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($manifest) {
            Add-AppxPackage -DisableDevelopmentMode -Register "$($manifest.FullName)\AppxManifest.xml" -ErrorAction SilentlyContinue
            Write-Log "Re-registered from $($manifest.FullName)" OK
        } else {
            Write-Log "SecHealthUI manifest not found. Run: DISM /Online /Cleanup-Image /RestoreHealth" WARN
        }
    } catch {
        Write-Log "SecHealthUI restore issue: $_" WARN
    }
}

# ---------------------------------------------------------------------------
# Phase: Platform package removal (Remove mode only)
# ---------------------------------------------------------------------------
function Remove-DefenderPlatformPackages {
    Write-Log "Enumerating Defender platform packages..." INFO
    $pkgs = @()
    try {
        $pkgs = (dism.exe /Online /Get-Packages /Format:Table 2>&1) -split "`n" |
                Where-Object { $_ -match 'Windows-Defender|SecurityClient' } |
                ForEach-Object { ($_ -split '\|')[0].Trim() }
    } catch {}
    foreach ($p in $pkgs) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        Write-Log "DISM remove: $p" DEBUG
        dism.exe /Online /Remove-Package /PackageName:$p /Quiet /NoRestart 2>&1 | Out-Null
    }
    Write-Log "Platform package removal attempted." OK
}

# ---------------------------------------------------------------------------
# Pre-flight + status
# ---------------------------------------------------------------------------
function Confirm-Prereqs {
    $tp = Test-TamperProtection
    if ($tp -eq $true) {
        Write-Log "Tamper Protection is ON. Disable it first in Windows Security UI." ERROR
        if (-not $Force) {
            throw "Tamper Protection blocks changes. Disable it manually, then retry. Use -Force to proceed anyway."
        }
    } elseif ($null -eq $tp) {
        Write-Log "Could not query Tamper Protection (Get-MpComputerStatus failed). Defender may already be partially removed." WARN
    } else {
        Write-Log "Tamper Protection is OFF." OK
    }
    $safe = (Get-CimInstance Win32_ComputerSystem).BootupState
    if ($safe -like '*Fail-safe*') {
        Write-Log "Running in Safe Mode - service registry edits should succeed." OK
        $script:InSafeMode = $true
    } else {
        $script:InSafeMode = $false
    }
}

function Get-DefenderStatus {
    $o = [ordered]@{}
    try {
        $s = Get-MpComputerStatus -ErrorAction Stop
        $o.AntivirusEnabled          = $s.AntivirusEnabled
        $o.RealTimeProtectionEnabled = $s.RealTimeProtectionEnabled
        $o.IsTamperProtected         = $s.IsTamperProtected
        $o.AMServiceEnabled          = $s.AMServiceEnabled
        $o.OnAccessProtection        = $s.OnAccessProtectionEnabled
        $o.BehaviorMonitor           = $s.BehaviorMonitorEnabled
        $o.IoavProtection            = $s.IoavProtectionEnabled
        $o.AntispywareEnabled        = $s.AntispywareEnabled
    } catch {
        $o.AMQuery = "Get-MpComputerStatus failed: $($_.Exception.Message)"
    }
    foreach ($s in ($script:DefenderServices + $script:MDEServices)) {
        $sv = Get-Service -Name $s -ErrorAction SilentlyContinue
        if ($sv) { $o["svc_$s"] = "$($sv.Status) / $($sv.StartType)" } else { $o["svc_$s"] = 'not present' }
    }
    foreach ($f in $script:CriticalFirewallServices) {
        $sv = Get-Service -Name $f -ErrorAction SilentlyContinue
        if ($sv) { $o["fw_$f"] = "$($sv.Status) / $($sv.StartType)" }
    }
    try {
        $fwp = Get-NetFirewallProfile -ErrorAction Stop
        foreach ($p in $fwp) { $o["firewall_$($p.Name)"] = $p.Enabled }
    } catch {}
    return $o
}

function Show-Status {
    Write-Banner
    $s = Get-DefenderStatus
    foreach ($k in $s.Keys) {
        $v = $s[$k]
        $c = 'Gray'
        if ($v -is [bool]) { $c = if ($v) { 'Green' } else { 'DarkGray' } }
        elseif ($v -is [string] -and $v -match 'Running') { $c = 'Yellow' }
        elseif ($v -is [string] -and $v -match 'Stopped|Disabled|not present') { $c = 'DarkGray' }
        Write-Host (" {0,-32} {1}" -f $k, $v) -ForegroundColor $c
    }
    Write-Host ''
}

function Show-Menu {
    Write-Banner
    Write-Host '  [1] Disable  (reversible; policy + tasks + passive mode + services)' -ForegroundColor White
    Write-Host '  [2] Remove   (aggressive; Safe Mode recommended; SecHealthUI + SafeBoot trap)' -ForegroundColor Red
    Write-Host '  [3] Restore  (undo: clear policy, re-enable services, reprovision UI)' -ForegroundColor Green
    Write-Host '  [4] Status   (show current Defender + firewall state)' -ForegroundColor Cyan
    Write-Host '  [Q] Quit' -ForegroundColor Gray
    Write-Host ''
    $choice = Read-Host 'Select'
    switch ($choice.ToUpper()) {
        '1' { return 'Disable' }
        '2' { return 'Remove' }
        '3' { return 'Restore' }
        '4' { return 'Status' }
        'Q' { return $null }
        default { return $null }
    }
}

# ---------------------------------------------------------------------------
# Mode runners
# ---------------------------------------------------------------------------
function Invoke-DisableMode {
    Confirm-Prereqs
    Assert-FirewallSafety -Stage pre
    New-SafetyRestorePoint
    Set-DefenderPolicy
    Set-MpRuntimePrefs
    Disable-DefenderTasks
    Disable-DefenderServices
    Assert-FirewallSafety -Stage post
    Write-Log "Disable complete. Reboot recommended." OK
}

function Invoke-RemoveMode {
    Confirm-Prereqs
    Assert-FirewallSafety -Stage pre
    if (-not $script:InSafeMode -and -not $Force) {
        Write-Log "Remove mode works best in Safe Mode. Reboot into Safe Mode and rerun, or pass -Force." WARN
        if (-not $Silent) {
            $ans = Read-Host 'Continue anyway? (y/N)'
            if ($ans.ToUpper() -ne 'Y') { return }
        } else { return }
    }
    New-SafetyRestorePoint
    Set-DefenderPolicy
    Set-MpRuntimePrefs
    Disable-DefenderTasks
    Disable-DefenderServices
    Remove-SafeBootWinDefend
    Remove-SecHealthUI
    Remove-DefenderPlatformPackages
    Assert-FirewallSafety -Stage post
    Write-Log "Remove complete. Reboot required." OK
}

function Invoke-RestoreMode {
    Assert-FirewallSafety -Stage pre
    Clear-DefenderPolicy
    Clear-MpRuntimePrefs
    Enable-DefenderTasks
    Restore-DefenderServices
    Restore-RegKeyACLs
    Restore-SecHealthUI
    Assert-FirewallSafety -Stage post
    Write-Log "Restore complete. Reboot recommended. If Defender does not come back: sfc /scannow then DISM /Online /Cleanup-Image /RestoreHealth." OK
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
# Library mode gate - when dot-sourced by the GUI, skip auto-execution.
if ($script:LibraryMode) { return }

try {
    Start-Transcript -Path (Join-Path $script:AppDir 'transcript.log') -Append -Force | Out-Null
} catch {}

Write-Log "=== $script:AppName v$script:Version starting (Mode=$Mode) ==="

if (-not $Mode) {
    if ($Silent) { throw "Silent mode requires -Mode" }
    $Mode = Show-Menu
    if (-not $Mode) { Write-Host 'Aborted.'; exit 0 }
}

try {
    switch ($Mode) {
        'Disable' { Invoke-DisableMode }
        'Remove'  { Invoke-RemoveMode }
        'Restore' { Invoke-RestoreMode }
        'Status'  { Show-Status; exit 0 }
    }
    Show-Status
    if (-not $NoReboot -and ($Mode -eq 'Disable' -or $Mode -eq 'Remove')) {
        if ($Silent) {
            Write-Log "Rebooting in 15 seconds..." WARN
            shutdown.exe /r /t 15 /c "$script:AppName reboot" | Out-Null
        } else {
            $r = Read-Host 'Reboot now? (Y/n)'
            if ($r.ToUpper() -ne 'N') { shutdown.exe /r /t 5 | Out-Null }
        }
    }
} catch {
    Write-Log "FATAL: $_" ERROR
    if (-not $Silent) {
        Add-Type -AssemblyName PresentationFramework
        [System.Windows.MessageBox]::Show($_.Exception.Message, "$script:AppName error", 'OK', 'Error') | Out-Null
    }
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}

try { Stop-Transcript | Out-Null } catch {}
