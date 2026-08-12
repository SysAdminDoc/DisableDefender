# Changelog

## Unreleased

### Added
- Added a versioned release-gate policy that pins Pester/PSScriptAnalyzer, ratchets test and command coverage, validates every source/archive version and artifact schema fixture, and reproduces the exact unsigned ZIP from a clean detached checkout.
- Added one persisted-artifact compatibility registry plus golden current/legacy/future fixtures for restore, recovery, snapshot, logging, support, error, and release formats.
- Added exported `Get-DefenderFirewallStatus` evidence for `mpssvc`, `BFE`, and the Domain, Private, and Public profiles; Health now reports the same shared evidence.
- Reimagined the WPF shell as a safety-first security control center with a command rail, six protection-state cards, component-health and policy-change views, and a compact live-activity panel.
- Added UI Automation names, keyboard focus treatment, maximize/restore chrome, F5 refresh, and accessible text labels for every status.
- Added one structured operation-result contract across phase state, logs, CLI JSON, and GUI completion feedback, with per-effect attempted, changed, verified, evidence, and error fields.
- Added durable restore replay/finalization state so partial manifest replay, failed baseline verification, and interrupted multi-manifest archival remain resumable.
- Added an explicit `-RepairWithoutManifest` fixed-default repair path in the CLI, module command, and GUI.
- Added `Get-DefenderSafeModeStatus` for live BCD/task evidence, persisted cross-boot stages, child/task results, verified effect counts, errors, and recovery guidance; the GUI component dashboard surfaces the same transaction state.
- Added explicit support-bundle health targeting, unique reparse-checked staging, local preview, a versioned privacy allowlist, redacted runtime diagnostics, and opt-in transcript/tripwire collection with no automatic upload.
- Added rollback-capable offline servicing artifacts: every generated offline mutation and hive mount is journaled, baselines are persisted before writes, unload is retried and verified, residual mounts fail nonzero, and `-RecoveryAction Rollback` replays the captured baseline.
- Added cooperative GUI cancellation at phase boundaries, a visible cancellation state, verified worker-result propagation, and deterministic runspace/dispatcher-timer draining and disposal.
- Added a GUI Recovery hub with target-aware cancellable evidence, persisted phase resume/rollback controls, Safe Mode status, target-aware snapshot/diff, and local HTML/support exports; snapshots now accept `-HealthTarget`.
- Hardened GUI accessibility with automation-name coverage for every named interactive control, visible keyboard focus in custom chrome/inputs, a startup minimum-layout contract, and a Windows high-contrast palette path; version-matched minimum-size dashboard and Recovery hub renders were inspected locally.
- Added localizable presentation resources for CLI text and key GUI controls, with deterministic `en-US` fallback, French extraction, pseudo-locale clipping checks, RTL metadata, and stable structured-log `message_id` fields.
- Added a local Windows tray completion notification with localized Open/Exit actions, green/yellow/red success-cancel-failure status icons, balloon severity mapping, and deterministic disposal on GUI shutdown.

