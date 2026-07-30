function Get-DefenderSafeModeStatus {
    <#
    .SYNOPSIS
        Returns the persisted Safe Mode removal transaction and live task/BCD evidence.
    .PARAMETER Json
        Emit the status contract as JSON.
    .EXAMPLE
        Get-DefenderSafeModeStatus
    .EXAMPLE
        Get-DefenderSafeModeStatus -Json
    #>
    [CmdletBinding()]
    param([switch]$Json)

    $state = Read-DefenderSafeModeTransaction
    if ($null -eq $state) {
        $status = [PSCustomObject][ordered]@{
            SchemaVersion          = Get-DefenderArtifactSchemaVersion -Name SafeModeStatus
            TransactionSchema      = $null
            TransactionId          = $null
            Stage                  = 'Idle'
            Active                 = $false
            Updated                = $null
            StatePath              = Get-DefenderSafeModeTransactionPath
            BootupState            = [string](
                Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).BootupState
            Bcd                    = $null
            MainTask               = $null
            Watchdog               = $null
            ChildExitCode          = $null
            SafeModeTaskResult     = $null
            FinalizerTaskResult    = $null
            RequiredEffects        = 0
            VerifiedEffects        = 0
            LastError              = $null
            RecoveryRecommendation = 'None'
        }
    } else {
        $encodedWorker = New-DefenderSafeModeWorkerCommand -State $state
        $mainEvidence = Get-DefenderSafeModeTaskEvidence -TaskName $state.MainTaskName `
            -Kind Main -ExpectedEncodedScript $encodedWorker -AllowMissing
        $watchdogEvidence = Get-DefenderSafeModeTaskEvidence -TaskName $state.WatchdogTaskName `
            -Kind Watchdog -AllowMissing
        $bcdEvidence = Get-DefenderBcdSafeBootEvidence
        $effects = @($state.EffectEvidence)
        $requiredEffects = @($effects | Where-Object { [bool]$_.Required })
        $verifiedEffects = @($requiredEffects | Where-Object {
            [bool]$_.Verified -and @($_.Errors).Count -eq 0
        })
        $terminal = $state.Stage -in @('Completed', 'RolledBack')
        $recommendation = switch ([string]$state.Stage) {
            { $_ -in @('TasksVerified', 'SafeBootConfigured', 'RebootRequested') } { 'Resume'; break }
            'RebootRequestedNormal' { 'Finalize'; break }
            { $_ -in @('Preparing', 'SafeModeRunning', 'RemoveVerified', 'ReturnConfigured', 'Failed') } {
                'Rollback'
                break
            }
            default { 'None' }
        }
        $status = [PSCustomObject][ordered]@{
            SchemaVersion           = Get-DefenderArtifactSchemaVersion -Name SafeModeStatus
            TransactionSchema       = [int]$state.SchemaVersion
            TransactionId           = [string]$state.TransactionId
            Stage                   = [string]$state.Stage
            Active                  = -not $terminal
            Updated                 = [string]$state.Updated
            StatePath               = Get-DefenderSafeModeTransactionPath
            BootupState             = [string](
                Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).BootupState
            Bcd                     = $bcdEvidence
            MainTask                = $mainEvidence
            Watchdog                = $watchdogEvidence
            ChildExitCode           = $state.ChildExitCode
            SafeModeTaskResult      = $state.SafeModeTaskResult
            FinalizerTaskResult     = $state.FinalizerTaskResult
            RequiredEffects         = $requiredEffects.Count
            VerifiedEffects         = $verifiedEffects.Count
            LastError               = $state.LastError
            RecoveryRecommendation  = $recommendation
        }
    }

    if ($Json) {
        return ($status | ConvertTo-Json -Depth 10)
    }
    return $status
}
