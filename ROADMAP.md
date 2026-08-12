# DisableDefender Roadmap

Actionable work only. Historical and completed roadmap material is archived in CHANGELOG.md; blocked work is kept in Roadmap_Blocked.md.

## Actionable Items

- [ ] Toast and system tray notification on run completion with exit-code color.

- [ ] Track new Windows 26H1/26H2 Defender surfaces as Microsoft ships them.
  Research cross-reference (2026-07-29): publish an edition/build/architecture support matrix with an absolute last-validated date; distinguish Windows 10 consumer EOS, LTSC 2019, Windows 11 24H2/25H2, and new-device-only 26H1; keep README, changelog, and local VM coverage aligned.

- [ ] ETW subscription for `Microsoft-Windows-Windows Defender` during run to surface silent Defender reactions.

- [ ] Fleet mode (`-ComputerName`) via WinRM with explicit opt-in for batch status collection.

- [ ] ADMX template that disables Defender via GPO for shops that prefer GPO-first.

- [ ] Integration hook with DefenderShield so the DisableDefender undo manifest wins.

- [ ] "Disable everything except cloud sample submission" preset for users who want cloud reputation lookups but no local scanning.

- [ ] P1 — Add a local disposable-VM and fault-injection acceptance matrix
  Why: Mocks cannot prove reboot, Safe Mode, DISM, offline hive, service/task, update-drift, Firewall, x64, or ARM64 recovery invariants.
  Evidence: 2026-07-29 Pester coverage, Microsoft Windows lifecycle/release-health pages, competitor recovery issues, repository local-only testing rule.
  Touches: local test tooling, VM fixtures/snapshots, recovery evidence, release checklist.
  Acceptance: Disposable images cover Windows 10 LTSC 2019 and supported Windows 11 releases/architectures available to maintainers with PowerShell 5.1 and 7; each destructive phase has pre/effect/restore assertions, Firewall invariants, injected interruption points, and retained machine-readable evidence; no hosted CI or signing is introduced.
  Complexity: XL

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