### Fixed
- Release ZIP entries and metadata now use a fixed timestamp for byte-reproducible builds; the strict gate rejects missing tools, dirty release inputs, stale/wrong archives, bad hashes or metadata, content drift, unexpected signing, and clean-checkout hash mismatches.
- Phase state, surface baselines, snapshots, and support-bundle JSON now flush to same-directory temporary files, publish by atomic replacement, read-verify their own schema, and retain the previous artifact when publication fails; mutation-critical readers reject unknown future versions before use.
- Registry ACL takeover now flushes a versioned, allowlisted per-run JSON journal before each owner or DACL mutation, atomically replaces and read-verifies journal bytes, binds exact Restore to selected manifest RunIds, unwinds repeated runs newest-first, retains every active journal after partial failure, archives only fully verified replay, and still accepts the constrained legacy CLIXML format.
- Restore manifests, replay state, and registry ACL backups are now treated as privileged input: bounded versioned schemas and target allowlists reject the whole artifact before mutation, while one owner/DACL/reparse/file-identity-validated, no-write-shared lease supplies the exact replayed bytes.
- Release packaging now cleans only a newly created, file-identity-tracked staging directory; strict `dist` / unique-temp containment, reparse checks, path-substitution detection, and an immediate identity recheck protect every recursive delete. The builder now emits unsigned artifacts only.
- Firewall guards now fail closed when `mpssvc` or `BFE` is missing, disabled, stopped, or unverifiable, or when a required profile is missing, unavailable, or off; the GUI no longer maintains a weaker duplicate probe.
- Phase filters now apply only to mutation phases; prerequisite, managed/domain, Safe Mode, restore-point, and Firewall pre/postflight gates are mandatory, and an empty action selection fails before manifest creation.
- Safe Mode and offline generators preserve `-Force` only when the caller explicitly requests it instead of injecting a safety override.
- The GUI now blocks window closure while a privileged operation is active and drains completed runspaces instead of stopping workers abruptly.
- Minimum-size layouts keep actions, component evidence, and activity output reachable through bounded scrolling instead of overlapping controls.
- Destructive confirmation defaults keyboard focus to Cancel and separates warning, destructive, and recovery actions visually.
- Registry, MpPreference, task, service, SafeBoot, Appx, DISM, context-menu, restore-point, and ACL phases now fail on unverified required postconditions instead of accepting swallowed or zero-effect mutations.
- Disable and Remove save a surface baseline only after a verified non-simulation plan; action-mode JSON emits one success envelope and the GUI consumes the same verified result.
- Restore now replays and verifies the exact recorded registry, preference, task, service, SafeBoot, context-menu, Security Health, and DISM baseline before archiving the manifest; unreadable registry pre-state aborts before mutation.
- Repeated-run restore collapses final expectations to the oldest selected baseline, while exact Restore refuses partial phase filters and never falls through to fixed defaults.
- Safe Mode removal now verifies both exact SYSTEM startup-task definitions before BCD mutation, proves the watchdog is an independent `bcdedit.exe` action, read-verifies every BCD transition, persists child JSON/effect evidence and task exit results, reboots only after verified removal, and deterministically resumes, finalizes, or rolls back interrupted stages.
- Runtime-directory ACL inspection and repair now use an explicit `Get-Acl`/`Set-Acl` cross-edition adapter, with a checked Windows PowerShell fallback; module import and read-only Status/Health inspection no longer create or harden `%ProgramData%\DisableDefender`.
- Release text is normalized during packaging and the strict gate accepts CRLF checkouts, so clean detached builds reproduce the same ZIP bytes regardless of `core.autocrlf`.
- SecHealthUI removal and Health now share a versioned package/marker catalog, including LTSC identities, and Health distinguishes complete removal from partial marker state.
- The GUI log override now writes the same versioned JSONL fields as the module sink, including `message_id`, while preserving the existing human-readable log and in-app queue.

## v0.0.40 - 2026-06-30

### Fixed
- Invoke-SafeModeRemove never actually rebooted: added missing shutdown.exe call. Changed AtLogOn trigger to AtStartup for reliable Safe Mode task execution.
- Export-DefenderHtmlReport: HTML-encoded all health item and component values (stored XSS prevention). Fixed wrong component property name (Status -> RuntimeStatus). Fixed null-health crash with graceful fallback text. Changed word-break from break-all to overflow-wrap for readable registry paths.
- Write-Log: unified timestamp capture (single Get-Date call) so text and JSONL logs never diverge. Cached runtime directory check to avoid ACL inspection on every log line. JSONL now respects LogPathOverride directory.
- Set-RunOptions: reset RuntimeDirectoryVerified cache when log path changes between runs.
- Confirm-LanguageAndAppControl: removed duplicate language-mode log message.
- Confirm-Prereqs: wrapped SafeMode CIM query in error handler to prevent unhandled WMI failures from aborting the entire operation.
- Compare-DefenderSnapshots: added schema validation for baseline/current HealthItems to prevent NullReferenceException on arbitrary JSON input.
- Export-DefenderSupportBundle: now logs warnings when health or component collection fails instead of silently returning incomplete bundles.
- Register-RegistryValueUndo: empty catch block replaced with WARN-level log so original value read failures are visible instead of silently recording remove-on-restore.
- CLI: Show-DefenderStatus no longer called after Restore/Health modes, preventing double JSON output that broke automation output contracts.
- Test-ReleaseReadiness: coverage.xml now written to TEMP instead of polluting repo root.
- README: fixed stale -Mode parameter table (added PrepareOffline), fixed -Json description (applies to Status, Health, and errors), updated interactive menu description to include all 6 options.

