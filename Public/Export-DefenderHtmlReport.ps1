function Export-DefenderHtmlReport {
    <#
    .SYNOPSIS
        Builds a single-file HTML summary of the current Defender state.
    .DESCRIPTION
        Collects health, component status, and system information into a
        self-contained HTML report with inline CSS. No external dependencies.
    .PARAMETER OutputPath
        Path for the HTML file. Defaults to DisableDefender-report.html in
        the current directory.
    .PARAMETER HealthTarget
        Expected target for the health comparison. Defaults to Disable.
    .PARAMETER IncludeMDE
        Include MDE Sense service in the health comparison.
    .EXAMPLE
        Export-DefenderHtmlReport
    .EXAMPLE
        Export-DefenderHtmlReport -OutputPath C:\Reports\defender.html -HealthTarget Remove
    #>
    [CmdletBinding()]
    param(
        [string]$OutputPath,
        [ValidateSet('Disable','Remove','Restore')]
        [string]$HealthTarget = 'Disable',
        [switch]$IncludeMDE
    )

    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $OutputPath = Join-Path (Get-Location).Path 'DisableDefender-report.html'
    }

    $reportTime = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

    $osInfo = 'Unknown'
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $osInfo = "$($os.Caption) $($os.Version)"
        try {
            $dv = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'DisplayVersion' -ErrorAction Stop).DisplayVersion
            $osInfo += " ($dv)"
        } catch {}
    } catch {}

    $health = $null
    try { $health = Get-DefenderHealth -Target $HealthTarget -IncludeMDE:$IncludeMDE } catch {}

    $components = @()
    try { $components = @(Get-DefenderComponentStatus) } catch {}

    $statusRows = ''
    if ($health -and $health.Items) {
        foreach ($item in $health.Items) {
            $rowClass = switch ($item.Status) {
                'OK'      { 'row-ok' }
                'Drift'   { 'row-drift' }
                'Unknown' { 'row-unknown' }
                default   { '' }
            }
            $cat = [System.Net.WebUtility]::HtmlEncode([string]$item.Category)
            $name = [System.Net.WebUtility]::HtmlEncode([string]$item.Name)
            $exp = [System.Net.WebUtility]::HtmlEncode([string]$item.Expected)
            $act = [System.Net.WebUtility]::HtmlEncode([string]$item.Actual)
            $st = [System.Net.WebUtility]::HtmlEncode([string]$item.Status)
            $statusRows += "<tr class=`"$rowClass`"><td>$cat</td><td>$name</td><td>$exp</td><td>$act</td><td>$st</td></tr>`n"
        }
    }

    $componentRows = ''
    foreach ($c in $components) {
        $cName = [System.Net.WebUtility]::HtmlEncode([string]$c.Name)
        $cSvc = [System.Net.WebUtility]::HtmlEncode([string]$c.Service)
        $cRuntime = [System.Net.WebUtility]::HtmlEncode([string]$c.RuntimeStatus)
        $cPpl = if ($c.PSObject.Properties.Name -contains 'PPLStatus') {
            [System.Net.WebUtility]::HtmlEncode([string]$c.PPLStatus)
        } else { '' }
        $componentRows += "<tr><td>$cName</td><td>$cSvc</td><td>$cRuntime</td><td>$cPpl</td></tr>`n"
    }

    $summaryText = ''
    $summaryHtml = 'Health data unavailable.'
    if ($health -and $health.Summary) {
        $s = $health.Summary
        $summaryText = "OK=$($s.OK) Drift=$($s.Drift) Unknown=$($s.Unknown) Total=$($s.Total)"
        $summaryHtml = "Health summary: <span class=`"ok`">OK=$($s.OK)</span> <span class=`"drift`">Drift=$($s.Drift)</span> <span class=`"unknown`">Unknown=$($s.Unknown)</span> Total=$($s.Total)"
    }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>DisableDefender Report</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font-family: 'Segoe UI', system-ui, sans-serif; background: #1e1e2e; color: #cdd6f4; padding: 24px; }
  h1 { color: #89b4fa; margin-bottom: 4px; }
  h2 { color: #a6adc8; margin: 24px 0 8px; border-bottom: 1px solid #313244; padding-bottom: 4px; }
  .meta { color: #6c7086; font-size: 0.85em; margin-bottom: 16px; }
  .summary { background: #313244; border-radius: 8px; padding: 12px 16px; margin: 12px 0; font-size: 1.1em; }
  .summary .ok { color: #a6e3a1; } .summary .drift { color: #f38ba8; } .summary .unknown { color: #fab387; }
  table { width: 100%; border-collapse: collapse; margin: 8px 0; }
  th { background: #313244; color: #89b4fa; text-align: left; padding: 8px 10px; font-weight: 600; }
  td { padding: 6px 10px; border-bottom: 1px solid #313244; font-size: 0.9em; overflow-wrap: anywhere; }
  .row-ok td:last-child { color: #a6e3a1; }
  .row-drift td:last-child { color: #f38ba8; font-weight: 600; }
  .row-unknown td:last-child { color: #fab387; }
  footer { margin-top: 32px; color: #585b70; font-size: 0.8em; text-align: center; }
</style>
</head>
<body>
<h1>DisableDefender Report</h1>
<div class="meta">
  Generated: $reportTime | Version: $($script:Version) | Target: $HealthTarget<br>
  System: $([System.Net.WebUtility]::HtmlEncode($osInfo))
</div>

<div class="summary">
  $summaryHtml
</div>

<h2>Health Detail</h2>
<table>
<tr><th>Category</th><th>Name</th><th>Expected</th><th>Actual</th><th>Status</th></tr>
$statusRows
</table>

<h2>Component Status</h2>
<table>
<tr><th>Name</th><th>Service</th><th>Status</th><th>PPL</th></tr>
$componentRows
</table>

<footer>DisableDefender v$($script:Version) -- single-file HTML report</footer>
</body>
</html>
"@

    Set-Content -LiteralPath $OutputPath -Value $html -Encoding UTF8
    Write-Log "HTML report exported: $OutputPath" OK

    return [PSCustomObject]@{
        ReportPath   = $OutputPath
        HealthTarget = $HealthTarget
        Summary      = $summaryText
        Generated    = $reportTime
    }
}
