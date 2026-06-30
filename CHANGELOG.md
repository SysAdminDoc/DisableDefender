# Changelog

## v0.0.25 - 2026-06-30

### Added
- Runtime directory preflight that refuses reparse-point `%ProgramData%\DisableDefender` paths.
- Runtime directory ACL hardening that repairs inherited or non-admin/SYSTEM write access.
- Pester coverage for safe runtime directories, reparse-point refusal, and weak-DACL repair.

### Changed
- Logs, restore manifests, phase state, tripwires, ACL backups, and SYSTEM task output now assert the runtime directory before writing.
- Version metadata is aligned to `0.0.25` across the manifest, scripts, README badge, and changelog.

## v0.0.24 - 2026-06-30

### Added
- Restore manifest selection via `-ManifestSelection Newest|All|Active`.
- Detection and warning for archived restore manifests left behind by repeated Disable/Remove runs.
- Pester coverage for two-run restore chains and newest-vs-all manifest replay behavior.

### Changed
- Restore now selects the newest non-empty manifest by default and can replay all active/archived manifests newest-first.
- Replayed archived manifests are moved to restored archives instead of being left as active undo candidates.
- Version metadata is aligned to `0.0.24` across the manifest, scripts, README badge, and changelog.

## v0.0.23 - 2026-06-30

### Added
- SYSTEM scheduled-task fallback now logs task output and final `LastTaskResult`.
- Pester coverage for successful and failed SYSTEM fallback task results.
- Pester coverage for service-start and SafeBoot target-state verification.

### Changed
- Service start writes now verify the registry value after direct, ACL, and SYSTEM strategies before reporting success.
- SafeBoot WinDefend removal now fails the phase if a targeted key remains after SYSTEM fallback.
- Version metadata is aligned to `0.0.23` across the manifest, scripts, README badge, and changelog.

## v0.0.22 - 2026-06-30

### Added
- Shared MpPreference catalog used by Disable, Restore, and Health.
- Health coverage for every runtime MpPreference write and every managed path / extension exclusion.
- Pester parity checks that fail when a runtime preference lacks restore or health coverage.

### Changed
- Restore now resets all runtime preferences written by Disable, including signature schedule, scan schedule, cloud, network protection, and parsing preferences.
- Version metadata is aligned to `0.0.22` across the manifest, scripts, README badge, and changelog.

## v0.0.21 - 2026-06-30

### Added
- Restore manifest schema validation for every replay entry.
- Restore manifest integrity logs with run IDs, entry count, and SHA256 digest before replay and archive.
- Pester coverage for refused unexpected actions and malformed action data.

### Changed
- Restore now refuses unknown or malformed manifest actions instead of warning through replay.
- Version metadata is aligned to `0.0.21` across the manifest, scripts, README badge, and changelog.

## v0.0.20 - 2026-06-28

### Added
- Post-Restore health verification against the Restore target.
- Repair-command logging for remaining service, Appx, task, policy, and MpPreference drift.
- Silent Restore now exits non-zero when verification still finds drift or unknown state.

### Changed
- Version metadata is aligned to `0.0.20` across the manifest, scripts, README badge, and changelog.

## v0.0.19 - 2026-06-28

### Fixed
- GUI Disable/Remove no longer pass `-Force` automatically; users must explicitly select the safety override checkbox.
- Firewall guard failures now fail closed at preflight, per-phase before/after boundaries, and postflight instead of warning through preflight failures.

### Changed
- Version metadata is aligned to `0.0.19` across the manifest, scripts, README badge, and changelog.

## v0.0.18 - 2026-06-27

### Added
- Always-on GUI firewall integrity banner.
- Live polling for mpssvc, BFE, and firewall profile health.
- Red flash on firewall guard-trip log events from pre/post operation boundaries.

### Changed
- GUI footer now switches from preserved to attention-required when firewall integrity is degraded.
- Version metadata is aligned to `0.0.18` across the manifest, scripts, README badge, and changelog.

## v0.0.17 - 2026-06-27

### Added
- Live GUI policy edit stream.
- Method icons for direct registry writes, ACL override writes, and SYSTEM scheduled-task fallback writes.

