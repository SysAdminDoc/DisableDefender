# DisableDefender Roadmap

Actionable work beyond v0.0.18. Completed work is removed. True blockers live in `Roadmap_Blocked.md`.

## P2 - GUI

- Toast and system tray notification on run completion with exit-code color.

## P2 - CLI And Coverage

- Track new Windows 26H1/26H2 Defender surfaces as Microsoft ships them.

## P3 - Diagnostics

- ETW subscription for `Microsoft-Windows-Windows Defender` during run to surface silent Defender reactions.

## P3 - Optional Tools

- Fleet mode (`-ComputerName`) via WinRM with explicit opt-in for batch status collection.
- ADMX template that disables Defender via GPO for shops that prefer GPO-first.
- Integration hook with DefenderShield so the DisableDefender undo manifest wins.
- "Disable everything except cloud sample submission" preset for users who want cloud reputation lookups but no local scanning.

## Research-Driven Additions


- [ ] P2 - GUI accessibility and screenshot verification pass
  Why: The WPF GUI is now the primary recommended path, but README still has a screenshot placeholder and there is no UI Automation/accessibility evidence.
  Evidence: RESEARCH.md Architecture Assessment; `DisableDefender.GUI.ps1`; `README.md` screenshot placeholder.
  Touches: `DisableDefender.GUI.ps1`, `README.md`, local screenshot capture workflow.
  Acceptance: All actionable controls have accessible names/tooltips, text does not clip at supported window sizes, README screenshot is recaptured from v0.0.18+ GUI, and a local GUI parse/screenshot check is documented.
  Complexity: M



## Audit Findings (2026-06-30)

- [ ] P2 - GUI Write-Log override missing JSONL output
  Why: When running via GUI, no JSONL entries are written because the GUI overrides Write-Log without the JSONL block.
  Where: `DisableDefender.GUI.ps1` lines 83-93.

- [ ] P2 - GUI system tray notification on run completion with exit-code color
  Why: The GUI already has in-app toasts but lacks OS-level notification for background-aware completion.
  Where: `DisableDefender.GUI.ps1`.

- [ ] P2 - GUI accessibility: AutomationProperties.Name on tiles/buttons, maximize button, status text distinction for colorblind users
  Why: No screen reader labels, no maximize/restore button, color-only state indicators fail WCAG.
  Where: `DisableDefender.GUI.ps1` XAML section.

- [ ] P2 - GUI version hardcoded in XAML and file header (v0.0.23 stale)
  Why: XAML default Text="v0.0.23" shows during initial render; header comment also stale.
  Where: `DisableDefender.GUI.ps1` lines 3 and 318.

- [ ] P2 - CLI JSON success envelope for Disable/Remove/Restore
  Why: With -Json, successful operations emit raw status output with no Ok=true wrapper; error path has envelope. Automation cannot parse both consistently.
  Where: `DisableDefender.ps1` Invoke-SelectedMode.

- [ ] P2 - Invoke-AsSystem still uses cmd.exe despite CHANGELOG v0.0.5 claiming removal
  Why: Output redirection requires cmd.exe wrapper; CHANGELOG is inaccurate. Low practical risk but misleading documentation.
  Where: `Private/Invoke-AsSystem.ps1` line 18-19; `CHANGELOG.md` v0.0.5 Security section.

- [ ] P2 - ACL backup uses Import-Clixml (deserialization of untrusted .NET types)
  Why: If an attacker writes to the hardened runtime directory (race between creation and ACL application), CLIXML allows arbitrary type instantiation at SYSTEM privilege.
  Where: `Private/Grant-RegKeyControl.ps1` line 80.

- [ ] P3 - Export-DefenderSupportBundle hardcodes health target to Disable
  Why: After a Remove operation, health shows misleading drift for Remove-only items.
  Where: `Public/Export-DefenderSupportBundle.ps1` line 61.

- [ ] P3 - Offline bundle generated script: release RegistryKey handles before Dismount
  Why: PowerShell may hold .NET handles from Get-ItemProperty; hive unload can fail with "access denied."
  Where: `Public/New-OfflineRemoveBundle.ps1` generated script, Dismount-OfflineHives.

- [ ] P3 - GUI timer/runspace cleanup on window close (EndInvoke not called)
  Why: Worker AsyncResult without EndInvoke leaks the runspace; exceptions silently swallowed.
  Where: `DisableDefender.GUI.ps1` window Closed handler.

- [ ] P3 - Portable preset export/import for Defender-adjacent preferences
  Why: O&O ShutUp10++ and privacy tools show value in portable, explainable presets; this project should keep it narrow to Defender AV/MAPS/sample-submission choices.
  Evidence: RESEARCH.md Competitive Landscape; O&O ShutUp10++ import/export behavior; existing ROADMAP cloud sample submission preset.
  Touches: `Public/Get-DefenderHealth.ps1`, `Private/Set-MpRuntimePrefs.ps1`, `DisableDefender.GUI.ps1`, `README.md`.
  Acceptance: Users can export/import a small JSON preset for supported Defender-adjacent choices; unsupported broad privacy tweaks are rejected with a clear message.
  Complexity: M


