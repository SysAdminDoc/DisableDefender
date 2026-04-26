# DisableDefender Roadmap

PowerShell native Defender disable/remove/restore tool with CLI and WPF GUI, explicit firewall preservation, and SYSTEM-via-task escalation. Tracks work beyond v0.0.4.

## Planned Features

### Core
- True replay-based `Restore`: every destructive op writes an undo entry to a manifest; Restore walks it in reverse so 1:1 reversibility doesn't depend on code parity with Disable
- Atomic phase boundaries — if phase N fails, log the partial state and offer resume vs rollback
- `-Only` / `-Skip` phase flags for surgical reruns (Policies, MpPreference, Tasks, Services, Appx, DISM, SafeBoot)
- `-Status` output in JSON with `-Json` for pipelines
- Health-check mode that lists every expected state (service start types, policy keys, Appx presence) and marks drift

### GUI (Catppuccin Mocha)
- Diff view between current state and target state before Disable executes
- Dashboard tile for every locked-down component (PPL status for MsMpEng/WdFilter/WdBoot/WdNisDrv)
- Live policy-key edit stream with icons for direct-write vs ACL-override vs SYSTEM-task method
- Embedded Tamper Protection detector with one-click shortcut to Windows Security
- "Firewall integrity" always-on banner; flashes red if pre/post guard trips
- Toast + system tray notification on run completion with exit code color

### CLI
- Full parity with GUI: `-Mode Disable|Remove|Restore|Status|Health`, `-Silent`, `-DryRun`, `-NoRestorePoint`, `-NoReboot`, `-Force`, `-LogPath`, `-Json`, `-Only`, `-Skip`
- Exit codes: 0 success, 1 partial, 2 Tamper-blocked, 3 needs Safe Mode, 4 firewall guard tripped
- Auto-detect third-party AV registered in Security Center and warn when it's absent after Disable

### Coverage
- Track new Windows 26H1/26H2 Defender surfaces as Microsoft ships them (additional services, Appx, telemetry keys)
- MDE passive-mode handling: when `PassiveMode` is enabled upstream, make sure Disable leaves the MDE sensor intact
- Remove `Microsoft.SecHealthUI` with fallback path for Enterprise LTSC where DISM package IDs differ
- Detect and handle the new Windows 11 "Smart App Control" policy that can force Defender on

### Safety
- Firewall integrity guard: continuously poll `Get-NetFirewallProfile` at phase boundaries and abort if any profile flipped off
- Tamper Protection pre-flight gate with a `-Force` override and a loud warning banner
- "Known-bad" override list — refuse to Remove on domain-joined machines unless `-Force` is passed, log a machine-readable tripwire
- System Restore throttle-aware checkpoint with clear messaging when Windows refuses (24h rule)
- Refuse to run under PSRemoting / PSSession unless explicitly allowed — these paths have bitten users

### Packaging
- Authenticode-signed `.ps1` + GUI launcher
- GitHub Actions workflow producing signed artifacts + SHA256SUMS on tag
- PSGallery publish (`Install-Module DisableDefender`) with GUI as an opt-in dependency
- Winget manifest (`SysAdminDoc.DisableDefender`)
- Optional `.msi` wrapper for Intune Win32 packaging

### Telemetry / Diagnostics (Local-Only)
- Structured JSONL log alongside transcript for SIEM ingestion (no outbound)
- ETW subscription for `Microsoft-Windows-Windows Defender` during run to surface silent Defender reactions
- `Export-HtmlReport` subcommand that builds a single-file HTML summary of the run

## Competitive Research

- **ionuttbara/windows-defender-remover** — Nuclear DISM-based removal; DisableDefender already borrows the `NonRemovableAppPolicy` technique. Track their releases for new Appx targets.
- **Sordum Defender Control** — Closed-source GUI gold standard for UX. DisableDefender wins on auditability; close the polish gap via the Catppuccin GUI and toast notifications.
- **undergroundwires/privacy.sexy** — Largest catalog of Defender policy keys; auto-sync via an Action that opens PRs whenever their scripts grow new keys.
- **DefenderControl (sibling)** — Reversible-only variant in the same repo family; share the 4-level escalation helper + firewall refuse-list + Catppuccin chrome.

## Nice-to-Haves