### Changed
- Clear Log now clears the policy edit stream alongside the full log pane.
- Version metadata is aligned to `0.0.17` across the manifest, scripts, README badge, and changelog.

## v0.0.16 - 2026-06-27

### Added
- `Get-DefenderComponentStatus` for GUI component inventory.
- GUI component lockdown grid covering Defender services and drivers.
- PPL / LaunchProtected display for MsMpEng, WdFilter, WdBoot, and WdNisDrv.
- Pester coverage for component inventory and JSON output.

### Changed
- Dashboard now surfaces each locked-down component instead of only aggregate service counts.
- Version metadata is aligned to `0.0.16` across the manifest, scripts, README badge, and changelog.

## v0.0.15 - 2026-06-27

### Added
- GUI Disable confirmation diff panel.
- Current-vs-target drift preview powered by `Get-DefenderHealth -Target Disable`.

### Changed
- Disable confirmation modal widened and made scrollable for compact drift details before execution.
- Version metadata is aligned to `0.0.15` across the manifest, scripts, README badge, and changelog.

## v0.0.14 - 2026-06-27

### Added
- PSRemoting / PSSession execution guard for Disable, Remove, and Restore.
- `-AllowRemoting` explicit override for module commands and CLI launcher.
- Tripwire logging for blocked and overridden remoting sessions.
- Pester coverage for remoting refusal and override behavior.

### Changed
- Disable/Remove/Restore now fail closed in remoting contexts unless `-AllowRemoting` is passed.
- Version metadata is aligned to `0.0.14` across the manifest, scripts, README badge, and changelog.

## v0.0.13 - 2026-06-27

### Added
- System Restore throttle-aware checkpoint messaging.
- Pester coverage for restore-point interval detection and configured throttle reporting.

### Changed
- Restore point failures caused by Windows restore-point creation frequency now log the throttle window instead of a generic warning.
- Version metadata is aligned to `0.0.13` across the manifest, scripts, README badge, and changelog.

## v0.0.12 - 2026-06-27

### Added
- Domain-joined Remove safety gate.
- Machine-readable tripwire log at `%ProgramData%\DisableDefender\tripwire.jsonl`.
- Pester coverage for blocked domain-joined Remove and `-Force` override tripwire entries.

### Changed
- Remove now refuses domain-joined machines unless `-Force` is passed.
- Version metadata is aligned to `0.0.12` across the manifest, scripts, README badge, and changelog.

## v0.0.11 - 2026-06-27

### Added
- Per-phase firewall boundary polling before and after every executed phase.
- Pester assertions that completed phases run pre/post firewall guards and failed phases run the pre-phase guard before recording failure.

### Changed
- Phase failures now capture firewall guard failures through the same `phase-state.json` partial-state path.
- Version metadata is aligned to `0.0.11` across the manifest, scripts, README badge, and changelog.

## v0.0.10 - 2026-06-27

### Added
- `Get-DefenderHealth` public command.
- CLI `-Mode Health` with `-HealthTarget Disable|Remove|Restore` and `-Json` support.
- Health drift reporting for Defender policy keys, service start types, scheduled tasks, SecHealthUI Appx presence, SafeBoot keys, and selected MpPreference values.
- Pester coverage for health summaries and JSON output.

### Changed
- Module exports now include `Get-DefenderHealth`.
- Version metadata is aligned to `0.0.10` across the manifest, scripts, README badge, and changelog.

## v0.0.9 - 2026-06-27

### Added
- `-Only` and `-Skip` phase filters for module commands and the CLI launcher.
- Phase keys for surgical reruns: `Policies`, `MpPreference`, `Tasks`, `Services`, `Appx`, `DISM`, `SafeBoot`, and `ContextMenu`.
- Pester coverage for phase filter execution, skipped phase state records, and empty-filter failure handling.

### Changed
- Phase state now records active `Only` / `Skip` filters and skipped phase reasons.
- Version metadata is aligned to `0.0.9` across the manifest, scripts, README badge, and changelog.

## v0.0.8 - 2026-06-27

