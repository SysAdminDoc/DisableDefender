# DisableDefender Roadmap

Actionable work beyond v0.0.18. Completed work is removed. True blockers live in `Roadmap_Blocked.md`.

## P2 - GUI

- Toast and system tray notification on run completion with exit-code color.

## P2 - CLI And Coverage

- Full CLI parity with GUI: `-Mode Disable|Remove|Restore|Status|Health`, `-Silent`, `-DryRun`, `-NoRestorePoint`, `-NoReboot`, `-Force`, `-LogPath`, `-Json`, `-Only`, `-Skip`.
- Auto-detect third-party AV registered in Security Center and warn when it is absent after Disable.
- Track new Windows 26H1/26H2 Defender surfaces as Microsoft ships them.
- MDE passive-mode handling: when `PassiveMode` is enabled upstream, make sure Disable leaves the MDE sensor intact.
- Remove `Microsoft.SecHealthUI` with fallback path for Enterprise LTSC where DISM package IDs differ.
- Detect and handle Windows 11 Smart App Control policy that can force Defender on.

## P3 - Diagnostics

- Structured JSONL log alongside transcript for SIEM ingestion, local only.
- ETW subscription for `Microsoft-Windows-Windows Defender` during run to surface silent Defender reactions.
- `Export-HtmlReport` subcommand that builds a single-file HTML summary of the run.

## P3 - Optional Tools

- Side-by-side state diff between two snapshots taken weeks apart.
- Fleet mode (`-ComputerName`) via WinRM with explicit opt-in for batch status collection.
- Safe Mode bootstrap helper: schedule a one-shot task that boots into Safe Mode, runs `-Mode Remove`, then reboots back to normal.
- ADMX template that disables Defender via GPO for shops that prefer GPO-first.
- Integration hook with DefenderShield so the DisableDefender undo manifest wins.
- "Disable everything except cloud sample submission" preset for users who want cloud reputation lookups but no local scanning.

## Research-Driven Additions

- [ ] P1 - WinRE/offline servicing mode for protected live systems
  Why: Microsoft and NTLite evidence show live Tamper Protection blocks registry/service edits, while offline images/WinRE avoid WdFilter live protection.
  Evidence: RESEARCH.md Competitive Landscape; Microsoft tamper-protection docs; NTLite offline Defender discussions; `Private\Set-ServiceStart.ps1`; `Private\SafeBoot.ps1`.
  Touches: `Public/Invoke-RemoveDefender.ps1`, `Private/SafeBoot.ps1`, new functions under `Private/`, `README.md`, `Tests/DisableDefender.Tests.ps1`.
  Acceptance: A `-PrepareOfflineRemove` or equivalent mode creates a one-shot WinRE/offline script bundle that targets an offline Windows volume, logs actions, and refuses to run against the live system root.
  Complexity: L

- [ ] P1 - Feature-update drift detector and reapply plan
  Why: Defender-removal competitors repeatedly break after Windows feature updates, especially 25H2/26H-era changes; DisableDefender should detect changed surfaces before hard-coded assumptions fail.
  Evidence: RESEARCH.md Competitive Landscape; ionuttbara/windows-defender-remover issues #263/#270; Microsoft Defender Core service docs; existing ROADMAP 26H1/26H2 tracking item.
  Touches: `Public/Get-DefenderComponentStatus.ps1`, `Public/Get-DefenderHealth.ps1`, `Private/Variables.ps1`, `Tests/DisableDefender.Tests.ps1`, `README.md`.
  Acceptance: Health output flags unknown Defender services/packages/tasks and changed Windows build; CLI/GUI provide a "reapply Disable after feature update" plan without modifying firewall or MDE Sense by default.
  Complexity: M

- [ ] P1 - Signed release and Smart App Control distribution path
  Why: Smart App Control blocks unknown/unsigned code; Defender tools are especially reputation-sensitive, so unsigned zips/scripts undermine installability and trust.
  Evidence: RESEARCH.md Sources - Smart App Control FAQ and Microsoft code-signing guidance; es3n1n/defendnot issue #48; `dist/DisableDefender-v0.0.17.zip`; README distribution section.
  Touches: `DisableDefender.psd1`, `README.md`, release packaging scripts if added, artifact build process.
  Acceptance: Local release build produces a signed zip or signed launcher where certificate availability permits; README documents SAC behavior, signature verification, and fallback manual script execution.
  Complexity: L

- [ ] P2 - Pester coverage report and local release-check script
  Why: Risky registry, replay, GUI classifier, and phase-runner branches are growing faster than measured test coverage.
  Evidence: RESEARCH.md Architecture Assessment; Pester code coverage docs; existing `Tests/DisableDefender.Tests.ps1`; `PSScriptAnalyzerSettings.psd1`.
  Touches: `Tests/DisableDefender.Tests.ps1`, optional local release script, `README.md`.
  Acceptance: A local command runs manifest validation, Pester with coverage, ScriptAnalyzer, GUI/XAML parse, version consistency, and artifact inspection; coverage output identifies untested files without using GitHub Actions.
  Complexity: M

