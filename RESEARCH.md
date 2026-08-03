# Research — DisableDefender

Date: 2026-07-29 — replaces all prior research.

## Executive Summary

DisableDefender v0.0.40 is a Windows-only PowerShell module, CLI, and WPF GUI for local, reversible Microsoft Defender disable/remove/restore workflows while explicitly preserving Windows Firewall and, by default, Microsoft Defender for Endpoint. Its strongest shape observed on 2026-07-29 is its narrow scope, portable unsigned distribution, manifest/phase-state artifacts, health/diff/report tooling, and live/Safe Mode/offline recovery paths. The highest-value direction is not another removal technique: it is making every privileged transition transactional, effect-verified, baseline-aware, and recoverable. The top opportunities, in order, are:

1. Return structured action results and prove target postconditions before a phase can succeed.
2. Restore the exact recorded baseline instead of replaying it and then overwriting it with fixed defaults.
3. Move safety gates outside the `-Only`-filterable plan and remove implicit `-Force` from generated workflows.
4. Fail closed when `mpssvc` or `BFE` is missing, disabled, or stopped.
5. Turn Safe Mode entry/removal/return into a durable, queryable cross-boot transaction.
6. Harden release cleanup and restore-artifact replay as privileged trust boundaries.
7. Version and migrate all persisted artifacts, then test previous/supported/future schemas with golden fixtures.
8. Make clean-checkout packaging, PowerShell 5.1/7 compatibility, and disposable-VM recovery tests release gates.

## Product Map

- Core workflows: inspect Status/Health; capture snapshots and diffs; Disable reversibly; Remove live, in Safe Mode, or through an offline bundle; Restore from the active or selected manifest; export reports and support bundles.
- User personas: lab and malware-analysis operator; break/fix administrator; dedicated-device owner; workstation user who accepts reduced AV protection but requires Firewall preservation and an undo path.
- Platforms and distribution: the README on 2026-07-29 claims Windows 10 1809+, Windows 11, and PowerShell 5.1/7; local module/CLI plus WPF GUI; portable unsigned ZIP; no hosted service or remote control plane.
- Integrations and data flow: CLI/GUI → `Private/PhaseRunner.ps1` → registry, Defender cmdlets, services, scheduled tasks, Appx/DISM, SafeBoot, and Security Health mutators → `%ProgramData%\DisableDefender` manifests, phase state, snapshots, ACL backups, tripwire, JSONL logs, reports, and support bundles → `Public/Get-DefenderHealth.ps1`.

## Competitive Landscape

- **O&O ShutUp10++** — Does profiles, add-only versus replace-all import, restore points, undo, localization, accessibility, and update-driven reapplication well. Learn its explicit profile semantics and refusal to apply when recovery-point creation fails. Avoid its broad privacy surface and invisible continuous reapplication.
- **privacy.sexy** — Does explainable catalogs, generated scripts, and reversible privacy operations well; its issue history also documents painful incomplete reverts. Learn its per-action explanation and verification discipline. Avoid arbitrary imported scripts in a SYSTEM-capable action model.
- **NTLite** — Does dependency-aware offline servicing, compatibility guards, and Host Refresh recovery well. Learn its separation of removal, dependency analysis, and repair. Avoid making image rebuilding the normal local workflow.
- **pgkt04/defender-control and Sordum Defender Control** — Do narrow status/disable/enable interactions and recovery guidance well. Learn the value of a visible live state and explicit repair path. Avoid TrustedInstaller/token tricks and undocumented binary-only behavior.
- **windows-defender-remover** — Covers aggressive removal, ISO workflows, and feature-update breakage extensively; issues repeatedly ask how to reverse half-removed states. Learn from its real-world recovery failures and offline demand. Avoid collateral removal of unrelated Windows security features.
- **ConfigureDefender and Harden Windows Security** — Do named profiles, export/import, golden-state baselines, and policy explanations well. Learn their data-driven settings and portable baseline model. Avoid expanding into a general Windows hardening suite.
- **WinUtil** — Does grouped operator workflows and diagnostics well; its issue tracker contains concrete examples of PowerShell 7 Appx failures being reported as GUI success and proposals for privacy-allowlisted support data. Learn its operator-facing repair context. Avoid its unrelated tweak/catalog breadth.
- **defendnot** — Demonstrates a narrow Windows Security Center registration path and robust autorun cleanup. Learn only from its lifecycle hygiene. Avoid undocumented WSC impersonation, detection-sensitive binaries, and unsupported Server behavior.

