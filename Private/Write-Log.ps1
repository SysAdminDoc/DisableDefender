function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK','DEBUG')][string]$Level = 'INFO'
    )
    $now = Get-Date
    $stamp = $now.ToString('yyyy-MM-dd HH:mm:ss')
    $line  = "[$stamp] [$Level] $Message"
    if (-not $script:RuntimeDirectoryVerified) {
        Assert-DefenderRuntimeDirectory
        $script:RuntimeDirectoryVerified = $true
    }
    $logTarget = if ($script:LogPathOverride) { $script:LogPathOverride }
                 else { Join-Path $script:AppDir "$script:AppName.log" }
    try { Add-Content -LiteralPath $logTarget -Value $line -ErrorAction Stop } catch {}
    $jsonlDir = if ($script:LogPathOverride) { Split-Path -Parent $script:LogPathOverride }
                else { $script:AppDir }
    $jsonlTarget = Join-Path $jsonlDir "$script:AppName.jsonl"
    try {
        $jsonEntry = [ordered]@{
            ts    = $now.ToString('o')
            level = $Level
            msg   = $Message
        } | ConvertTo-Json -Compress
        Add-Content -LiteralPath $jsonlTarget -Value $jsonEntry -ErrorAction Stop
    } catch {}
    if ($script:LogCallback) {
        try { & $script:LogCallback -Message $Message -Level $Level } catch {}
    }
    if ($script:SilentMode) { return }
    $color = switch ($Level) {
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'DEBUG' { 'DarkGray' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
}

function Write-Banner {
    if ($script:SilentMode) { return }
    $bar = '=' * 72
    Write-Host ''
    Write-Host $bar -ForegroundColor DarkCyan
    Write-Host " $script:AppName v$script:Version" -ForegroundColor Cyan
    Write-Host "  Microsoft Defender disabler / remover (firewall preserved)" -ForegroundColor Gray
    Write-Host $bar -ForegroundColor DarkCyan
    Write-Host ''
}

function Set-RunOptions {
    param(
        [switch]$Force,
        [switch]$NoRestorePoint,
        [switch]$IncludeMDE,
        [switch]$AllowRemoting,
        [switch]$Silent,
        [string]$LogPath,
        [scriptblock]$LogCallback
    )

    $script:ForceMode = [bool]$Force
    $script:NoRestorePointMode = [bool]$NoRestorePoint
    $script:IncludeMDEMode = [bool]$IncludeMDE
    $script:AllowRemotingMode = [bool]$AllowRemoting
    $script:SilentMode = [bool]$Silent
    $script:LogPathOverride = if ([string]::IsNullOrWhiteSpace($LogPath)) { $null } else { $LogPath }
    $script:LogCallback = $LogCallback
    $script:RuntimeDirectoryVerified = $false
}
