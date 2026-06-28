# Research - DisableDefender

## Executive Summary
DisableDefender is a PowerShell 5.1+ module, CLI launcher, and WPF GUI for disabling, removing, restoring, and health-checking Microsoft Defender Antivirus on Windows 10/11 while explicitly preserving Windows Firewall. Verified current shape: v0.0.18 has clean module boundaries, phase-state tracking, replay restore manifests, health drift checks, component inventory, remoting/domain tripwires, and a capable dark WPF GUI. Highest-value direction is trust and recoverability before more removal breadth. Top opportunities in priority order: 1. stop GUI destructive actions from always passing `-Force`, 2. make firewall preflight fail closed before destructive phases, 3. add post-Restore verification and repair guidance, 4. validate restore manifest schema/integrity and repeated-run restore selection, 5. make MpPreference restore/health parity data-driven, 6. verify SYSTEM-task fallback results, 7. add WinRE/offline servicing for protected live systems, 8. detect Windows feature-update drift and new Defender surfaces, 9. add runtime directory ACL/reparse preflight, 10. improve signing/App Control readiness, release checks, GUI accessibility, and support bundle export.

## Product Map
- Core workflows: Disable, Remove, Restore, Status/Health, GUI-assisted destructive execution with live log, policy edit stream, component grid, and firewall banner.
- User personas: lab/workstation admins, PACS/DICOM and dedicated-purpose machine operators, VM hosts, power users, security researchers; managed enterprise endpoints only with explicit override and recovery planning.
- Platforms and distribution: Windows 10 1809+ and Windows 11; PowerShell 5.1+; local zip artifact; no GitHub Actions/Dependabot/Renovate by repo policy; signed release and package channels remain unresolved.
- Key integrations and data flows: HKLM policy/service/SafeBoot registry writes, `Set-MpPreference`/`Get-MpComputerStatus`, scheduled-task SYSTEM fallback, DISM/Appx SecHealthUI removal, Windows Firewall profile/service guard, `%ProgramData%\DisableDefender` logs/manifests/tripwires/ACL backups.

## Competitive Landscape
- ionuttbara/windows-defender-remover
  - Does well: broad removal surface, active Windows-version issue signal, frequent user reports after feature updates.
  - Learn: feature upgrades, WinRE/Safe Mode paths, reversal scripts, and post-update reapply plans must be first-class.
  - Avoid: collateral damage reports around firewall, Wi-Fi, UWP/Store, boot loops, broken Security UI, and broad security-mitigation removal.
- undergroundwires/privacy.sexy
  - Does well: large script catalog, reversible operations, security review culture, and documented difficulty disabling Defender services under normal admin rights.
  - Learn: Defender policy values should live in one catalog with rationale, reversibility, generated tests, and narrow import/export boundaries.
  - Avoid: broad privacy-suite expansion beyond Defender AV/MAPS/sample-submission choices.
- es3n1n/defendnot
  - Does well: exposes Windows Security Center provider behavior and Smart App Control/reputation friction that registry-only tools miss.
  - Learn: WSC provider state, SAC blocking, and signed release expectations affect user trust and installability.
  - Avoid: fake-AV registration as a core strategy and binary injection/loader paths that Microsoft classifies as malware.
- Sordum Defender Control
  - Does well: simple portable UI with obvious enable/disable/status affordances and public repair guidance.
  - Learn: one-click repair and exact recovery status matter as much as disable success.
  - Avoid: closed-source opacity and weak forensic detail for failed enable/restore cases.
- O&O ShutUp10++
  - Does well: portable distribution, recommendation tiers, clear labels, and import/export of settings.
  - Learn: exportable presets should be narrow, explicit, reversible, and understandable.
  - Avoid: mixing Windows privacy, update, and AV disablement into one undifferentiated workflow.
- NTLite
  - Does well: offline image/component servicing where live Tamper Protection and WdFilter cannot interfere.
  - Learn: WinRE/offline servicing is the right advanced path for protected live systems.
  - Avoid: removing Security Center dependencies without compatibility checks and restore-source guidance.
- ConfigureDefender / DefenderUI / Hard_Configurator
  - Does well: profile-based status language, visible settings, and reboot-aware changes for Defender and Windows security controls.
  - Learn: profile/status clarity and WSC-aware health output help users understand what state they are actually in.
  - Avoid: ambiguous "permanent disable" claims without build-specific health checks.

