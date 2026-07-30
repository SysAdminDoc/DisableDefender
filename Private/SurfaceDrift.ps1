# ---------------------------------------------------------------------------
# Defender surface drift detection
# Tracks Windows build and Defender-like services, tasks, and Appx packages.
# ---------------------------------------------------------------------------

function Get-DefenderSurfaceBaselinePath {
    return (Join-Path $script:AppDir 'surface-baseline.json')
}

function Get-DefenderWindowsBuildInfo {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $displayVersion = $null
        try {
            $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
            if ($cv.DisplayVersion) { $displayVersion = [string]$cv.DisplayVersion }
            elseif ($cv.ReleaseId) { $displayVersion = [string]$cv.ReleaseId }
        } catch {}
        return [pscustomobject][ordered]@{
            Caption        = [string]$os.Caption
            Version        = [string]$os.Version
            BuildNumber    = [string]$os.BuildNumber
            DisplayVersion = $displayVersion
        }
    } catch {
        return [pscustomobject][ordered]@{
            Caption        = 'unknown'
            Version        = 'unknown'
            BuildNumber    = 'unknown'
            DisplayVersion = $null
        }
    }
}

function ConvertTo-DefenderBuildLabel {
    param([AllowNull()]$Build)

    if ($null -eq $Build) { return 'unknown' }
    $parts = New-Object System.Collections.ArrayList
    foreach ($name in @('Caption','Version','BuildNumber','DisplayVersion')) {
        if ($Build.PSObject.Properties.Name -contains $name -and -not [string]::IsNullOrWhiteSpace([string]$Build.$name)) {
            [void]$parts.Add([string]$Build.$name)
        }
    }
    if ($parts.Count -eq 0) { return 'unknown' }
    return ($parts -join ' ')
}

function Get-KnownDefenderServiceNames {
    return @(($script:DefenderServices + $script:MDEServices + $script:RefuseTouchServices) | Sort-Object -Unique)
}

function Test-DefenderLikeServiceName {
    param([Parameter(Mandatory)][string]$Name)

    return ($Name -match '^(WinDefend|Wd[A-Za-z0-9]|MD[A-Za-z0-9]|MsSec|Sgrm|webthreat|SecurityHealth|wscsvc|Sense$)')
}

function Get-DefenderLikeServices {
    $services = New-Object System.Collections.ArrayList
    try {
        foreach ($serviceKey in (Get-ChildItem -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue)) {
            $name = [string]$serviceKey.PSChildName
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if (-not (Test-DefenderLikeServiceName -Name $name)) { continue }
            [void]$services.Add($name)
        }
    } catch {}
    return @(($services | Sort-Object -Unique))
}

function ConvertTo-DefenderTaskPath {
    param(
        [Parameter(Mandatory)][string]$TaskPath,
        [Parameter(Mandatory)][string]$TaskName
    )

    $path = if ($TaskPath.EndsWith('\')) { $TaskPath } else { "$TaskPath\" }
    return "$path$TaskName"
}

function Get-DefenderLikeTasks {
    $tasks = New-Object System.Collections.ArrayList
    try {
        foreach ($task in (Get-ScheduledTask -ErrorAction SilentlyContinue)) {
            $fullName = ConvertTo-DefenderTaskPath -TaskPath ([string]$task.TaskPath) -TaskName ([string]$task.TaskName)
            if ($fullName -notmatch '(Windows Defender|ExploitGuard|Defender)') { continue }
            [void]$tasks.Add($fullName)
        }
    } catch {}
    return @(($tasks | Sort-Object -Unique))
}

function Get-DefenderLikePackages {
    $packages = New-Object System.Collections.ArrayList
    try {
        foreach ($package in (Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)) {
            $name = if ($package.Name) { [string]$package.Name } else { [string]$package.PackageFullName }
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($name -notmatch '(Defender|SecHealth|SecurityHealth)') { continue }
            [void]$packages.Add($name)
        }
    } catch {}
    try {
        foreach ($package in (Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)) {
            $name = if ($package.DisplayName) { [string]$package.DisplayName } else { [string]$package.PackageName }
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($name -notmatch '(Defender|SecHealth|SecurityHealth)') { continue }
            [void]$packages.Add($name)
        }
    } catch {}
    return @(($packages | Sort-Object -Unique))
}

function Get-DefenderSurfaceSnapshot {
    return [pscustomobject][ordered]@{
        SchemaVersion = Get-DefenderArtifactSchemaVersion -Name SurfaceBaseline
        Generated     = (Get-Date).ToString('o')
        WindowsBuild  = Get-DefenderWindowsBuildInfo
        Services      = @(Get-DefenderLikeServices)
        Tasks         = @(Get-DefenderLikeTasks)
        Packages      = @(Get-DefenderLikePackages)
    }
}

function Save-DefenderSurfaceBaseline {
    param([Parameter(Mandatory)][ValidateSet('Disable','Remove')][string]$Mode)

    if ($WhatIfPreference) { return }
    $snapshot = Get-DefenderSurfaceSnapshot
    $snapshot | Add-Member -NotePropertyName Mode -NotePropertyValue $Mode -Force
    $path = Get-DefenderSurfaceBaselinePath
    Assert-DefenderRuntimeDirectory -Path (Split-Path -Parent $path)
    Write-DefenderJsonArtifactAtomic -Name SurfaceBaseline -Path $path `
        -InputObject $snapshot -Depth 8 | Out-Null
    Write-Log "Defender surface baseline saved to $path" DEBUG
}

function Read-DefenderSurfaceBaseline {
    $path = Get-DefenderSurfaceBaselinePath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return (Read-DefenderJsonArtifact -Name SurfaceBaseline -Path $path)
}

function Get-DefenderReapplyPlan {
    param([switch]$IncludeMDE)

    $mdeText = if ($IncludeMDE) {
        'MDE Sense is included because -IncludeMDE was passed.'
    } else {
        'MDE Sense is preserved; do not pass -IncludeMDE unless enterprise EDR should be disabled.'
    }
    return @(
        'Review Health drift and unknown Surface items before changing services.',
        'Re-run .\DisableDefender.ps1 -Mode Disable -Only Policies,MpPreference,Tasks,Services -NoRestorePoint -NoReboot after confirming Tamper Protection is off.',
        $mdeText,
        'Firewall refuse-list and MDE default-preserve behavior remain enforced during reapply.'
    )
}