## Security, Privacy, and Reliability

- **Verified — baseline replay is not baseline restoration.** `Public/Invoke-RestoreDefender.ps1` invokes manifest replay and then deterministic cleanup. That cleanup deletes recorded policy trees, resets MpPreferences to fixed defaults, enables tasks, hard-codes service states, recreates a fixed context-menu tree, and ignores recorded Security Health data (`Private/Set-DefenderPolicy.ps1`, `Private/Set-MpRuntimePrefs.ps1`, `Private/Disable-DefenderTasks.ps1`, `Private/Set-ServiceStart.ps1`, `Private/ContextMenu.ps1`, `Private/SecHealthUI.ps1`). `Public/Get-DefenderHealth.ps1` validates those defaults rather than the selected baseline.
- **Verified — `-Only` can exclude mandatory safeguards.** `Private/PhaseRunner.ps1` filters any unmatched phase, so Remove can select `DISM` while excluding prerequisites, Tamper Protection, managed-device, Safe Mode, domain, and Firewall checks. `Public/New-OfflineRemoveBundle.ps1` emits `-Skip Prerequisites` and an implicit `-Force`, turning an internal filter into a safety bypass.
- **Verified — a phase can log success without changing its target.** Defender preference, task, service, Security Health, DISM, and context-menu helpers catch or ignore action failures (`Private/Set-MpRuntimePrefs.ps1`, `Private/Disable-DefenderTasks.ps1`, `Private/Set-ServiceStart.ps1`, `Private/SecHealthUI.ps1`, `Private/Remove-DefenderPlatformPackages.ps1`, `Private/ContextMenu.ps1`). Disable/Remove then save a baseline after the plan completes, even when individual effects were not proven (`Public/Invoke-DisableDefender.ps1`, `Public/Invoke-RemoveDefender.ps1`).
- **Verified — Firewall integrity is under-checked.** `Private/Test-FirewallIntact.ps1` skips missing services, checks only whether start type is `Disabled`, and never requires `mpssvc` and `BFE` to be running. The GUI has a divergent copy in `DisableDefender.GUI.ps1`. Microsoft documents stopping the Windows Defender Firewall service as unsupported.
- **Verified — Safe Mode bootstrap can strand the machine.** `Private/SafeBoot.ps1` suppresses task-registration failures; `Public/Invoke-SafeModeRemove.ps1` can still set BCD and request reboot without querying both tasks, proving the watchdog independently, checking child PowerShell exit codes, or persisting the cross-boot stage. The generated remove task cleans up and reboots after an unverified child run.
- **Verified — the release builder's cleanup guard is prefix-based.** `tools/New-DisableDefenderRelease.ps1` accepts the repository root and prefix-sharing sibling paths as output destinations before recursive deletion. It needs separator-aware strict containment, root equality refusal, reparse-point rejection, and a second identity check immediately before deletion.
- **Verified — restore artifacts are insufficiently constrained for SYSTEM replay.** `Private/ReplayManifest.ps1` checks basic fields but not one RunId, contiguous unique sequence, bounded size/depth, or allowlisted action/registry/service/task/MpPreference targets. A failed registry read is recorded as remove-on-restore. File owner, ACL, reparse status, and identity are not revalidated immediately before mutation.
- **Verified — ACL recovery is not crash-consistent.** `Private/Grant-RegKeyControl.ps1` changes owners before durably persisting the complete backup, overwrites one backup across runs, and can delete it after partial recovery. The risk is transactional loss and overly broad replay, not arbitrary CLIXML type instantiation.
- **Verified — offline and support-bundle cleanup are fragile.** `Public/New-OfflineRemoveBundle.ps1` can miss hive unload when mounting fails between hives and can exit successfully after unload failure; it produces no machine-readable undo artifact. `Public/Export-DefenderSupportBundle.ps1` uses second-resolution staging, recursively removes the path, hard-codes a Disable health target, and copies raw logs/transcripts/tripwire/domain data without an allowlist preview.
- **Verified — PowerShell 7 compatibility is broken in the 2026-07-29 checkout.** Import under PowerShell 7.6.3 fails because `Private/RuntimeDirectory.ps1` calls `DirectoryInfo.GetAccessControl()`, while Windows PowerShell 5.1 imports and the Pester suite passes. The README's PowerShell 7 claim must be made true or narrowed.
- **Verified — runtime patching remains a host prerequisite.** The repository vendors no PowerShell runtime; PowerShell Announcement 77 reports CVE-2025-30399 as fixed in 7.4.11/7.5.2. Release evidence should record patched Windows and PowerShell host versions rather than bundle a runtime.
- **Needs live validation — reboot and OS-servicing invariants.** Safe Mode return, exact service/task restoration, LTSC Appx removal, 26H1 behavior, ARM64, DISM package removal, and offline hive recovery require disposable Windows images; mocks cannot prove them.