## Security, Privacy, and Reliability
- Verified P0: `DisableDefender.GUI.ps1:1203` and `DisableDefender.GUI.ps1:1204` always pass `-Force` for Disable/Remove, so the recommended GUI bypasses Tamper Protection, managed-device, and Safe Mode gates by default instead of making override intent explicit.
- Verified P0: `Private/Test-FirewallIntact.ps1:20` only throws for `Stage -eq 'post' -and -not $script:ForceMode`; preflight and per-phase `before:*` firewall failures only warn, contradicting the README guarantee that firewall issues abort operations.
- Verified P1: `Private/Set-MpRuntimePrefs.ps1` sets `SignatureDisableUpdateOnStartupWithoutEngine`, `SignatureScheduleDay`, `ScanScheduleDay`, `EnableControlledFolderAccess`, `EnableNetworkProtection`, `CloudBlockLevel`, and exclusion extensions, but `Clear-MpRuntimePrefs` and `Get-DefenderHealth` only restore/check a subset.
- Verified P1: `Private/Invoke-AsSystem.ps1` returns `$true` after starting the transient task without checking final `LastTaskResult`; `Private/SafeBoot.ps1` uses that fallback without verifying the SafeBoot keys were actually removed.
- Verified P1: `Private/ReplayManifest.ps1` archives an existing restore manifest when a new Disable/Remove run starts, but Restore only replays the active manifest; repeat runs can make the oldest undo data less discoverable.
- Verified risk: `%ProgramData%\DisableDefender` receives privileged logs, transcripts, restore manifests, phase state, tripwires, and ACL backups; `DisableDefender.psm1` and `DisableDefender.ps1` harden ACLs only when creating the directory and do not reject a pre-existing reparse point, junction, symlink, or weak DACL.
- Verified risk: `DisableDefender.GUI.ps1` uses `Add-Type`, WPF assemblies, dynamic XAML, and custom P/Invoke while `Private/Confirm-Prereqs.ps1` does not report PowerShell language mode or App Control/WDAC state.
- Verified risk: `Private/SecHealthUI.ps1` restore depends on a local WindowsApps manifest or generic DISM advice; air-gapped/LTSC/WSUS-only recovery lacks tested component-source discovery.
- Missing guardrails: signed release packaging for Smart App Control, explicit GUI force override, pre-destructive firewall aborts, WSC provider health, restore success criteria, component-source preflight, local release gate, coverage thresholds, VM/integration harness.
- Recovery needs: post-Restore health gate, repeated-run manifest selection, SecHealthUI repair-source discovery, exportable support bundle, offline undo/reg import flow, and clear "no active AV provider" warning after Disable when no third-party AV is registered.

## Architecture Assessment
- Module boundaries are solid: `DisableDefender.psm1` dot-sources `Private/` helpers and exports public commands from `Public/`.
- Refactor candidate: split `DisableDefender.GUI.ps1` into GUI state, XAML/resources, status adapters, and event classifiers; the current 1,366-line single-file surface makes UI, accessibility, and App Control failures harder to isolate.
- Refactor candidate: promote policy and MpPreference definitions from `Public/Get-DefenderHealth.ps1`, `Private/Set-DefenderPolicy.ps1`, and `Private/Set-MpRuntimePrefs.ps1` into one in-module catalog so writes, restore defaults, health expectations, README tables, and tests cannot drift.
- Refactor candidate: centralize runtime directory creation/validation instead of duplicating `%ProgramData%\DisableDefender` ACL setup in `DisableDefender.psm1` and `DisableDefender.ps1`.
- Refactor candidate: extend `Confirm-Prereqs.ps1` into a full execution-environment preflight covering language mode, App Control/WDAC indicators, elevation, remoting, managed-device state, Tamper Protection, firewall, WSC provider state, and Safe Mode suitability.
- Test gaps: no assertion that GUI does not silently force overrides; no firewall preflight fail-closed tests; no MpPreference write/restore parity test; no SYSTEM-task result failure test; no Pester coverage report; no disposable VM/integration harness.
- Documentation gaps: README still has a screenshot placeholder line; no signed install/Smart App Control note; no compatibility matrix by Windows build; no support-bundle instructions; no language-mode/App Control troubleshooting note; no repeated-run restore manifest behavior note.