### Added
- Atomic phase runner for Disable, Remove, and Restore.
- Runtime phase-state file at `%ProgramData%\DisableDefender\phase-state.json`.
- Pester coverage for completed phase recording and failed-phase partial-state capture.

### Changed
- Mode execution now logs named phase boundaries and records failed phase, partial state, and recovery choices.
- Remove mode fails closed when not in Safe Mode unless `-Force` is passed, avoiding interactive continuation prompts.
- Version metadata is aligned to `0.0.8` across the manifest, scripts, README badge, and changelog.

## v0.0.7 - 2026-06-27

### Added
- Replay-based restore manifest at `%ProgramData%\DisableDefender\restore-manifest.jsonl`.
- Reverse-order manifest replay before legacy Restore cleanup.
- Pester coverage for manifest write/read, reverse replay ordering, and absent registry value undo entries.

### Changed
- Disable/Remove now capture undo entries for policy registry values, MpPreference changes, scheduled tasks, service start/stop changes, SafeBoot keys, SecHealthUI removal, DISM package removal, and Defender context-menu cleanup.
- Version metadata is aligned to `0.0.7` across the manifest, scripts, README badge, and changelog.

## v0.0.6 - 2026-06-27

### Added
- Proper PowerShell module packaging with `DisableDefender.psd1`, `DisableDefender.psm1`, `Public/`, and `Private/`.
- Manifest and export tests that verify `Import-Module .\DisableDefender.psd1` exposes only the public commands.

### Changed
- `DisableDefender.ps1` is now a module-backed CLI launcher instead of the implementation host.
- `DisableDefender.GUI.ps1` imports the module and calls exported commands from its worker runspace while preserving live GUI log streaming.
- Version metadata is aligned to `0.0.6` across the manifest, scripts, README badge, and changelog.

## v0.0.5 - 2026-06-15

### Fixed
- **Clear-MpRuntimePrefs omitted 24H2/25H2 parameters**: 7 new preferences (CoreService, SSH/RDP parsing, etc.) were set during Disable but never restored during Restore. All are now properly undone.
- **HKCR: PSDrive dead code in context menu**: `Remove-DefenderContextMenu` referenced `HKCR:\` paths that don't exist as a PSDrive in PowerShell. Removed — the `HKLM:\SOFTWARE\Classes` paths cover the same keys.
- **Double Get-TargetServices call**: `Disable-DefenderServices` called `Get-TargetServices` twice (once via `Stop-DefenderServices`, once directly), producing duplicate "MDE services included" log warnings. Inlined the stop loop.
- **GUI version stuck at v0.0.4**: XAML `versionText` was hardcoded. Now dynamically set from `$script:Version` at startup.
- **Confirmation overlay didn't block title bar**: Modal spanned only the body row, allowing close/minimize during confirmation. Now spans all rows.
- **Core script header said v0.0.4**: Updated to v0.0.5.

### Added
- Escape key dismisses the confirmation overlay in the GUI.
- 2 new Pester tests for WhatIf behavior (Grant-RegKeyControl, Invoke-AsSystem).

### Security
- **Removed wildcard `ExclusionProcess @('*')`** from `Set-MpRuntimePrefs`. This silently blinded Defender without triggering Security Center alerts (MITRE T1562.001). Drive-level exclusions (`C:\`, `D:\`, `E:\`) remain and are sufficient.
- **ACL backup/restore** in `Grant-RegKeyControl`: original owner and DACL are saved to `%ProgramData%\DisableDefender\acl-backup.clixml` before takeover. `Restore` mode re-applies original ACLs. Addresses CVE-2026-33825 class of weakness.
- **MDE Sense service preserved by default**: `Sense` (Defender for Endpoint EDR) removed from default service list to avoid blinding enterprise SOCs. New `-IncludeMDE` flag re-adds it for explicit opt-in.
- **`Invoke-AsSystem` no longer uses `cmd.exe`**: replaced `cmd.exe /c $Command` with direct `reg.exe` execution via `New-ScheduledTaskAction -Execute`, eliminating the command injection surface at SYSTEM privilege level.

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
