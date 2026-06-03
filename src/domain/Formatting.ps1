#requires -Version 7.4
#
# Pure formatters. They build the human-facing strings; the ConsolePresenter
# adapter only Write-*s them. Keeping Format-* pure means the console output is
# unit-testable with no captured host. Time math is pure because "now" is
# always injected.
# Depends on: Enums.ps1, ValueObjects.ps1.

function Test-ColorEnabled
{
  # Pure colour-policy decision. Colour is used only on a real terminal: NOT
  # when NO_COLOR is set (https://no-color.org) and NOT when output is
  # redirected/piped (so captured text stays plain). The caller supplies the
  # two facts; this function does no I/O and is fully testable.
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)][bool] $NoColor,
    [Parameter(Mandatory)][bool] $Redirected
  )
  (-not $NoColor) -and (-not $Redirected)
}

function Get-OutcomePhrase
{
  [OutputType([string])]
  param([Parameter(Mandatory)][string] $Outcome)
  switch ($Outcome)
  {
    'NothingToDo'
    {
      'Nothing to update'
    }
    'Succeeded'
    {
      'Succeeded'
    }
    'Skipped'
    {
      'Completed with skipped targets'
    }
    'ManualActionRequired'
    {
      'Manual action required'
    }
    'Failed'
    {
      'Failed'
    }
    default
    {
      $Outcome
    }
  }
}

function Get-RelativeTimeText
{
  # A friendly "how long ago" phrase. Pure: both ends supplied.
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][datetimeoffset] $From,
    [Parameter(Mandatory)][datetimeoffset] $To
  )
  $span = $To - $From
  if ($span.TotalSeconds -lt 0)
  {
    return 'in the future'
  }
  if ($span.TotalSeconds -lt 60)
  {
    return 'just now'
  }
  if ($span.TotalMinutes -lt 60)
  {
    $n = [int][math]::Round($span.TotalMinutes)
    return "about $n minute$($n -ne 1 ? 's' : '') ago"
  }
  if ($span.TotalHours -lt 24)
  {
    $n = [int][math]::Round($span.TotalHours)
    return "about $n hour$($n -ne 1 ? 's' : '') ago"
  }
  $n = [int][math]::Floor($span.TotalDays)
  "$n day$($n -ne 1 ? 's' : '') ago"
}

function Format-FirstRunLine
{
  [OutputType([string])]
  param()
  'Last run: never - first recorded invocation on this machine.'
}

function Format-LastRunLine
{
  # Render the persisted last-run record as one line: absolute + relative time,
  # outcome, what was applied, and whether a reboot was pending.
  [OutputType([string])]
  param(
    [Parameter(Mandatory)][object] $Record,
    [Parameter(Mandatory)][datetimeoffset] $Now
  )
  $when    = [datetimeoffset]::Parse([string]$Record.timestamp)
  $abs     = $when.ToString('yyyy-MM-dd HH:mm')
  $rel     = Get-RelativeTimeText -From $when -To $Now
  $phrase  = Get-OutcomePhrase -Outcome ([string]$Record.outcome)
  $applied = [int]$Record.updates_applied_total

  $line = "Last run: $abs ($rel) - $phrase; $applied updates applied"
  if ($Record.reboot_required)
  {
    $line += '; reboot was pending'
  }
  "$line."
}

function Format-OneLineResult
{
  # One line summarising a single target's result, with a leading status glyph
  # (ASCII for encoding safety across consoles).
  [OutputType([string])]
  param([Parameter(Mandatory)][object] $Result)

  $name = $Result.Target.DisplayName
  switch ($Result.Outcome.ToString())
  {
    'Succeeded'
    {
      $count = @($Result.ItemsApplied).Count
      $note  = $Result.RebootRequired ? ' (reboot required)' : ''
      "  [+] $name - Succeeded ($count applied)$note"
    }
    'NothingToDo'
    {
      "  [=] $name - Nothing to do"
    }
    'Skipped'
    {
      "  [-] $name - Skipped"
    }
    'ManualActionRequired'
    {
      "  [!] $name - Manual action required"
    }
    'Failed'
    {
      "  [x] $name - Failed: $($Result.Error)"
    }
    default
    {
      "  [ ] $name - $($Result.Outcome)"
    }
  }
}