### Changed
- Version metadata is aligned to `0.0.40` across the manifest, scripts, README badge, and changelog.

## v0.0.39 - 2026-06-30

### Added
- `Save-DefenderSnapshot` and `Compare-DefenderSnapshots` for side-by-side state diff between snapshots taken weeks apart.
- Snapshot comparison detects changed, added, and removed health items with before/after values.
- JSON output via `-Json` flag for automation.
- Pester coverage for snapshot diff change detection.

### Changed
- Module exports now include `Save-DefenderSnapshot` and `Compare-DefenderSnapshots`.
- Version metadata is aligned to `0.0.39` across the manifest, scripts, README badge, and changelog.

## v0.0.38 - 2026-06-30

### Added
- `Invoke-SafeModeRemove` public command: schedules a one-shot task that boots into Safe Mode, runs `-Mode Remove -Force -Silent`, clears the safeboot BCD flag, and reboots back to normal.
- Watchdog task registered as fallback to clear the safeboot flag if the Remove script fails.
- Refuses to schedule if already in Safe Mode (directs user to run Remove directly).
- Supports `-IncludeMDE`, `-NoRestorePoint`, and `-DelaySeconds` parameters.

### Changed
- Module exports now include `Invoke-SafeModeRemove`.
- Version metadata is aligned to `0.0.38` across the manifest, scripts, README badge, and changelog.

## v0.0.37 - 2026-06-30

### Added
- `Export-DefenderHtmlReport` public command: single-file HTML summary with health detail, component status, system info, and Catppuccin Mocha dark styling.
- Pester coverage for HTML report generation and content validation.

### Changed
- Module exports now include `Export-DefenderHtmlReport`.
- Version metadata is aligned to `0.0.37` across the manifest, scripts, README badge, and changelog.

## v0.0.36 - 2026-06-30

### Added
- SecHealthUI LTSC/variant fallback: wildcard Appx search when exact `Microsoft.SecHealthUI` name is absent, multiple deprovisioning marker paths, and graceful degradation on Server Core where Appx cmdlets are unavailable.
- DISM package removal now matches `Defender-Features` and `Defender-AM-Default` patterns for LTSC editions.
- Restore-SecHealthUI searches for `*SecHealthUI*` manifests and clears all known deprovisioning markers.

### Changed
- Version metadata is aligned to `0.0.36` across the manifest, scripts, README badge, and changelog.

## v0.0.35 - 2026-06-30

### Added
- Structured JSONL log at `%ProgramData%\DisableDefender\DisableDefender.jsonl` alongside the human-readable text log.
- Every `Write-Log` call emits a JSON object with `ts` (ISO 8601), `level`, and `msg` for SIEM/automation ingestion.
- JSONL log included in `Export-DefenderSupportBundle` output.

### Changed
- Version metadata is aligned to `0.0.35` across the manifest, scripts, README badge, and changelog.

## v0.0.34 - 2026-06-30

### Changed
- Policy definitions consolidated into `Get-DefenderPolicyCatalog` as single source of truth for both writes and health checks.
- `Set-DefenderPolicy` now iterates the catalog instead of inline `Set-RegValue` calls.
- `Get-ExpectedPolicyValues` delegates to the same catalog, eliminating drift risk.
- Pester test verifies every catalog entry appears in both write and health paths.
- Version metadata is aligned to `0.0.34` across the manifest, scripts, README badge, and changelog.

## v0.0.33 - 2026-06-30

### Added
- Third-party AV detection via Security Center WMI; warns when no alternative AV is registered after Disable.
- Smart App Control re-enable warning when SAC is enforcing (may restore Defender after reboot or feature update).
- MDE passive-mode detection via `ForceDefenderPassiveMode` policy and `AMRunningMode`; logs Sense preservation notice.
- Pester coverage for third-party AV filtering and MDE passive-mode detection.