## Rejected Ideas
| Idea | Source | Reason |
|---|---|---|
| WSC fake-AV registration as the main disable method | es3n1n/defendnot | Contradicts PowerShell-native/no-binary philosophy and carries malware-classification/reputation risk. |
| BYOVD/kernel driver disable path | AlteredSecurity, MITRE T1562.001 | Security-risk technique associated with defense evasion; not appropriate for a legitimate workstation tool. |
| Disable Windows Firewall/UAC/mitigations bundle | windows-defender-remover issues, privacy.sexy issue #402 | Directly contradicts the project's firewall-preservation differentiator. |
| Broad privacy-suite expansion | privacy.sexy, O&O ShutUp10++ | Would dilute the single-purpose Defender AV workflow; only Defender-adjacent telemetry presets fit. |
| Mobile or cross-platform support | Microsoft Defender product breadth | Project targets Windows Defender AV internals; mobile Defender is a different product surface. |
| Plugin ecosystem | privacy.sexy script-import pressure | A plugin model would invite broad tweak scope; keep extension surface to narrow presets/reports. |
| Multi-user/cloud management service | MDE/Intune category | Existing optional fleet status is enough; a central management service would duplicate enterprise tools and add liability. |
| Silent Tamper Protection bypass | Microsoft tamper-protection docs, AlteredSecurity research | Live Tamper Protection is intentionally protected; recommend manual, managed, Safe Mode, or offline paths instead. |

## Sources
### Project
- https://github.com/SysAdminDoc/DisableDefender

### OSS competitors and adjacent tools
- https://github.com/ionuttbara/windows-defender-remover
- https://github.com/ionuttbara/windows-defender-remover/issues/263
- https://github.com/ionuttbara/windows-defender-remover/issues/270
- https://github.com/ionuttbara/windows-defender-remover/issues/271
- https://github.com/ionuttbara/windows-defender-remover/issues/281
- https://github.com/undergroundwires/privacy.sexy
- https://github.com/undergroundwires/privacy.sexy/issues/104
- https://github.com/undergroundwires/privacy.sexy/issues/402
- https://github.com/es3n1n/defendnot
- https://github.com/AndyFul/ConfigureDefender
- https://github.com/AndyFul/Hard_Configurator

### Commercial and community
- https://www.sordum.org/9480/defender-control-v2-1/
- https://www.sordum.org/wp-content/uploads/2023/06/Repair_defender.html
- https://www.oo-software.com/en/shutup10
- https://ntlite.com/community/threads/windows-defender-question.5408/
- https://ntlite.com/community/threads/difficult-to-disable-windows-defender-online.5551/
- https://learn.microsoft.com/en-us/answers/questions/5864088/windows-defender-damaged-by-defender-control-it-ad

### Microsoft and platform APIs
- https://learn.microsoft.com/en-us/defender-endpoint/microsoft-defender-antivirus-windows
- https://learn.microsoft.com/en-us/defender-endpoint/manage-tamper-protection-individual-device
- https://learn.microsoft.com/en-us/defender-endpoint/microsoft-defender-core-service-overview
- https://learn.microsoft.com/en-us/powershell/module/defender/set-mppreference
- https://learn.microsoft.com/en-us/windows/client-management/mdm/defender-csp
- https://learn.microsoft.com/en-us/windows/win32/api/wscapi/
- https://learn.microsoft.com/en-us/windows/win32/fileio/reparse-points
- https://learn.microsoft.com/en-us/windows/apps/develop/smart-app-control/code-signing-for-smart-app-control
- https://learn.microsoft.com/en-us/powershell/scripting/security/app-control/how-app-control-works

### Security and toolchain
- https://d3fend.mitre.org/offensive-technique/attack/T1562.001/
- https://www.alteredsecurity.com/post/disabling-tamper-protection-and-other-defender-mde-components
- https://pester.dev/docs/usage/code-coverage

## Open Questions
- Needs live validation: which Windows 26H1/26H2 Insider builds and SKUs should be part of the compatibility matrix before adding hard-coded service/package expectations?
- Needs human judgment: whether distribution should optimize for PSGallery module install, signed zip release, Winget, or all three once credentials/certificates exist.