## Architecture Assessment

- Introduce one internal operation-result contract—attempted, changed, verified, evidence, errors—and make `Private/PhaseRunner.ps1`, CLI JSON, GUI status, logs, and health consume it. Native exit codes and target postconditions must be first-class, not inferred from log text.
- Make the selected baseline an immutable transaction input. Split exact replay from a clearly labeled no-manifest repair preset; keep a failed or partial manifest active; make Health compare against the selected baseline.
- Define one data catalog for phases, safety classification, service/task/package targets, restore validators, and health probes. This removes the GUI/CLI Firewall duplication and LTSC Appx removal/health mismatch observed on 2026-07-29.
- Version manifests, phase state, baselines, snapshots, ACL backups, logs, and support bundles independently. Add atomic reader migrations and golden fixtures; reject unknown future schemas before mutation.
- Keep module import, help, Status, and other read-only paths side-effect free. Protected runtime-directory creation and ACL repair belong at the first mutating operation, with explicit preflight results.
- **Verified test gap:** Windows PowerShell 5.1 with Pester 5.8 passes 94 tests, but command coverage is 1,910/2,945 statements (64.9%). Critical mutators including Security Health, Safe Mode Remove, Disable/Remove orchestration, policy/tasks/context-menu, and platform-package removal have no direct coverage.
- **Verified release gap:** the local release check accepts any stale ZIP, warns instead of failing when Pester/PSScriptAnalyzer is unavailable, has no ratcheted coverage threshold, and depends on an untracked `tools/New-DisableDefenderRelease.ps1`. A clean checkout therefore cannot reproduce the documented release.
- **Verified GUI gap:** the XAML parses, but its 64 named elements and 12 buttons define no `AutomationProperties`, access keys, explicit tab order, default/cancel semantics, high-contrast resources, or localization resources. At the declared 1000×640 minimum, the live-log region can collapse; small overlay text is below WCAG 2.2 contrast. The close path stops an active pipeline abruptly and does not consistently call `EndInvoke`.
- Align documentation with the actual lifecycle: Windows 10 Home/Pro 22H2 support ended on 2025-10-14; LTSC 2019 remains a separate target; Windows 11 26H1 is for selected new devices rather than an in-place upgrade. Record an absolute last-validated date per build/edition/architecture.

## Rejected Ideas

- **General privacy/debloat/hardening suite** — Rejected despite privacy.sexy, WinUtil, xd-AntiSpy, and Harden Windows Security; it contradicts the repository's Defender-only boundary and multiplies recovery states.
- **Undocumented WSC impersonation or stealth AV registration** — Rejected despite defendnot; it is detection-sensitive, relies on undocumented behavior, and does not provide a truthful Defender recovery model.
- **TrustedInstaller/token theft, driver renaming, or broad security-component deletion** — Rejected despite Sordum and aggressive removers; the maintenance and rollback risk conflicts with the reversible/Firewall-safe promise.
- **Background automatic reapplication after every Windows update** — Rejected as a default despite O&O's commercial feature; silently weakening protection is inappropriate. Keep drift detection and explicit reapply plans.
- **Arbitrary plugins or imported scripts** — Rejected despite catalog extensibility elsewhere; privileged action plugins expand the trusted code base and make restore validation unbounded. A versioned allowlisted data catalog is sufficient.
- **Remote mutation, SaaS, multi-user collaboration, or mobile clients** — Rejected; the product is a local Windows recovery tool. Existing opt-in fleet Status collection should remain read-only.
- **Broad cloud telemetry** — Rejected; diagnostics should remain local, previewable, redacted, and user-exported.
- **Code-signing acquisition** — Rejected by the governing no-signing rule. Release work must build, hash, and verify an unsigned artifact without treating a certificate as a gate.

## Sources

### Direct OSS and issue signal

