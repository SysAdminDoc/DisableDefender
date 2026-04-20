# Changelog

## v0.0.4 - 2026-04-20

### Added
- **Premium WPF GUI** — `DisableDefender.GUI.ps1` with Catppuccin Mocha palette, custom chrome, glassmorphic panels.
  - Custom title bar (draggable, minimize, close) with app icon + version
  - Six live status tiles: Antivirus, Real-time, Tamper Protection, Firewall, Services count, MAPS telemetry
  - Overall status indicator with three states (PROTECTED / DISABLED / BLOCKED)
  - Tamper Protection warning banner with direct "Open Windows Security" button
  - Action rail: Disable / Full Remove / Restore / Refresh
  - Embedded live log with level-colored entries, Copy / Export / Clear
  - System info panel: OS build, Safe Mode, elevation, Tamper Protection
  - Confirmation modal overlay for destructive ops
  - Toast notifications (success / warn / error) with fade animation
  - Dispatcher-timer status refresh every 5s when idle
  - Async worker runspace so UI never blocks during Disable/Remove/Restore
- `DisableDefender.GUI.bat` convenience launcher for double-click
- Core script (`DisableDefender.ps1`) now honours `$script:LibraryMode` to suppress auto-execution when dot-sourced

### Changed
- Self-elevation via `Start-Process -Verb RunAs` in GUI
- Console window hidden via P/Invoke when GUI launches

## v0.0.3 - 2026-04-20

### Changed
- Project renamed from `DefenderPurge` to `DisableDefender`. Script file, `$AppName`, `%APPDATA%` log directory, and all docs updated.

## v0.0.2 - 2026-04-20

Hotfix + privacy.sexy integration.

### Fixed
- Firewall safety check was too strict — aborted when `SharedAccess` (ICS) was disabled, which is the default on stock Windows. Critical list now only contains `mpssvc` + `BFE` + the per-profile firewall state. Touch-refuse list is separate and broader.
- TrustedInstaller token elevation returned error -2 (`OpenProcessToken` failing) due to wrong process access mask. **Removed TI path entirely** — privacy.sexy documented that running as TI triggers Defender alarms ([issue #264](https://github.com/undergroundwires/privacy.sexy/issues/264)).
- `Apply-*` function names renamed to `Set-*` for PowerShell approved-verb compliance.

### Added
- **Registry ACL takeover** via `SeTakeOwnershipPrivilege` + `Microsoft.Win32.Registry` API — primary method for service key edits. No TrustedInstaller needed.
- **SYSTEM-via-transient-scheduled-task** fallback for keys that Admin can't write but SYSTEM can.
- **Multi-strategy `Set-ServiceStart`**: direct → ACL takeover → SYSTEM task, with per-attempt logging.
- **SafeBoot trap** (Remove mode): clears `HKLM\SYSTEM\...\SafeBoot\Minimal\WinDefend` + `...\Network\WinDefend` so `WinDefend` can't load even in Safe Mode.
- **Expanded service surface** (via privacy.sexy): `MDDlpSvc`, `MsSecFlt`, `MsSecCore`, `SgrmAgent`, `SgrmBroker`, `webthreatdefsvc`, `webthreatdefusersvc`.
- **Expanded policy keys** (via privacy.sexy):
  - `MpEngine\MpEnablePus`, `EnableFileHashComputation`, `MpCloudBlockLevel`, `MpBafsExtendedTimeout`
  - `NIS\DisableProtocolRecognition`, `NIS\Consumers\IPS\DisableSignatureRetirement`, `ThrottleDetectionEventsRate`
  - `Real-Time Protection\DisableInformationProtectionControl`
  - `Spynet\LocalSettingOverrideSpynetReporting`
  - `Signature Updates\RealtimeSignatureDelivery`, `DisableUpdateOnStartupWithoutEngine`
  - `UX Configuration\Notification_Suppress`
  - Legacy `Microsoft Antimalware\ServiceKeepAlive`
- **Expanded MpPreference sweep**: `SignatureDisableUpdateOnStartupWithoutEngine`, `CloudBlockLevel`.
- Critical vs touch-refuse distinction in firewall guard.

## v0.0.1 - 2026-04-20

Initial release.

- Three modes: `Disable`, `Remove`, `Restore`, plus `Status`
- Firewall preservation with pre/post integrity guard (refuse-list of firewall services and policy paths)
- TrustedInstaller token elevation via embedded P/Invoke (`CreateProcessWithTokenW`)
- Full Defender policy coverage across 10 policy roots
- `Set-MpPreference` sweep + global path/extension/process exclusions
- 5 scheduled tasks disabled (Cache Maintenance, Cleanup, Scheduled Scan, Verification, ExploitGuard refresh)
- 10 services targeted: `WinDefend`, `WdFilter`, `WdBoot`, `WdNisDrv`, `WdNisSvc`, `Sense`, `SecurityHealthService`, `wscsvc`, `webthreat`, `MDCoreSvc`
- SecHealthUI Appx deprovision with DISM `NonRemovableAppPolicy` override
- DISM platform package removal (Remove mode)
- Safe Mode detection for deeper removal
- System Restore checkpoint before destructive ops
- Transcript + structured log
- Interactive menu + CLI + silent mode
