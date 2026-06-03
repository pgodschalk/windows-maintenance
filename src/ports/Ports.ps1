#requires -Version 7.4
#
# Ports = the boundaries. A port is a [pscustomobject] carrying [scriptblock]
# members, produced by a factory. Adapters (the imperative shell) build these;
# the application core calls their members. This is the idiomatic PowerShell
# ports & adapters style - it sidesteps every PS-class pitfall (no parse-time
# load order, no `using module`, no per-method mocking, no [ref] silent-fail
# with COM) and makes dependency injection by value trivial.
#
# Driven (secondary) ports: UpdateProvider, Clock, StateStore, EventSink,
# Presenter.
# Depends on: nothing (Ports only describe shapes; Domain types flow through as
# data).

function New-UpdateProviderPort
{
  # The pluggable update target. ONE port with a Kind discriminator (carried on
  # Target) - automated and manual-advisory targets share this shape so the
  # orchestrator treats them uniformly. GetPlan discovers (impure); Apply
  # realises the plan (impure). The proceed/skip POLICY lives in the pure core
  # (Get-UpdateDecision), so adapters stay dumb I/O.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][object]      $Target,     # WindowsMaintenance.UpdateTarget
    [Parameter(Mandatory)][scriptblock] $GetPlan,    # { param($ctx) -> UpdatePlan }
    [Parameter(Mandatory)][scriptblock] $Apply       # { param($ctx,$plan) -> UpdateResult }
  )
  [pscustomobject]@{
    PSTypeName = 'WindowsMaintenance.Port.UpdateProvider'
    Target     = $Target
    GetPlan    = $GetPlan
    Apply      = $Apply
  }
}

function New-ClockPort
{
  [CmdletBinding()]
  param([Parameter(Mandatory)][scriptblock] $Now)   # { -> [datetimeoffset] }
  [pscustomobject]@{ PSTypeName = 'WindowsMaintenance.Port.Clock'; Now = $Now }
}

function New-StateStorePort
{
  # Load returns an envelope { Record = <InvocationRecord|$null>; Corrupt =
  # [bool] } so the orchestrator can tell "first run" (Record null, not
  # corrupt) from "unreadable" (corrupt).
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][scriptblock] $Load,   # { -> { Record; Corrupt } }
    [Parameter(Mandatory)][scriptblock] $Save    # { param($record) }
  )
  [pscustomobject]@{ PSTypeName = 'WindowsMaintenance.Port.StateStore'; Load = $Load; Save = $Save }
}

function New-EventSinkPort
{
  # Receives an already-built event object; does ONLY serialization +
  # transport.
  [CmdletBinding()]
  param([Parameter(Mandatory)][scriptblock] $Emit)  # { param($event) }
  [pscustomobject]@{ PSTypeName = 'WindowsMaintenance.Port.EventSink'; Emit = $Emit }
}

function New-PresenterPort
{
  # Human-facing output. The strings are formatted by the pure core; this just
  # writes them. ShowLastRun/ShowProgress/ShowSummary are primary output
  # (stdout); ShowAlert is for something-is-wrong messages and goes to stderr,
  # keeping the two streams disciplined.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][scriptblock] $ShowLastRun,   # { param($text) }
    [Parameter(Mandatory)][scriptblock] $ShowProgress,  # { param($text) }
    [Parameter(Mandatory)][scriptblock] $ShowSummary,   # { param($text) }
    [Parameter(Mandatory)][scriptblock] $ShowAlert,     # { param($text) } -> stderr
    [Parameter(Mandatory)][scriptblock] $ConfirmReboot  # { param($prompt) -> [bool] }
  )
  [pscustomobject]@{
    PSTypeName    = 'WindowsMaintenance.Port.Presenter'
    ShowLastRun   = $ShowLastRun
    ShowProgress  = $ShowProgress
    ShowSummary   = $ShowSummary
    ShowAlert     = $ShowAlert
    ConfirmReboot = $ConfirmReboot
  }
}

function Confirm-Port
{
  # Fail loudly and early if an adapter doesn't satisfy a port's shape.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][object]   $Port,
    [Parameter(Mandatory)][string]   $PSTypeName,
    [Parameter(Mandatory)][string[]] $Members
  )
  if ($Port.PSObject.TypeNames -notcontains $PSTypeName)
  {
    throw "Port assertion failed: expected type '$PSTypeName', got '$($Port.PSObject.TypeNames[0])'."
  }
  foreach ($m in $Members)
  {
    if ($Port.$m -isnot [scriptblock])
    {
      throw "Port assertion failed: '$PSTypeName' is missing scriptblock member '$m'."
    }
  }
  $Port
}
