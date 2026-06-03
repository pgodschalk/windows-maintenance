#requires -Version 7.4
#
# The outcome algebra and the RunReport aggregate. All pure.
# Depends on: Enums.ps1, ValueObjects.ps1 (resolvers are composed by
# New-RunReport).

function Resolve-OverallOutcome
{
  # Fold per-target outcomes into one: the worst (maximum on the severity
  # lattice) wins. An empty run is NothingToDo. Total and order-independent -
  # the crown-jewel function.
  [OutputType([UpdateOutcome])]
  [CmdletBinding()]
  param([object[]] $Results = @())

  $results = [object[]]@($Results)
  if ($results.Count -eq 0)
  {
    return [UpdateOutcome]::NothingToDo
  }

  $worst = ($results | ForEach-Object { [int]$_.Outcome } | Measure-Object -Maximum).Maximum
  [UpdateOutcome]$worst
}

function Resolve-RebootRequirement
{
  # OR-fold the per-target reboot flags; name the targets that triggered it.
  [CmdletBinding()]
  param([object[]] $Results = @())

  $reasons = @(
    [object[]]@($Results) |
      Where-Object { $_.RebootRequired } |
      ForEach-Object { [string]$_.Target.Id }
  )
  [pscustomobject]@{
    PSTypeName = 'WindowsMaintenance.RebootRequirement'
    Required   = [bool]($reasons.Count -gt 0)
    Reasons    = $reasons
  }
}

function New-RunReport
{
  # The in-memory aggregate of a whole invocation. The wide event, the
  # persisted InvocationRecord, and the console summary are all PROJECTIONS of
  # this one object. It derives the overall outcome / reboot requirement /
  # advisories from the results so the aggregate is always self-consistent; the
  # reboot DECISION is supplied by the shell.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][object] $Environment,
    [object[]] $Results = @(),
    [Parameter(Mandatory)][datetimeoffset] $StartedAt,
    [int] $DurationMs = 0,
    [Parameter(Mandatory)][string] $RunId,
    [string] $HostName,
    [RebootDecision] $RebootDecision = [RebootDecision]::NotRequired,
    [bool] $StateLoadCorrupt = $false
  )
  $results = [object[]]@($Results)
  $reboot  = Resolve-RebootRequirement -Results $results

  [pscustomobject]@{
    PSTypeName       = 'WindowsMaintenance.RunReport'
    RunId            = $RunId
    Host             = $HostName
    StartedAt        = $StartedAt
    DurationMs       = $DurationMs
    Environment      = $Environment
    Results          = $results
    OverallOutcome   = Resolve-OverallOutcome -Results $results
    RebootRequired   = $reboot.Required
    RebootReasons    = $reboot.Reasons
    RebootDecision   = $RebootDecision
    Advisories       = @($results | ForEach-Object { $_.Advisory } | Where-Object { $_ })
    StateLoadCorrupt = $StateLoadCorrupt
  }
}