- https://github.com/es3n1n/defendnot
- https://github.com/es3n1n/defendnot/releases/tag/v1.5.0
- https://github.com/pgkt04/defender-control
- https://github.com/pgkt04/defender-control/issues/36
- https://github.com/ionuttbara/windows-defender-remover
- https://github.com/ionuttbara/windows-defender-remover/issues/249
- https://github.com/ionuttbara/windows-defender-remover/issues/271
- https://github.com/ionuttbara/windows-defender-remover/issues/276
- https://github.com/AndyFul/ConfigureDefender
- https://github.com/AndyFul/ConfigureDefender/issues/14
- https://github.com/undergroundwires/privacy.sexy
- https://github.com/undergroundwires/privacy.sexy/releases/tag/0.13.8
- https://github.com/undergroundwires/privacy.sexy/issues/418
- https://github.com/undergroundwires/privacy.sexy/issues/619
- https://github.com/ChrisTitusTech/winutil/issues/4821
- https://github.com/ChrisTitusTech/winutil/issues/4882
- https://github.com/HotCakeX/Harden-Windows-Security/issues/1008
- https://github.com/HotCakeX/Harden-Windows-Security/issues/1010
- https://github.com/HotCakeX/Harden-Windows-Security/releases/tag/HardenSystemSecurity-v1.0.75.0
- https://github.com/builtbybel/xd-AntiSpy

### Commercial and adjacent products

- https://manuals.oo-software.com/ooshutup10/docs/common-features/profiles-and-export/
- https://manuals.oo-software.com/ooshutup10/docs/introduction/feature-comparison/
- https://www.oo-software.com/en/shutup10/changelog
- https://ntlite.com/features/
- https://ntlite.com/docs/guides/host-refresh/
- https://www.sordum.org/9480/defender-control-v2-1/comment-page-35/
- https://www.defenderui.com/
- https://wpd.app/docs/arguments/

### Platform, standards, and lifecycle

- https://learn.microsoft.com/en-us/defender-endpoint/troubleshooting-mode-scenarios
- https://learn.microsoft.com/en-us/defender-endpoint/prevent-changes-to-security-settings-with-tamper-protection
- https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/windows-firewall/
- https://learn.microsoft.com/en-us/windows/win32/taskschd/registeredtask-lasttaskresult
- https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/dism-app-package--appx-or-appxbundle--servicing-command-line-options?view=windows-11
- https://learn.microsoft.com/en-us/windows/win32/fileio/reparse-point-operations
- https://learn.microsoft.com/en-us/powershell/scripting/whats-new/differences-from-windows-powershell?view=powershell-7.6
- https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.security/get-acl?view=powershell-7.6
- https://learn.microsoft.com/en-us/dotnet/desktop/wpf/advanced/wpf-globalization-and-localization-overview
- https://learn.microsoft.com/en-us/windows/compatibility/high-contrast-mode
- https://www.w3.org/TR/WCAG22/
- https://learn.microsoft.com/en-us/lifecycle/products/windows-10-home-and-pro
- https://learn.microsoft.com/en-us/lifecycle/products/windows-10-enterprise-ltsc-2019
- https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information

### Dependencies, security, and engineering

- https://github.com/pester/Pester/releases/tag/6.0.0
- https://github.com/pester/Pester/releases/tag/5.9.0
- https://github.com/PowerShell/PSScriptAnalyzer/releases/tag/1.25.0
- https://github.com/PowerShell/Announcements/issues/77
- https://cwe.mitre.org/data/definitions/22.html
- https://cwe.mitre.org/data/definitions/59.html
- https://cwe.mitre.org/data/definitions/367.html
- https://devblogs.microsoft.com/powershell/announcing-dsc-v3/
- https://learn.microsoft.com/en-us/powershell/dsc/reference/cli/resource/set?view=dsc-3.0
- https://www.usenix.org/system/files/fast25-jiao.pdf

### Community and discovery lists

- https://news.ycombinator.com/item?id=20640372
- https://news.ycombinator.com/item?id=36685919
- https://lobste.rs/s/albewr/disable_your_antivirus_software_except
- https://stackoverflow.com/questions/77356228/powershell-script-set-mppreference-not-working-correctly
- https://www.tenforums.com/antivirus-firewalls-system-security/218177-how-to-restore-defender-after-using-defender-disabler-software.html
- https://github.com/TemporalAgent7/awesome-windows-privacy
- https://github.com/PaulSec/awesome-windows-domain-hardening
- https://github.com/decalage2/awesome-security-hardening

## Open Questions

- Which disposable Windows images are available for destructive/reboot validation: Windows 10 LTSC 2019, Windows 11 24H2/25H2/26H1, x64, and ARM64?
- Is Windows 10 consumer Extended Security Updates in scope, or should the supported consumer matrix begin at Windows 11 while retaining explicit LTSC coverage?
