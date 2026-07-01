# ---------------------------------------------------------------------------
# Phase: policy keys (expanded w/ privacy.sexy findings)
# ---------------------------------------------------------------------------
function Set-DefenderPolicy {
    Write-Log "Applying Defender policy keys..." INFO

    try {
        $mpStatus = Get-MpComputerStatus -ErrorAction Stop
        if ($mpStatus.AMProductVersion) {
            $ver = [version]$mpStatus.AMProductVersion
            if ($ver -ge [version]'4.18.2007.8') {
                Write-Log "DisableAntiSpyware is a no-op on platform $($mpStatus.AMProductVersion) -- kept for legacy compatibility only." WARN
            }
        }
    } catch {}

    foreach ($entry in Get-DefenderPolicyCatalog) {
        Set-RegValue $entry.Path $entry.Name $entry.Value
    }

    Write-Log "Policy keys written." OK
}

function Clear-DefenderPolicy {
    Write-Log "Removing Defender policy keys..." INFO
    $roots = @(
        $script:PolicyRoot, $script:RealTimeRoot, $script:SpynetRoot,
        $script:SignatureRoot, $script:ReportingRoot, $script:MpEngineRoot,
        $script:ScanRoot, $script:UXRoot, $script:NISRoot,
        $script:ATPRoot, $script:MRTRoot, $script:MsAntimalware
    )
    foreach ($r in $roots) {
        if (Test-Path -LiteralPath $r) {
            Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Removed $r" DEBUG
        }
    }
    if (Test-Path -LiteralPath $script:SmartScreen) {
        Remove-ItemProperty -LiteralPath $script:SmartScreen -Name 'EnableSmartScreen' -ErrorAction SilentlyContinue
    }
    # Restore WMI Autologger entries
    $loggerRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger'
    foreach ($logger in @('DefenderApiLogger','DefenderAuditLogger')) {
        $lPath = Join-Path $loggerRoot $logger
        if (Test-Path -LiteralPath $lPath) {
            New-ItemProperty -LiteralPath $lPath -Name 'Start' -Value 1 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }
    Write-Log "Policy keys cleared." OK
}
