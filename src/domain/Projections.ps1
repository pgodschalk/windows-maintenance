#requires -Version 7.4
#
# Pure projections of a RunReport into the shapes the outer world consumes. No
# I/O, no serialization (the sink serializes) - just shaping. Three projections
# from one aggregate:
#   1. the canonical wide event (one per invocation) -> IEventSink
#   2. the fail-fast wide event (the abort path still emits exactly one event)
#   3. the trimmed InvocationRecord (last-run memory) -> IStateStore
# Depends on: Enums.ps1, ValueObjects.ps1, Outcome.ps1.

function ConvertTo-WideEvent
{
  # The single canonical log line for a run: high-cardinality ids + env/deploy
  # context + business context, with a nested providers[] array (one event per
  # invocation, not per provider). Late-bound infra facts (state-save outcome,
  # fail reason) are parameters, so the immutable report is never mutated to
  # record them.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][object] $Report,
    [bool]   $StateSaveFailed = $false,
    [string] $FailureReason
  )
  $providers = @(
    $Report.Results | ForEach-Object {
      $r = $_
      [ordered]@{
        id              = $r.Target.Id
        display_name    = $r.Target.DisplayName
        kind            = $r.Target.Kind.ToString()
        outcome         = $r.Outcome.ToString()
        updates_applied = @($r.ItemsApplied).Count
        updates_failed  = @($r.ItemsFailed).Count
        reboot_required = [bool]$r.RebootRequired
        duration_ms     = $r.DurationMs
        items           = @($r.ItemsApplied | ForEach-Object {
            [ordered]@{ id = $_.Id; name = $_.Name; from = $_.From; to = $_.To }
          })
        error           = $r.Error
      }
    }
  )
  $advisories = @(
    $Report.Advisories | ForEach-Object {
      [ordered]@{ id = $_.Id; name = $_.Name; category = $_.Category; link = $_.Link }
    }
  )
  $appliedTotal = ($Report.Results | ForEach-Object { @($_.ItemsApplied).Count } | Measure-Object -Sum).Sum
  $failedTotal  = ($Report.Results | ForEach-Object { @($_.ItemsFailed).Count }  | Measure-Object -Sum).Sum

  [pscustomobject][ordered]@{
    event                 = 'windows_maintenance.invocation'
    schema_version        = 1
    run_id                = $Report.RunId
    host                  = $Report.Host
    timestamp             = $Report.StartedAt.ToString('o')
    env                   = ConvertTo-EnvBlock -Environment $Report.Environment
    outcome               = $Report.OverallOutcome.ToString()
    duration_ms           = $Report.DurationMs
    reboot_required       = [bool]$Report.RebootRequired
    reboot_reasons        = @($Report.RebootReasons)
    reboot_decision       = $Report.RebootDecision.ToString()
    updates_applied_total = [int]($appliedTotal ?? 0)
    updates_failed_total  = [int]($failedTotal ?? 0)
    providers_total       = @($Report.Results).Count
    providers             = $providers
    manual_advisories     = $advisories
    state_save_failed     = [bool]$StateSaveFailed
    state_load_corrupt    = [bool]$Report.StateLoadCorrupt
    failure_reason        = [string]::IsNullOrEmpty($FailureReason) ? $null : $FailureReason
  }
}

function ConvertTo-FailFastEvent
{
  # The abort path (e.g. not elevated) still emits exactly one wide event -
  # telemetry is never silent. Same schema, Failed outcome, empty providers, a
  # failure_reason.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][object] $Environment,
    [Parameter(Mandatory)][string] $RunId,
    [string] $HostName,
    [Parameter(Mandatory)][datetimeoffset] $Timestamp,
    [int]    $DurationMs = 0,
    [Parameter(Mandatory)][string] $FailureReason
  )
  [pscustomobject][ordered]@{
    event                 = 'windows_maintenance.invocation'
    schema_version        = 1
    run_id                = $RunId
    host                  = $HostName
    timestamp             = $Timestamp.ToString('o')
    env                   = ConvertTo-EnvBlock -Environment $Environment
    outcome               = 'Failed'
    duration_ms           = $DurationMs
    reboot_required       = $false
    reboot_reasons        = @()
    reboot_decision       = 'NotRequired'
    updates_applied_total = 0
    updates_failed_total  = 0
    providers_total       = 0
    providers             = @()
    manual_advisories     = @()
    state_save_failed     = $false
    state_load_corrupt    = $false
    failure_reason        = $FailureReason
  }
}

function ConvertTo-InvocationRecord
{
  # The trimmed projection persisted for "last run" display - only what the
  # next run needs. Deliberately omits the fat env/items context the wide event
  # carries.
  [CmdletBinding()]
  param([Parameter(Mandatory)][object] $Report)

  $appliedTotal = ($Report.Results | ForEach-Object { @($_.ItemsApplied).Count } | Measure-Object -Sum).Sum
  [pscustomobject][ordered]@{
    schema_version        = 1
    run_id                = $Report.RunId
    host                  = $Report.Host
    timestamp             = $Report.StartedAt.ToString('o')
    outcome               = $Report.OverallOutcome.ToString()
    reboot_required       = [bool]$Report.RebootRequired
    updates_applied_total = [int]($appliedTotal ?? 0)
    providers             = @(
      $Report.Results | ForEach-Object {
        [ordered]@{
          id              = $_.Target.Id
          outcome         = $_.Outcome.ToString()
          updates_applied = @($_.ItemsApplied).Count
        }
      }
    )
  }
}

function ConvertTo-EnvBlock
{
  # Shared shaping of the environment value object into the event's env
  # sub-document.
  [OutputType([System.Collections.Specialized.OrderedDictionary])]
  [CmdletBinding()]
  param([Parameter(Mandatory)][object] $Environment)
  [ordered]@{
    os_build       = $Environment.OsBuild
    os_version     = $Environment.OsVersion
    ps_version     = $Environment.PsVersion
    script_version = $Environment.ScriptVersion
    is_elevated    = [bool]$Environment.IsElevated
    is_interactive = [bool]$Environment.IsInteractive
    locale         = $Environment.Locale
    region         = $Environment.Region
  }
}
