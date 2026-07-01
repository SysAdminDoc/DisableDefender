# DisableDefender

[![Version](https://img.shields.io/badge/version-0.0.37-blue.svg)](https://github.com/SysAdminDoc/DisableDefender/releases)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D6.svg)](https://www.microsoft.com/windows)
[![PowerShell](https://img.shields.io/badge/powershell-5.1%2B-012456.svg)](https://learn.microsoft.com/powershell)

<img width="1168" height="754" alt="2026-04-20 14_23_00-DisableDefender" src="https://github.com/user-attachments/assets/975dd36c-e05f-461e-8a40-3b9c2b9136e9" />
<br>


**The ultimate Microsoft Defender Antivirus disabler / remover for Windows 10 and 11.**

DisableDefender fully disables (and optionally removes) Microsoft Defender Antivirus while **explicitly preserving the Windows Firewall**. Firewall services (`mpssvc`, `BFE`, `SharedAccess`) and policy keys are on a refuse-list and verified intact before and after every operation.

PowerShell-native module with **both a CLI launcher and a premium WPF GUI**. No external dependencies. Reversible. Built from a synthesis of the best community techniques (policy keys, `Set-MpPreference`, registry ACL takeover, SYSTEM-via-task fallback, DISM package removal, SecHealthUI deprovision, scheduled task nuke, SafeBoot trap).

---

## GUI

A premium WPF dark interface — Catppuccin Mocha palette, custom chrome, glassmorphic tiles, live status dashboard, embedded log, async execution.

Run via:
```powershell
.\DisableDefender.GUI.ps1
```
or double-click `DisableDefender.GUI.bat`.

Dashboard tiles show: Antivirus engine, Real-time protection, Tamper Protection (with warning banner + direct link to Windows Security), Firewall, Defender service count, MAPS telemetry, and a per-component lockdown grid for Defender services/drivers with PPL or LaunchProtected state for MsMpEng, WdFilter, WdBoot, and WdNisDrv. A live policy edit stream tags direct writes, ACL overrides, and SYSTEM-task fallback methods as they happen. The always-on firewall integrity banner polls mpssvc, BFE, and firewall profiles, then flashes red if any guard trips. Disable/Remove confirmations expose a default-off `-Force` override checkbox instead of bypassing safety gates automatically. Overall indicator summarizes to PROTECTED / DISABLED / BLOCKED. Live log pane streams every operation with level colors (INFO / OK / WARN / ERROR / DEBUG). Copy, Export, Clear buttons. Toast notifications on completion.
Disable confirmation includes a current-vs-target drift preview before execution.

![GUI placeholder — re-capture after first run per screenshots.md]

---

## Features

- **Three modes**: `Disable` (reversible), `Remove` (aggressive), `Restore` (undo)
- **Firewall preservation** with critical (`mpssvc`, `BFE`) vs touch-refuse separation; pre/post integrity guard aborts if profile flips off
- **Registry ACL takeover** via `SeTakeOwnershipPrivilege` + `Microsoft.Win32.Registry` — no TrustedInstaller needed (TI triggers Defender alarms per privacy.sexy #264)
- **SYSTEM-via-task fallback** for keys that even Admin+ACL-override can't touch, with task result/output logging
- **Multi-strategy `Set-ServiceStart`**: direct write → ACL takeover → SYSTEM task, with target-state verification after every strategy
- **Full policy coverage** (privacy.sexy-enriched): `DisableAntiSpyware`, real-time, behavior, IOAV, IPS, IPC, spynet, MAPS, NIS, IPS-throttle, MpEngine PUA + file-hash, signatures, scan, SmartScreen, MRT, passive-mode for MDE, UX suppression, legacy `Microsoft Antimalware`
- **Runtime prefs**: cataloged `Set-MpPreference` sweep with restore defaults, health expectations, and global path/extension exclusions
- **Scheduled tasks**: all four Defender tasks + ExploitGuard refresh disabled
- **Service takedown**: 16 Defender services by default, including `MDCoreSvc`, `MDDlpSvc`, `MsSecFlt`, `MsSecCore`, `SgrmAgent`/`Broker`, `webthreatdefsvc`; MDE `Sense` requires explicit `-IncludeMDE`
- **Appx removal**: SecHealthUI deprovision with `NonRemovableAppPolicy` override
- **SafeBoot trap** (Remove mode): nukes `SafeBoot\{Minimal,Network}\WinDefend` so the service can't load even in Safe Mode
- **Restore point** before any destructive op (opt-out with `-NoRestorePoint`)
- **Runtime directory preflight**: `%ProgramData%\DisableDefender` refuses junctions/symlinks and repairs weak ACLs before writing logs, manifests, phase state, tripwires, ACL backups, or SYSTEM task output
- **Replay restore manifest**: Disable/Remove record validated JSONL undo entries; Restore logs run IDs, entry count, and SHA256 before reverse-order replay, detects archived undo chains, and can replay newest or all manifests deterministically
- **Atomic phase boundaries**: each mode records phase status to `phase-state.json`; failures log partial state plus resume/rollback recovery choices
- **Per-phase firewall guard**: every executed phase checks firewall services and profiles before and after running
- **Known-bad Remove gate**: domain-joined machines are refused unless `-Force` is passed and emit JSONL tripwires
- **PSRemoting guard**: Disable/Remove/Restore refuse PSSession execution unless `-AllowRemoting` is explicit
- **Restore point throttle awareness**: Windows restore-point interval refusals are logged with the configured cadence instead of a generic warning
- **Surgical reruns**: `-Only` and `-Skip` phase filters for Policies, MpPreference, Tasks, Services, Appx, DISM, SafeBoot, and ContextMenu
- **Health mode + Restore verification**: compares current state to Disable/Remove/Restore targets and reports drift for services, policy keys, tasks, Appx, SafeBoot, and MpPreference; Restore ends with a health summary and repair commands when drift remains
- **Feature-update drift detection**: Disable/Remove record a Defender surface baseline; Health flags changed Windows builds plus unknown Defender-like services, tasks, and packages and prints a reapply plan that preserves firewall and MDE Sense by default
- **Local release builder**: creates a clean zip, SHA256 file, release metadata JSON, and optional Authenticode signatures when a code-signing certificate is supplied
- **Support bundle export**: `Export-DefenderSupportBundle` collects logs, phase-state, tripwires, component status, health summary, Windows build info, and optional redacted Defender event-log excerpts into a diagnostic zip without secrets
- **Offline remove bundle** (`PrepareOffline`): generates a self-contained `Invoke-OfflineDefenderRemove.ps1` that targets an offline Windows volume from WinRE or a secondary OS, bypassing live Tamper Protection by editing dormant registry hives directly; refuses to run against the live system root
- **Module layout**: `DisableDefender.psd1` / `DisableDefender.psm1` with public commands and private helpers for function-level tests
- **GUI auto-elevate, silent CLI mode, transcript logging, Safe Mode aware**

## Requirements

- Windows 10 (1809+) or Windows 11 (any build, including 24H2/25H2)
- PowerShell 5.1+ (PowerShell 7 works too)
- Administrator rights (GUI auto-elevates; CLI must run from an elevated PowerShell session)
- **Tamper Protection OFF** — you must toggle this manually first:
  *Settings > Windows Security > Virus & threat protection > Manage settings > Tamper Protection*
  There is no scripted bypass for Tamper Protection on 24H2+. DisableDefender detects the state and aborts if still on.

## Usage

### GUI (recommended)
```powershell
.\DisableDefender.GUI.ps1
```
Or double-click `DisableDefender.GUI.bat`. Auto-elevates to Administrator.

### Interactive CLI
```powershell
powershell -ExecutionPolicy Bypass -File .\DisableDefender.ps1
```
A menu appears with Disable / Remove / Restore / Status.

### CLI
```powershell
# Reversible disable
.\DisableDefender.ps1 -Mode Disable

# Full removal (Safe Mode recommended)
.\DisableDefender.ps1 -Mode Remove

# Undo everything
.\DisableDefender.ps1 -Mode Restore

# Undo every archived run chain after repeated Disable/Remove runs
.\DisableDefender.ps1 -Mode Restore -ManifestSelection All

# Just show state
.\DisableDefender.ps1 -Mode Status

# Health check against the Disable target
.\DisableDefender.ps1 -Mode Health

# After a Windows feature update, review drift and the reapply plan
.\DisableDefender.ps1 -Mode Health -HealthTarget Disable

# Silent automation
.\DisableDefender.ps1 -Mode Disable -Silent -NoReboot

# JSON status for automation
.\DisableDefender.ps1 -Mode Status -Json
.\DisableDefender.ps1 -Mode Health -HealthTarget Remove -Json

# Surgical reruns
.\DisableDefender.ps1 -Mode Disable -Only Policies,MpPreference
.\DisableDefender.ps1 -Mode Remove -Skip DISM,Appx -Force
```

### Module
```powershell
Import-Module .\DisableDefender.psd1
Get-DefenderStatus
Get-DefenderHealth -Target Disable
Invoke-DisableDefender -Force -NoRestorePoint
Invoke-RestoreDefender
Invoke-RestoreDefender -ManifestSelection All

# Export diagnostic bundle
Export-DefenderSupportBundle -OutputDirectory C:\Support
Export-DefenderSupportBundle -IncludeEventLog

# Generate single-file HTML report
Export-DefenderHtmlReport
Export-DefenderHtmlReport -OutputPath C:\Reports\defender.html -HealthTarget Remove
```

### Offline Remove (WinRE / secondary OS)

When Tamper Protection cannot be toggled off (e.g. managed devices, locked UI), generate a self-contained script that edits registry hives from an offline volume:

```powershell
# Generate the bundle
.\DisableDefender.ps1 -Mode PrepareOffline

# Or via the module
Import-Module .\DisableDefender.psd1
New-OfflineRemoveBundle -OutputDirectory C:\OfflineBundle
```

Copy the generated `Invoke-OfflineDefenderRemove.ps1` to a USB drive, boot into WinRE or a secondary Windows install, and run:

```powershell
.\Invoke-OfflineDefenderRemove.ps1 -TargetVolume D:\
```

The script loads the offline volume's SOFTWARE and SYSTEM registry hives, applies all Defender policy keys, disables services, removes SafeBoot entries, and disables WMI Autologger telemetry. It refuses to run against the live system drive. After booting the target, run `-Mode Health` and `-Mode Remove -Force -Only MpPreference,Tasks,Appx,DISM` to complete the remaining live-only steps.

### Parameters
| Flag | Description |
|---|---|
| `-Mode` | `Disable` / `Remove` / `Restore` / `Status` / `Health` |
| `-Silent` | No console output, no prompts. Requires `-Mode`. |
| `-NoRestorePoint` | Skip System Restore checkpoint. |
| `-NoReboot` | Don't auto-reboot at end. |
| `-Force` | Bypass Tamper Protection / managed-device / Safe Mode abort gates. GUI users must explicitly select the override checkbox. |
| `-AllowRemoting` | Allow Disable/Remove/Restore inside PSRemoting or PSSession contexts. |
| `-IncludeMDE` | Also target the MDE `Sense` service. Disabled by default to preserve enterprise EDR visibility. |
| `-Json` | Emit JSON for `Status`. |
| `-Only` | Run only matching phase keys. Common keys: `Policies`, `MpPreference`, `Tasks`, `Services`, `Appx`, `DISM`, `SafeBoot`, `ContextMenu`. |
| `-Skip` | Skip matching phase keys while running the rest of the selected mode. |
| `-ManifestSelection` | Restore manifest selection for `Restore`: `Newest` (default), `All`, or `Active`. Use `All` after repeated Disable/Remove runs when older undo chains must also be replayed. |
| `-HealthTarget` | Expected target for `-Mode Health`: `Disable`, `Remove`, or `Restore`. |
| `-LogPath` | Override log path (default `%ProgramData%\DisableDefender\DisableDefender.log`). |

## Exit codes

| Code | Meaning | Repair |
|------|---------|--------|
| 0 | Success | |
| 1 | Unknown / unclassified error | Check logs |
| 2 | Tamper Protection is ON | Toggle off in Windows Security UI |
| 3 | Safe Mode required for Remove | Boot to Safe Mode or use `-Force` |
| 4 | Firewall integrity check failed | `netsh advfirewall set allprofiles state on` |
| 5 | Managed device (Intune/MDM/MDE) | Use `-Force` (may trigger compliance violations) |
| 6 | Restore verification failed | Run `-Mode Health -HealthTarget Restore` |
| 7 | Phase filters selected nothing | Check `-Only` / `-Skip` values |
| 8 | PSRemoting session blocked | Use `-AllowRemoting` |
| 9 | Domain-joined machine (Remove) | Use `-Force` (may trigger SIEM alerts) |

With `-Json`, fatal errors emit a stable object:
```json
{
  "Ok": false,
  "Mode": "Disable",
  "ExitCode": 2,
  "ErrorCode": "TAMPER_PROTECTION",
  "Message": "Tamper Protection blocks changes.",
  "FailedPhase": "Prerequisites",
  "PhaseStatePath": "C:\\ProgramData\\DisableDefender\\phase-state.json",
  "RepairCommands": ["Toggle Tamper Protection off in Windows Security UI, then retry."],
  "Timestamp": "2026-06-30T22:00:00.0000000-04:00"
}
```

## Local release readiness check

Verify the repo before a release:
```powershell
.\tools\Test-ReleaseReadiness.ps1
.\tools\Test-ReleaseReadiness.ps1 -SkipCoverage   # faster, no coverage report
```

Checks manifest validation, module import, version consistency across all locations, Pester tests (with optional code coverage), ScriptAnalyzer (when installed), GUI parse, and release artifact presence.

## Local release build and Smart App Control

Build the distributable locally:
```powershell
.\tools\New-DisableDefenderRelease.ps1
```

Build and sign when a code-signing certificate is available:
```powershell
.\tools\New-DisableDefenderRelease.ps1 -CertificateThumbprint '<thumbprint>'
```

The builder creates `dist\DisableDefender-vX.Y.Z.zip`, a `.sha256` file, and `DisableDefender-vX.Y.Z.release.json`. Without a supplied certificate, the artifact is intentionally marked `Unsigned`.

Smart App Control can block unknown, unsigned, or low-reputation apps. See Microsoft’s [Smart App Control FAQ](https://support.microsoft.com/windows/smart-app-control-faq-285ea03d-fa88-4d56-882e-6698afdb7003). PowerShell script signatures use Authenticode; see Microsoft’s [`Set-AuthenticodeSignature`](https://learn.microsoft.com/powershell/module/microsoft.powershell.security/set-authenticodesignature) documentation. If SAC blocks the unsigned zip or launcher, extract manually, review the scripts, unblock the downloaded files if appropriate, and run from an elevated PowerShell session.

## What each mode does

### Disable (reversible)
1. Checks Tamper Protection is off
2. Verifies firewall intact
3. Creates System Restore point
4. Writes Defender policy keys (anti-spyware, real-time, behavior, IPS, spynet, passive-mode, SmartScreen, MRT)
5. Applies `Set-MpPreference` sweep + global exclusions
6. Disables 5 scheduled tasks
7. Stops + disables Defender services (NOT firewall; MDE `Sense` only with `-IncludeMDE`)
8. Re-verifies firewall intact
9. Prompts reboot

### Remove (aggressive)
Everything Disable does, plus:
- Deprovisions the `Microsoft.SecHealthUI` Appx package (with `NonRemovableAppPolicy` override)
- DISM-removes `Windows-Defender` / `SecurityClient` platform packages
- **Best run from Safe Mode** for service registry key edits to stick

### Restore (undo)
- Validates and replays the newest non-empty `%ProgramData%\DisableDefender\restore-manifest*.jsonl` in reverse order, with run ID / entry count / SHA256 integrity logging
- Warns when older archived undo chains exist; use `-ManifestSelection All` to replay active and archived manifests newest-first
- Removes all Defender policy keys
- Resets `MpPreference` flags to default
- Re-enables scheduled tasks
- Restores default service start types
- Restores backed-up registry ACLs when ACL takeover was used
- Re-registers SecHealthUI from `%ProgramFiles%\WindowsApps`
- Verifies Restore target health and logs exact repair commands for remaining drift; silent CLI exits non-zero when verification fails
- If the Security app does not come back: `sfc /scannow` then `DISM /Online /Cleanup-Image /RestoreHealth`

## Firewall preservation (explicit guarantee)

The following are on a hard refuse-list and will never be modified:

**Critical** (must stay running — script aborts if they're disabled or profiles are off):
- Services: `mpssvc`, `BFE`
- Per-profile firewall state (Domain / Private / Public)

**Touch-refuse** (script never writes to these, even if they happen to be disabled by default like `SharedAccess`/ICS):
- Services: `mpssvc`, `BFE`, `SharedAccess`, `MpsDrv`, `mpsdrv`, `MsSecWfp`, `IKEEXT`, `PolicyAgent`, `Dnscache`, `Dhcp`, `Wlansvc`, `NetSetupSvc`
- Policy paths: `HKLM\SOFTWARE\Policies\Microsoft\WindowsFirewall`, `HKLM\SYSTEM\...\mpssvc`, `HKLM\SYSTEM\...\BFE`, `HKLM\SYSTEM\...\SharedAccess\Parameters\FirewallPolicy`, `...\MpsDrv`, `...\MsSecWfp`

v0.0.2 fixed a false-positive where `SharedAccess` (ICS, off by default) tripped the guard. v0.0.3 renamed the project from DefenderPurge → DisableDefender.

## Warnings

- **Your PC will have no antivirus after running this.** Install an alternative AV if that matters to you.
- Tamper Protection must be off first. No workaround exists on Windows 11 24H2+.
- `Remove` mode partially bricks the Windows Security UI. `Restore` reprovisions it but may require `DISM /RestoreHealth` if Windows Update has installed a Security Intelligence Update.
- Windows Update may periodically re-install parts of Defender; re-run `-Mode Disable` after major feature updates.
- Use at your own risk on production systems. Authored for lab / workstation / dedicated-purpose machines (medical imaging, PACS/DICOM, VM hosts).

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Tamper Protection blocks changes" | Toggle off in Windows Security UI, rerun |
| Services come back after reboot | Boot to Safe Mode, run `-Mode Remove` |
| Get-MpComputerStatus errors in Status | Defender platform is partly removed — expected |
| Restore didn't bring back UI | `sfc /scannow && DISM /Online /Cleanup-Image /RestoreHealth` |
| Firewall got disabled | Run `-Mode Restore`, or `netsh advfirewall set allprofiles state on` |

## Log locations
- `%ProgramData%\DisableDefender\DisableDefender.log` (human-readable text)
- `%ProgramData%\DisableDefender\DisableDefender.jsonl` (structured JSONL for SIEM/automation)
- `%ProgramData%\DisableDefender\transcript.log`
- `%ProgramData%\DisableDefender\restore-manifest.jsonl`
- `%ProgramData%\DisableDefender\restore-manifest.*.jsonl`
- `%ProgramData%\DisableDefender\surface-baseline.json`
- `%ProgramData%\DisableDefender\phase-state.json`
- `%ProgramData%\DisableDefender\tripwire.jsonl`

## License

MIT. See [LICENSE](LICENSE).

## Credits / Prior Art

Techniques synthesized from:
- [undergroundwires/privacy.sexy](https://github.com/undergroundwires/privacy.sexy) — comprehensive policy key catalog (NIS, MpEngine, IPC, UX, SpyNet overrides, legacy Antimalware), MpPreference-first strategy, `grantPermissions` ACL takeover approach, SafeBoot\WinDefend trick, extended service list (`MsSecFlt`, `MsSecCore`, `SgrmAgent/Broker`, `MDDlpSvc`, `webthreatdefsvc`)
- [ionuttbara/windows-defender-remover](https://github.com/ionuttbara/windows-defender-remover) — DISM `NonRemovableAppPolicy` pattern, SecHealthUI deprovision
- [pgkt04/defender-control](https://github.com/pgkt04/defender-control) — registry flag research
- [conspiracyrip/DefenderControlV2](https://github.com/conspiracyrip/DefenderControlV2) — anti-tamper service kill surface
- Microsoft `Set-MpPreference` and `admx.help` documentation
