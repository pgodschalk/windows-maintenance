#requires -Version 7.4
#
# The use case (imperative shell). Everything it needs is INJECTED - no
# globals, no Import-Module inside. It calls the pure core to decide/shape and
# the ports to act. It contains no formatting, no outcome math, and no event
# shaping (those are pure functions).
#
# Guarantees:
#   * Exactly ONE wide event per invocation, on every path (success, all-fail,
#     fail-fast).
#   * Fail-fast only for unrecoverable preconditions (elevation); the
#     per-provider loop is resilient - one provider throwing never aborts the
#     others.
# Depends on: domain (Outcome/Decisions/Projections/Formatting), ports (by
# duck-typed shape).

function Invoke-UpdateRun
{
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [object[]] $Providers = @(),
    [Parameter(Mandatory)][object] $Clock,
    [Parameter(Mandatory)][object] $StateStore,
    [Parameter(Mandatory)][object] $EventSink,
    [Parameter(Mandatory)][object] $Presenter,
    [Parameter(Mandatory)][object] $Environment,
    [string] $HostName = $env:COMPUTERNAME
  )

  $startedAt = [datetimeoffset](& $Clock.Now)
  $runId     = [guid]::NewGuid().Guid
  $dryRun    = [bool]$WhatIfPreference
  $ctx       = [pscustomobject]@{ Environment = $Environment; WhatIf = $dryRun; RunId = $runId; LastRunAt = $null }

  # --- Precondition gate: elevation. Fail fast, but still emit exactly one
  #     event. ---
  if (-not (Test-ElevationGate -Providers $Providers -Environment $Environment))
  {
    $msg = 'Elevation required: run this from an elevated PowerShell session. No changes were made.'
    & $Presenter.ShowSummary $msg
    $elapsed = [int](([datetimeoffset](& $Clock.Now)) - $startedAt).TotalMilliseconds
    $evt = ConvertTo-FailFastEvent -Environment $Environment -RunId $runId -HostName $HostName `
      -Timestamp $startedAt -DurationMs $elapsed -FailureReason 'not_elevated'
    Invoke-SafeEmit -EventSink $EventSink -EventObject $evt -Presenter $Presenter
    return New-RunResult -Outcome ([UpdateOutcome]::Failed) -FailFast -FailureReason 'not_elevated' -WideEvent $evt
  }

  $emitted = $false
  try
  {
    # --- Load + display the last run ('never' for first run or corrupt
    #     state) ---
    $loadResult = $null
    try
    {
      $loadResult = & $StateStore.Load
    } catch
    {
      $loadResult = [pscustomobject]@{ Record = $null; Corrupt = $true }
    }
    $record           = $loadResult.Record
    $stateLoadCorrupt = [bool]$loadResult.Corrupt
    if ($stateLoadCorrupt)
    {
      $record = $null
    }
    if ($record -and $record.timestamp)
    {
      try
      {
        $ctx.LastRunAt = [datetimeoffset]::Parse([string]$record.timestamp)
      } catch
      {
        Write-Verbose "could not parse last-run timestamp '$($record.timestamp)': $_"
      }
    }

    if ($record)
    {
      & $Presenter.ShowLastRun (Format-LastRunLine -Record $record -Now $startedAt)
    } else
    {
      & $Presenter.ShowLastRun (Format-FirstRunLine)
    }

    # --- Per-provider loop (resilient: a failure becomes data, never an
    #     abort) ---
    $results = [System.Collections.Generic.List[object]]::new()
    $announcedChecks = $false
    foreach ($p in $Providers)
    {
      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      $quiet = [bool]$p.Target.Capabilities.AlertOnly   # alert-only checks run silently
      # Alert-only checks are silent, but the slow ones (full scan, SFC/DISM)
      # would make a run look hung -- announce them ONCE so the user knows work
      # is still happening.
      if ($quiet -and -not $announcedChecks)
      {
        $notice = 'Running maintenance checks (storage, integrity, full scan) - this can take a while...'
        & $Presenter.ShowProgress $notice
        $announcedChecks = $true
      }
      $result = $null
      try
      {
        if (-not $quiet)
        {
          & $Presenter.ShowProgress "Checking $($p.Target.DisplayName)..."
        }
        $plan     = & $p.GetPlan $ctx
        $decision = Get-UpdateDecision -Target $p.Target -Plan $plan -Environment $Environment
        $ms = $sw.ElapsedMilliseconds
        switch ($decision.Kind)
        {
          'Skip'
          {
            $result = New-UpdateResult -Target $p.Target -Outcome 'Skipped' -DurationMs $ms
          }
          'NothingToDo'
          {
            $result = New-UpdateResult -Target $p.Target -Outcome 'NothingToDo' -DurationMs $ms
          }
          'ManualOnly'
          {
            $resultArgs = @{
              Target     = $p.Target
              Outcome    = 'ManualActionRequired'
              Advisory   = $plan.Advisory
              DurationMs = $ms
            }
            $result = New-UpdateResult @resultArgs
          }
          'Proceed'
          {
            # SupportsShouldProcess: under -WhatIf this returns $false (and
            # prints the standard "What if:" line, item count included), so
            # nothing is applied.
            $what = "$($p.Target.DisplayName) ($(@($plan.Items).Count) item(s))"
            if ($PSCmdlet.ShouldProcess($what, 'Apply updates'))
            {
              # Long-running alert-only checks (SFC/DISM, full scan) are silent
              # but slow; announce the start so the run doesn't look hung.
              # Reached only on Proceed -- skipped/NothingToDo/-WhatIf stay
              # quiet.
              if ($p.Target.Capabilities.LongRunning)
              {
                & $Presenter.ShowProgress "Starting $($p.Target.DisplayName)..."
              }
              $result = & $p.Apply $ctx $plan
            } else
            {
              $result = New-UpdateResult -Target $p.Target -Outcome 'NothingToDo' -DurationMs $ms
            }
          }
        }
      } catch
      {
        $msg = [string]$_.Exception.Message
        $ms = $sw.ElapsedMilliseconds
        $result = New-UpdateResult -Target $p.Target -Outcome 'Failed' -ErrorMessage $msg -DurationMs $ms
      } finally
      {
        $sw.Stop()
      }
      if ($null -eq $result)
      {
        $msg = 'provider returned no result'
        $ms = $sw.ElapsedMilliseconds
        $result = New-UpdateResult -Target $p.Target -Outcome 'Failed' -ErrorMessage $msg -DurationMs $ms
      }
      $results.Add($result)
      if (-not $quiet)
      {
        & $Presenter.ShowProgress (Format-OneLineResult -Result $result)
      }
    }
    $resultArray = [object[]]$results.ToArray()

    # --- Reboot prompt (shell), interactive-guarded so scheduled runs never
    #     hang ---
    $reboot = Resolve-RebootRequirement -Results $resultArray
    $rebootDecision = [RebootDecision]::NotRequired
    if ($reboot.Required)
    {
      if ($Environment.IsInteractive)
      {
        $confirmed = [bool](& $Presenter.ConfirmReboot 'Updates require a reboot to finish. Restart now?')
        $rebootDecision = $confirmed ? [RebootDecision]::Confirmed : [RebootDecision]::Declined
      } else
      {
        $rebootDecision = [RebootDecision]::NotPromptedNonInteractive
      }
    }

    # --- Assemble the aggregate (pure) ---
    $elapsed = [int](([datetimeoffset](& $Clock.Now)) - $startedAt).TotalMilliseconds
    $report = New-RunReport -Environment $Environment -Results $resultArray -StartedAt $startedAt `
      -DurationMs $elapsed -RunId $runId -HostName $HostName `
      -RebootDecision $rebootDecision -StateLoadCorrupt $stateLoadCorrupt

    # --- Present the human summary + the manual-advisory link block ---
    & $Presenter.ShowSummary (Format-Summary -Report $report)
    $advisoryBlock = Format-ManualAdvisories -Advisories $report.Advisories
    if ($advisoryBlock)
    {
      & $Presenter.ShowSummary $advisoryBlock
    }

    # --- Alert-only maintenance checks: surface to STDERR ONLY when something
    #     is wrong ---
    $alertBlock = Format-Alerts -Results $resultArray
    if ($alertBlock)
    {
      & $Presenter.ShowAlert $alertBlock
    }

    # --- Persist the trimmed record (best-effort: a failed save must not crash
    #     the run) ---
    $stateSaveFailed = $false
    try
    {
      & $StateStore.Save (ConvertTo-InvocationRecord -Report $report)
    } catch
    {
      $stateSaveFailed = $true
    }

    # --- Emit the ONE canonical wide event ---
    $evt = ConvertTo-WideEvent -Report $report -StateSaveFailed $stateSaveFailed
    Invoke-SafeEmit -EventSink $EventSink -EventObject $evt -Presenter $Presenter
    $emitted = $true

    # Carry the exact event that was logged on the return value, so -Json can
    # emit it to stdout without re-projecting (or reaching into module
    # internals).
    $report | Add-Member -NotePropertyName WideEvent -NotePropertyValue $evt -Force
    return $report
  } catch
  {
    # Unexpected shell failure (not a provider - those are caught above).
    # Honour the single-event invariant: emit one fail event if we haven't
    # already.
    if (-not $emitted)
    {
      $elapsed = [int](([datetimeoffset](& $Clock.Now)) - $startedAt).TotalMilliseconds
      $evt = ConvertTo-FailFastEvent -Environment $Environment -RunId $runId -HostName $HostName `
        -Timestamp $startedAt -DurationMs $elapsed -FailureReason ([string]$_.Exception.Message)
      Invoke-SafeEmit -EventSink $EventSink -EventObject $evt -Presenter $Presenter
    }
    return New-RunResult -Outcome ([UpdateOutcome]::Failed) -FailFast `
      -FailureReason ([string]$_.Exception.Message) -WideEvent $evt
  }
}

function Invoke-SafeEmit
{
  # Telemetry transport must never crash a run. If the sink throws (e.g. the
  # Event Log source can't be created on an unelevated first run), degrade to a
  # stderr fallback so the event is never lost. ($Event would shadow the
  # automatic variable, hence $EventObject.)
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][object] $EventSink,
    [Parameter(Mandatory)][object] $EventObject,
    [Parameter(Mandatory)][object] $Presenter
  )
  try
  {
    & $EventSink.Emit $EventObject
  } catch
  {
    try
    {
      $json = $EventObject | ConvertTo-Json -Depth 8 -Compress
      & $Presenter.ShowAlert "event-sink-fallback: $json"
    } catch
    {
      Write-Verbose "event-sink fallback also failed to render: $_"
    }
  }
}

function New-RunResult
{
  # The shape returned to the entrypoint on the non-report paths (fail-fast /
  # unexpected error). Exposes the same fields the entrypoint reads from a
  # RunReport.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][UpdateOutcome] $Outcome,
    [switch] $FailFast,
    [string] $FailureReason,
    [object] $WideEvent
  )
  [pscustomobject]@{
    PSTypeName     = 'WindowsMaintenance.RunResult'
    OverallOutcome = $Outcome
    RebootRequired = $false
    RebootDecision = [RebootDecision]::NotRequired
    FailFast       = [bool]$FailFast
    FailureReason  = $FailureReason
    Report         = $null
    WideEvent      = $WideEvent
  }
}