### Changed
- Prerequisites phase now reports registered third-party AV products and absence of AV protection.
- Version metadata is aligned to `0.0.33` across the manifest, scripts, README badge, and changelog.

## v0.0.32 - 2026-06-30

### Added
- Local release-readiness checker at `tools/Test-ReleaseReadiness.ps1`.
- Checks: manifest validation, module import, version consistency across 5 locations, Pester tests with optional code coverage, ScriptAnalyzer (when installed), GUI/XAML parse, and release artifact inspection.
- Coverage output identifies untested files when `-SkipCoverage` is not passed.

### Changed
- Version metadata is aligned to `0.0.32` across the manifest, scripts, README badge, and changelog.

## v0.0.31 - 2026-06-30

### Added
- `Export-DefenderSupportBundle` public command for diagnostic zip export.
- Support bundle collects logs, phase-state, tripwires, component status, health summary, surface baseline, and Windows build info.
- Optional `-IncludeEventLog` flag for redacted Defender event-log excerpts (file paths scrubbed).
- Secrets excluded by design: no restore manifests, ACL backups, or registry value snapshots.
- Pester coverage for bundle zip contents and secret exclusion.

### Changed
- Module exports now include `Export-DefenderSupportBundle`.
- Version metadata is aligned to `0.0.31` across the manifest, scripts, README badge, and changelog.

## v0.0.30 - 2026-06-30

### Added
- PowerShell language-mode and App Control preflight in `Confirm-Prereqs`.
- ConstrainedLanguage mode detection with remediation guidance (signing or offline bundle).
- Smart App Control / App Control for Business status detection and warning.
- Pester coverage for FullLanguage, ConstrainedLanguage, unknown mode, and SAC status logging.

### Changed
- Prerequisites phase now checks language mode before Tamper Protection.
- Version metadata is aligned to `0.0.30` across the manifest, scripts, README badge, and changelog.

## v0.0.29 - 2026-06-30

### Added
- Structured CLI JSON error envelope for `-Json` mode with `Ok`, `Mode`, `ExitCode`, `ErrorCode`, `Message`, `FailedPhase`, `PhaseStatePath`, `RepairCommands`, and `Timestamp`.
- Centralized exit-code contract table covering Tamper Protection (2), Safe Mode (3), Firewall (4), managed device (5), Restore verification (6), phase filter (7), remoting blocked (8), and domain-joined (9).
- Pester coverage for all error-code mappings and JSON envelope serialization.

### Changed
- CLI fatal paths now use `Get-DefenderErrorMapping` instead of regex classification.
- With `-Json`, fatal errors emit a stable machine-readable object instead of a MessageBox or console message.
- Version metadata is aligned to `0.0.29` across the manifest, scripts, README badge, and changelog.

## v0.0.28 - 2026-06-30

### Added
- WinRE/offline servicing mode via `New-OfflineRemoveBundle` and CLI `-Mode PrepareOffline`.
- Self-contained `Invoke-OfflineDefenderRemove.ps1` generator that targets offline Windows volumes.
- Offline script loads SOFTWARE and SYSTEM registry hives, applies all Defender policy keys, disables services, removes SafeBoot entries, and disables WMI Autologger telemetry.
- Live system drive refusal to prevent accidental execution against the booted OS.
- ControlSet resolution from the offline SYSTEM hive Select key.
- Firewall refuse-list enforcement in the offline script (same guarantees as live mode).
- Post-run guidance for completing live-only steps (MpPreference, tasks, Appx, DISM).
- Pester coverage for bundle generation, script validity, refuse-list embedding, and live-drive refusal.

### Changed
- Module exports now include `New-OfflineRemoveBundle`.
- CLI interactive menu adds option 6 for PrepareOffline.
- Version metadata is aligned to `0.0.28` across the manifest, scripts, README badge, and changelog.

## v0.0.27 - 2026-06-30

### Added
- Local release builder at `tools/New-DisableDefenderRelease.ps1`.
- Optional Authenticode signing by certificate thumbprint or PFX path.
- Release SHA256 sidecar and release metadata JSON.
- README guidance for Smart App Control behavior, signature verification, and unsigned fallback execution.
- Pester coverage that builds the local unsigned release zip and verifies release contents.

