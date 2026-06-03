#requires -Version 7.4
#
# Pure policy decisions. These sit BETWEEN a provider's (impure) discovery and
# its (impure) application - the middle of the functional-core/imperative-shell
# sandwich - so the adapters stay dumb I/O and all "should we?" logic is here,
# testable with no mocks.
# Depends on: Enums.ps1, ValueObjects.ps1.

function Get-UpdateDecision
{
  # Decide what to do with one target given its discovered plan and the
  # environment.
  # Returns a discriminator the orchestrator switches on: Proceed | Skip |
  # ManualOnly | NothingToDo.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][object] $Target,
    [Parameter(Mandatory)][object] $Plan,
    [Parameter(Mandatory)][object] $Environment
  )
  if ($Target.Kind -eq [ProviderKind]::ManualAdvisory)
  {
    return [pscustomobject]@{ Kind = 'ManualOnly'; Reason = 'manual advisory target' }
  }
  if (-not $Target.Capabilities.Enabled)
  {
    return [pscustomobject]@{ Kind = 'Skip'; Reason = 'disabled by configuration' }
  }
  if (@($Plan.Items).Count -eq 0)
  {
    return [pscustomobject]@{ Kind = 'NothingToDo'; Reason = 'no updates available' }
  }
  [pscustomobject]@{ Kind = 'Proceed'; Reason = 'updates available' }
}

function Test-ElevationGate
{
  # Precondition: may the run proceed given elevation? It may NOT only when an
  # enabled, elevation-requiring provider is selected on an unelevated session.
  # (Disabled providers won't run, so they don't force elevation.)
  [OutputType([bool])]
  [CmdletBinding()]
  param(
    [object[]] $Providers = @(),
    [Parameter(Mandatory)][object] $Environment
  )
  if ($Environment.IsElevated)
  {
    return $true
  }

  $needsElevation = @(
    [object[]]@($Providers) | Where-Object {
      $_.Target.Capabilities.Enabled -and $_.Target.Capabilities.RequiresElevation
    }
  )
  $needsElevation.Count -eq 0
}