function Format-Summary
{
  # The end-of-run summary block.
  [OutputType([string])]
  param([Parameter(Mandatory)][object] $Report)

  # Alert-only maintenance checks are excluded here - they're silent unless
  # there's a problem, which Format-Alerts surfaces separately.
  $visible = @($Report.Results | Where-Object { -not $_.Target.Capabilities.AlertOnly })

  $applied = [int](($visible | ForEach-Object { @($_.ItemsApplied).Count } | Measure-Object -Sum).Sum ?? 0)
  $failed  = [int](($visible | ForEach-Object { @($_.ItemsFailed).Count }  | Measure-Object -Sum).Sum ?? 0)
  $count   = @($visible).Count
  $seconds = [int][timespan]::FromMilliseconds($Report.DurationMs).TotalSeconds
  $phrase  = Get-OutcomePhrase -Outcome ([string](Resolve-OverallOutcome -Results $visible))

  $lines = [System.Collections.Generic.List[string]]::new()
  $lines.Add("Update summary - $phrase. $applied applied, $failed failed across $count target(s) in ${seconds}s.")
  foreach ($r in $visible)
  {
    $lines.Add((Format-OneLineResult -Result $r))
  }
  if ($Report.RebootRequired)
  {
    $lines.Add("Reboot required (decision: $($Report.RebootDecision)).")
  }
  $lines -join [Environment]::NewLine
}

function Format-ManualAdvisories
{
  # The "check these yourself" block printed at the END of a run - things the
  # tool cannot update automatically, each a name with an optional link.
  # Returns $null when there are none.
  [OutputType([string])]
  param([object[]] $Advisories = @())

  $adv = [object[]]@($Advisories)
  if ($adv.Count -eq 0)
  {
    return $null
  }

  $lines = [System.Collections.Generic.List[string]]::new()
  $lines.Add('Manual tasks (do these yourself):')

  # Group by category, preserving first-seen order of both categories and items
  # within them.
  $categories = [System.Collections.Generic.List[string]]::new()
  foreach ($a in $adv)
  {
    $c = [string]$a.Category
    if (-not $categories.Contains($c))
    {
      $categories.Add($c)
    }
  }
  foreach ($cat in $categories)
  {
    $lines.Add("  ${cat}:")
    foreach ($a in ($adv | Where-Object { [string]$_.Category -eq $cat }))
    {
      $lines.Add("    * $($a.Name)")
      if ($a.Link)
      {
        $lines.Add("        $($a.Link)")
      } else
      {
        $lines.Add('        (no link provided)')
      }
    }
  }
  $lines -join [Environment]::NewLine
}

function Format-Alerts
{
  # The "needs attention" block for alert-only maintenance checks that found a
  # problem. Returns $null when everything is clean (so the checks stay
  # silent); the orchestrator only prints this to stdout when it is non-null.
  [OutputType([string])]
  param([object[]] $Results = @())

  $alerts = @(
    [object[]]@($Results) | Where-Object {
      $_.Target.Capabilities.AlertOnly -and $_.Outcome.ToString() -eq 'Failed'
    }
  )
  if ($alerts.Count -eq 0)
  {
    return $null
  }

  $lines = [System.Collections.Generic.List[string]]::new()
  $lines.Add('!! Maintenance checks need attention:')
  foreach ($a in $alerts)
  {
    $detail = [string]::IsNullOrWhiteSpace($a.Error) ? 'problem detected' : $a.Error
    $lines.Add("  ! $($a.Target.DisplayName): $detail")
  }
  $lines -join [Environment]::NewLine
}