### Changed
- Release artifacts now exclude roadmap and research notes from the install zip.
- Version metadata is aligned to `0.0.27` across the manifest, scripts, README badge, and changelog.

## v0.0.26 - 2026-06-30

### Added
- Defender surface baseline saved after successful Disable/Remove runs.
- Health drift detection for changed Windows builds and unknown Defender-like services, scheduled tasks, and Appx packages.
- CLI health reapply plan that preserves firewall and MDE Sense by default unless `-IncludeMDE` is explicit.
- Pester coverage for unknown surface detection, build-baseline drift, and component status unknown service rows.

### Changed
- Component status now includes unknown Defender-like services as drift rows for GUI visibility after feature updates.
- Version metadata is aligned to `0.0.26` across the manifest, scripts, README badge, and changelog.

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

## Roadmap archive — 2026-08-10 — ROADMAP.md

<details>
<summary>Original roadmap snapshot</summary>

```markdown
# DisableDefender Roadmap

Actionable work beyond v0.0.18. Completed work is removed. True blockers live in `Roadmap_Blocked.md`.

## P2 - GUI

- Toast and system tray notification on run completion with exit-code color.

## P2 - CLI And Coverage

- Track new Windows 26H1/26H2 Defender surfaces as Microsoft ships them.
  Research cross-reference (2026-07-29): publish an edition/build/architecture support matrix with an absolute last-validated date; distinguish Windows 10 consumer EOS, LTSC 2019, Windows 11 24H2/25H2, and new-device-only 26H1; keep README, changelog, and local VM coverage aligned.

## P3 - Diagnostics

- ETW subscription for `Microsoft-Windows-Windows Defender` during run to surface silent Defender reactions.

## P3 - Optional Tools

- Fleet mode (`-ComputerName`) via WinRM with explicit opt-in for batch status collection.
- ADMX template that disables Defender via GPO for shops that prefer GPO-first.
- Integration hook with DefenderShield so the DisableDefender undo manifest wins.
- "Disable everything except cloud sample submission" preset for users who want cloud reputation lookups but no local scanning.

## Research-Driven Additions

### P1

- [ ] P1 — Build and gate releases from a clean checkout
  Why: The documented release depends on an untracked builder and the 2026-07-29 gate accepts stale ZIPs, missing test tools, and unratcheted coverage.
  Evidence: `tools/New-DisableDefenderRelease.ps1`, `tools/Test-ReleaseReadiness.ps1`, `Tests/DisableDefender.Tests.ps1`, Pester 5.9.0/6.0.0 releases, PSScriptAnalyzer 1.25.0.
  Touches: release scripts, manifest/version checks, test fixtures, README/changelog/release checklist.
  Acceptance: A fresh detached checkout produces the exact unsigned ZIP; source/module/GUI/docs/archive versions match; an artifact hash manifest is emitted; missing Pester/PSScriptAnalyzer, wrong or stale archives, schema failures, or coverage below a ratcheted threshold fail the gate; the supported Pester major is pinned and tested.
  Complexity: M

- [ ] P1 — Restore declared PowerShell 7 compatibility
  Why: PowerShell 7.6.3 cannot import the module because runtime ACL code calls Windows PowerShell-only `DirectoryInfo` methods.
  Evidence: `Private/RuntimeDirectory.ps1`, README runtime claim, Microsoft Windows PowerShell compatibility differences, `Get-Acl` documentation.
  Touches: runtime-directory/ACL helpers, module manifest, native/cmdlet compatibility adapters, tests, README.
  Acceptance: Import, read-only commands, and supported mutations pass on Windows PowerShell 5.1 and PowerShell 7.4/7.6; incompatible Windows-only cmdlets use an explicit checked 5.1 adapter where required; `CompatiblePSEditions` and README state the tested boundary.
  Complexity: M

- [ ] P1 — Unify LTSC Appx removal and health matching
  Why: Removal accepts wildcard package variants and two markers while Health checks one exact identity and one marker, producing false success or drift.
  Evidence: `Private/Remove-DefenderPlatformPackages.ps1`, `Public/Get-DefenderHealth.ps1`, `Tests/DisableDefender.Tests.ps1`.
  Touches: a shared package/marker catalog, remover, Health, tests.
  Acceptance: Removal and Health consume the same versioned catalog; fixtures cover both known package identities, both markers, already-absent and partial states; verified removal cannot immediately report contradictory health.
  Complexity: S

- [ ] P1 — Make read-only module use side-effect free
  Why: Import and inspection initialize and harden `%ProgramData%\DisableDefender`, so non-admin read-only use mutates the machine before a requested operation.
  Evidence: `DisableDefender.psm1`, `Private/RuntimeDirectory.ps1`, CLI startup flow.
  Touches: module/CLI bootstrap, runtime-directory initialization, Status/Health/help paths, tests.
  Acceptance: Import, help, command discovery, Status, and other declared read-only paths create no files, directories, ACLs, tasks, or registry changes; the first mutating operation performs and reports runtime preflight; non-admin tests verify both behaviors.
  Complexity: M

- [ ] P1 — Add a local disposable-VM and fault-injection acceptance matrix
  Why: Mocks cannot prove reboot, Safe Mode, DISM, offline hive, service/task, update-drift, Firewall, x64, or ARM64 recovery invariants.
  Evidence: 2026-07-29 Pester coverage, Microsoft Windows lifecycle/release-health pages, competitor recovery issues, repository local-only testing rule.
  Touches: local test tooling, VM fixtures/snapshots, recovery evidence, release checklist.
  Acceptance: Disposable images cover Windows 10 LTSC 2019 and supported Windows 11 releases/architectures available to maintainers with PowerShell 5.1 and 7; each destructive phase has pre/effect/restore assertions, Firewall invariants, injected interruption points, and retained machine-readable evidence; no hosted CI or signing is introduced.
  Complexity: XL

### P2

- [ ] P2 — Add a GUI recovery and diagnostics hub
  Why: The GUI hides manifest selection, target-aware Health, phase resume state, snapshots/diff, reapply plans, support/report export, and failed-effect evidence needed to recover safely.
  Evidence: `DisableDefender.GUI.ps1`, CLI public commands, O&O recovery UX, NTLite Host Refresh, competitor revert issues.
  Touches: `DisableDefender.GUI.ps1`, shared operation results, Health, manifest/phase-state APIs, report/support commands.
  Acceptance: One view shows selected baseline/target, exact live drift, last verified result, interrupted phase with resume/rollback, snapshots/diff, and local report/support export; Sense is not counted as disabled under the default preserve policy; queries are cancellable and never claim success before shared verification completes.
  Complexity: L

- [ ] P2 — GUI accessibility and screenshot verification pass
  Why: The WPF GUI is the recommended path but has no UI Automation metadata, access keys, explicit keyboard/focus model, high-contrast resources, localization resources, or reliable minimum-size layout.
  Evidence: RESEARCH.md Architecture Assessment; `DisableDefender.GUI.ps1`; `README.md`; Microsoft WPF localization/high-contrast guidance; WCAG 2.2.
  Touches: `DisableDefender.GUI.ps1`, resource dictionaries, README, local UI Automation/screenshot workflow.
  Acceptance: All controls expose programmatic names/roles/states, keyboard access and visible focus; default/cancel/close behavior is safe; color is not the only status cue; normal/high-contrast themes meet 4.5:1 for body text; content remains operable at supported minimum size and DPI; a version-matched screenshot plus local UI Automation/layout checks are documented.
  Complexity: M

- [ ] P2 — Introduce localizable presentation resources
  Why: User-facing strings are embedded across XAML and scripts, preventing a stable localization path and mixing human text with automation contracts.
  Evidence: `DisableDefender.GUI.ps1`, `DisableDefender.ps1`, public commands, Microsoft WPF globalization/localization guidance, O&O 3.0/3.2 localization releases.
  Touches: GUI resource dictionaries, CLI message catalog, stable message IDs, help/docs, localization tests.
  Acceptance: GUI and human CLI text resolve through an `en-US` resource catalog with deterministic fallback; JSON/log schemas retain stable machine keys and message IDs; a pseudo-locale and RTL smoke test catch clipping/order assumptions; one additional reference locale proves extraction without translating privileged action names.
  Complexity: L

## Audit Findings (2026-06-30)

- [ ] P2 - GUI Write-Log override missing JSONL output
  Why: When running via GUI, no JSONL entries are written because the GUI overrides Write-Log without the JSONL block.
  Where: `DisableDefender.GUI.ps1` lines 83-93.
  Research cross-reference (2026-07-29): route GUI and CLI through the shared structured result/log sink, surface sink failure, add operation correlation IDs and bounded rotation, and keep JSONL machine fields stable.

- [ ] P2 - GUI system tray notification on run completion with exit-code color
  Why: The GUI already has in-app toasts but lacks OS-level notification for background-aware completion.
  Where: `DisableDefender.GUI.ps1`.

- [ ] P2 - CLI JSON success envelope for Disable/Remove/Restore
  Why: With -Json, successful operations emit raw status output with no Ok=true wrapper; error path has envelope. Automation cannot parse both consistently.
  Where: `DisableDefender.ps1` Invoke-SelectedMode.
  Research cross-reference (2026-07-29): make this the serialization of the shared effect-verified operation result; runtime initialization/import/argument failures must use the same envelope and PowerShell 5.1-valid repair commands.

- [ ] P2 - Invoke-AsSystem still uses cmd.exe despite CHANGELOG v0.0.5 claiming removal
  Why: Output redirection requires cmd.exe wrapper; CHANGELOG is inaccurate. Low practical risk but misleading documentation.
  Where: `Private/Invoke-AsSystem.ps1` line 18-19; `CHANGELOG.md` v0.0.5 Security section.

- [ ] P1 - Make support-bundle targeting, staging, and privacy explicit
  Why: The bundle hard-codes Disable health after Remove, while second-resolution staging and raw log/transcript/tripwire/domain collection create collision, recursive-delete, and disclosure risks.
  Where: `Public/Export-DefenderSupportBundle.ps1`.
  Research cross-reference (2026-07-29): derive or require the target, use unique reparse-safe staging, define a versioned privacy allowlist/redaction schema, show a local preview, and never upload automatically.

- [ ] P1 - Make offline servicing a rollback-capable transaction
  Why: Registry handles can block unload, a failure between hive mounts can evade cleanup, unload failure can still exit zero, and no machine-readable undo artifact is emitted.
  Where: `Public/New-OfflineRemoveBundle.ps1` generated script, mount/dismount and action plan.
  Research cross-reference (2026-07-29): journal every mount and mutation, release handles in `finally`, retry and verify unload, fail nonzero on residual mounts, and emit a replayable offline baseline/result artifact.

- [ ] P1 - Make GUI cancellation and runspace cleanup safe
  Why: Close remains available during mutation, `Stop()` can interrupt a phase abruptly, `EndInvoke` is not consistently called, exceptions are swallowed, and result state can race with worker startup.
  Where: `DisableDefender.GUI.ps1` worker, timer, close handler, and `LastResult`.
  Research cross-reference (2026-07-29): prevent unsafe close during non-cancellable transitions, support cooperative cancellation at phase boundaries, always drain/dispose workers and timers, and propagate the shared verified result.

- [ ] P3 - Portable preset export/import for Defender-adjacent preferences
  Why: O&O ShutUp10++ and privacy tools show value in portable, explainable presets; this project should keep it narrow to Defender AV/MAPS/sample-submission choices.
  Evidence: RESEARCH.md Competitive Landscape; O&O ShutUp10++ import/export behavior; existing ROADMAP cloud sample submission preset.
  Touches: `Public/Get-DefenderHealth.ps1`, `Private/Set-MpRuntimePrefs.ps1`, `DisableDefender.GUI.ps1`, `README.md`.
  Acceptance: Users can export/import a small JSON preset for supported Defender-adjacent choices; unsupported broad privacy tweaks are rejected with a clear message.
  Complexity: M
  Research cross-reference (2026-07-29): implement only as versioned serialization for the existing cloud-sample-submission preset; do not add arbitrary actions or a general privacy catalog.
```

</details>