- [ ] P2 - GUI accessibility and screenshot verification pass
  Why: The WPF GUI is now the primary recommended path, but README still has a screenshot placeholder and there is no UI Automation/accessibility evidence.
  Evidence: RESEARCH.md Architecture Assessment; `DisableDefender.GUI.ps1`; `README.md` screenshot placeholder.
  Touches: `DisableDefender.GUI.ps1`, `README.md`, local screenshot capture workflow.
  Acceptance: All actionable controls have accessible names/tooltips, text does not clip at supported window sizes, README screenshot is recaptured from v0.0.18+ GUI, and a local GUI parse/screenshot check is documented.
  Complexity: M

- [ ] P2 - Exportable support bundle
  Why: Competitor issues show users struggle to explain broken states; DisableDefender already has logs, phase state, manifest, tripwires, and health output that should be bundled for diagnosis.
  Evidence: RESEARCH.md Security, Privacy, and Reliability; `Private/PhaseRunner.ps1`; `Private/ReplayManifest.ps1`; `%ProgramData%\DisableDefender` paths in README.
  Touches: `Public/Get-DefenderHealth.ps1`, new public export command, `DisableDefender.psd1`, `DisableDefender.GUI.ps1`, `README.md`, tests.
  Acceptance: A command exports logs, phase-state, tripwire entries, component status, health summary, Windows build, and optional redacted event-log excerpts into a zip without secrets.
  Complexity: M

- [ ] P2 - Data-driven Defender policy catalog
  Why: Policy definitions are duplicated between write logic and health logic, which can drift as Microsoft adds Defender CSP/policy surfaces.
  Evidence: RESEARCH.md Architecture Assessment; `Private/Set-DefenderPolicy.ps1`; `Public/Get-DefenderHealth.ps1`; Microsoft Defender CSP docs.
  Touches: `Private/Set-DefenderPolicy.ps1`, `Public/Get-DefenderHealth.ps1`, `Private/Variables.ps1`, tests.
  Acceptance: A single in-module catalog drives policy writes, health expected values, and README table generation or validation; tests fail if a writable policy lacks a health expectation.
  Complexity: M

- [ ] P3 - Portable preset export/import for Defender-adjacent preferences
  Why: O&O ShutUp10++ and privacy tools show value in portable, explainable presets; this project should keep it narrow to Defender AV/MAPS/sample-submission choices.
  Evidence: RESEARCH.md Competitive Landscape; O&O ShutUp10++ import/export behavior; existing ROADMAP cloud sample submission preset.
  Touches: `Public/Get-DefenderHealth.ps1`, `Private/Set-MpRuntimePrefs.ps1`, `DisableDefender.GUI.ps1`, `README.md`.
  Acceptance: Users can export/import a small JSON preset for supported Defender-adjacent choices; unsupported broad privacy tweaks are rejected with a clear message.
  Complexity: M

- [ ] P1 - Runtime directory reparse-point and ACL preflight
  Why: `%ProgramData%\DisableDefender` receives privileged manifests, logs, phase state, tripwires, and ACL backups; existing code hardens ACLs only when creating the directory, so a pre-existing junction/symlink or weak DACL can redirect or expose sensitive artifacts.
  Evidence: RESEARCH.md Security, Privacy, and Reliability; `DisableDefender.psm1`; `DisableDefender.ps1`; `Private/Write-Log.ps1`; `Private/ReplayManifest.ps1`; `Private/PhaseRunner.ps1`; `Private/Tripwire.ps1`; Microsoft reparse-point operations docs.
  Touches: `DisableDefender.psm1`, `DisableDefender.ps1`, `Private/Write-Log.ps1`, `Private/ReplayManifest.ps1`, `Private/PhaseRunner.ps1`, `Private/Tripwire.ps1`, `Tests/DisableDefender.Tests.ps1`.
  Acceptance: Startup refuses or repairs a pre-existing runtime directory that is a reparse point or grants non-admin/SYSTEM write access; tests cover safe directory, reparse-point directory, and weak-DACL cases.
  Complexity: M

- [ ] P2 - PowerShell App Control and language-mode preflight
  Why: The GUI and module depend on `Add-Type`, WPF/XAML, dot-sourced functions, and admin registry/service writes; App Control or Constrained Language can fail before the user gets an actionable Defender-specific error.
  Evidence: RESEARCH.md Security, Privacy, and Reliability; `DisableDefender.GUI.ps1`; `Private/Confirm-Prereqs.ps1`; Microsoft PowerShell language-mode and App Control docs.
  Touches: `Private/Confirm-Prereqs.ps1`, `DisableDefender.GUI.ps1`, `DisableDefender.ps1`, `Public/Invoke-DisableDefender.ps1`, `Public/Invoke-RemoveDefender.ps1`, `Public/Invoke-RestoreDefender.ps1`, `Tests/DisableDefender.Tests.ps1`, `README.md`.
  Acceptance: CLI and GUI report FullLanguage/ConstrainedLanguage/App Control status before destructive phases; unsupported language modes fail with signed/offline remediation guidance; tests cover FullLanguage, ConstrainedLanguage, and unknown policy states.
  Complexity: M