- Side-by-side state diff between two snapshots taken weeks apart
- Fleet mode (`-ComputerName`) via WinRM with explicit opt-in; batch status collection
- Safe Mode bootstrap helper: schedule a one-shot task that boots into Safe Mode, runs `-Mode Remove`, reboots back to normal
- ADMX template that disables Defender via GPO for shops that prefer GPO-first
- Integration hook with DefenderShield: if someone runs DisableDefender then later DefenderShield, the undo manifest wins
- "Disable everything except cloud sample submission" preset for the niche case where users want cloud reputation lookups but no local scanning

## Open-Source Research (Round 2)

### Related OSS Projects
- **AlteredSecurity/Disable-TamperProtection** — https://github.com/AlteredSecurity/Disable-TamperProtection — Kernel-level POC: unload `WdFilter.sys` minidriver, zero `ALTITUDE` regkey, bypass Tamper Protection via TrustedInstaller-token impersonation. Research-grade reference for why plain ACL takeover isn't enough on new builds.
- **lab52io/StopDefender** — https://github.com/lab52io/StopDefender — Token-theft approach: creates token from TrustedInstaller + WinDefend service accounts; single button-press stop without PID/args.
- **ionuttbara/windows-defender-remover** — https://github.com/ionuttbara/windows-defender-remover — `RemoveSecHealthApp.ps1` with the `dism /online /set-nonremovableapppolicy` → `Remove-AppxProvisionedPackage` → `Deprovisioned/EndOfLife` keys sequence.
- **WowT-sys/Defender-Removal** — https://github.com/WowT-sys/Defender-Removal — Isolated SecHealthUI-only removal; preserves firewall by design.
- **1sam11/remove-windows-defender** — https://github.com/1sam11/remove-windows-defender — Lightweight .bat that targets Defender but hides/disables SecHealthUI surface; also disables context menus and scan tasks.
- **gunnarhaslinger/Windows-Defender-Exploit-Guard-Configuration** — https://github.com/gunnarhaslinger/Windows-Defender-Exploit-Guard-Configuration — `Reset-RegistryKeyPermissions` exemplar for taking ownership + enabling inheritance on protected HKLM paths.
- **zoicware/DefenderProTools** — https://github.com/zoicware/DefenderProTools — DISM + TrustedInstaller removal from offline ISOs; complementary offline path.
- **pgkt04/defender-control** — https://github.com/pgkt04/defender-control — Open-source successor to Sordum Defender Control (now discontinued).

### Features to Borrow
- WdFilter minidriver unload step (research mode) before touching Defender keys on recent builds — borrow from `Disable-TamperProtection`. Gate behind a big red disclaimer.
- TrustedInstaller + WinDefend token duplication/impersonation as a process-kill primitive when `Stop-Service` is blocked — borrow from `lab52io/StopDefender`.
- SecHealthUI removal via the `set-nonremovableapppolicy` → `Remove-AppxProvisionedPackage` → `Deprovisioned/EndOfLife` sequence as a GUI-isolated operation separate from "full disable" — borrow from `ionuttbara/windows-defender-remover`.
- Offline DISM path: operate on a mounted `install.wim` (`/image:c:\mount /Remove-ProvisionedAppxPackage /PackageName:Microsoft.SecHealthUI_..._8wekyb3d8bbwe`) — borrow from the tenforums/community documented pattern, already used in `DefenderProTools`.
- IOC self-report: print the Event ID 7026 "WdFilter driver failed to load" expectation post-run so users know what they'll see in Event Viewer — borrow from `Disable-TamperProtection` write-up.
- Explicit note that `DisableAntiSpyware` is a no-op on platform 4.18.2007.8+ — borrow from Microsoft docs referenced by `Disable-TamperProtection`.
- Reusable `Reset-RegistryKeyPermissions` cmdlet for ACL-taking on any HKLM path — borrow from `gunnarhaslinger` (cleaner than the current inline ACL code).

### Patterns & Architectures Worth Studying
- `Disable-TamperProtection`'s ordered protection-chain model: WdFilter → Tamper Protection → Defender settings. DisableDefender should formalize the same layering and show the chain status in the GUI.
- `lab52io/StopDefender`'s token-duplication primitive is a general Windows privilege-escalation building block — factor it into a shared helper module reusable by DefenderControl/DisableDefender/DefenderShield.
- `ionuttbara/windows-defender-remover`'s clean separation: one script per concern (SecHealthUI / WinDefend / SmartScreen / WSC / App Guard). Makes diff'ing, testing, and user-opt-in per subsystem tractable.
