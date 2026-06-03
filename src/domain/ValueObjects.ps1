#requires -Version 7.4
#
# Domain value objects, built by factory functions. Each returns a
# [pscustomobject] tagged with a PSTypeName. They are immutable BY CONVENTION:
# the functional core never mutates them - it always constructs new ones.
# (Hard-sealing every DTO via Update-TypeData ScriptProperty traps adds fragile
# machinery for little gain in a single-process tool.)
#
# Depends on: Enums.ps1 (for [UpdateOutcome] / [ProviderKind] parameter
# constraints).

function New-UpdateItem
{
  # A single unit of change, with an optional prior version (a fresh Windows KB
  # has none).
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string] $Id,
    [Parameter(Mandatory)][string] $Name,
    [string] $From,
    [Parameter(Mandatory)][string] $To
  )
  [pscustomobject]@{
    PSTypeName = 'WindowsMaintenance.UpdateItem'
    Id         = $Id
    Name       = $Name
    From       = [string]::IsNullOrEmpty($From) ? $null : $From
    To         = $To
  }
}

function New-UpdateTarget
{
  # The identity card of an update target (data, not behavior - the provider
  # carries one). Capabilities default by kind: automated targets require
  # elevation; manual advisories never do.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string] $Id,
    [Parameter(Mandatory)][string] $DisplayName,
    [Parameter(Mandatory)][ProviderKind] $Kind,
    [hashtable] $Capabilities
  )
  $caps = @{
    Enabled           = $true
    RequiresElevation = ($Kind -eq [ProviderKind]::Automated)
    AlertOnly         = $false   # alert-only checks run silently; surfaced only on a problem
  }
  if ($Capabilities)
  {
    foreach ($key in $Capabilities.Keys)
    {
      $caps[$key] = $Capabilities[$key]
    }
  }
  [pscustomobject]@{
    PSTypeName   = 'WindowsMaintenance.UpdateTarget'
    Id           = $Id
    DisplayName  = $DisplayName
    Kind         = $Kind
    Capabilities = [pscustomobject]$caps
  }
}

function New-UpdatePlan
{
  # What a provider intends to do: a set of items to apply and/or a manual
  # advisory.
  [CmdletBinding()]
  param(
    [object[]] $Items = @(),
    [object]   $Advisory
  )
  [pscustomobject]@{
    PSTypeName = 'WindowsMaintenance.UpdatePlan'
    Items      = [object[]]@($Items)
    Advisory   = $Advisory
  }
}

function New-ManualAdvisory
{
  # A thing the tool cannot update itself - a name to check, optionally with a
  # link. Drives the config-defined manual tasks (and anything else that can
  # only be surfaced for the human).
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string] $Id,
    [Parameter(Mandatory)][string] $Name,
    [Parameter(Mandatory)][string] $Category,
    [string] $Link
  )
  [pscustomobject]@{
    PSTypeName = 'WindowsMaintenance.ManualAdvisory'
    Id         = $Id
    Name       = $Name
    Category   = $Category
    Link       = [string]::IsNullOrWhiteSpace($Link) ? $null : $Link
  }
}

function New-UpdateResult
{
  # The outcome of executing one target's plan.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][object] $Target,
    [Parameter(Mandatory)][UpdateOutcome] $Outcome,
    [object[]] $ItemsApplied = @(),
    [object[]] $ItemsFailed = @(),
    [object]   $Advisory,
    [bool]     $RebootRequired = $false,
    [int]      $DurationMs = 0,
    [string]   $ErrorMessage
  )
  $applied = [object[]]@($ItemsApplied)
  # Invariant: outcomes that mean "no work happened" cannot carry applied items.
  $noWork = @([UpdateOutcome]::NothingToDo, [UpdateOutcome]::Skipped, [UpdateOutcome]::ManualActionRequired)
  if ($applied.Count -gt 0 -and $Outcome -in $noWork)
  {
    throw "UpdateResult invariant violated: outcome '$Outcome' cannot have applied items."
  }
  [pscustomobject]@{
    PSTypeName     = 'WindowsMaintenance.UpdateResult'
    Target         = $Target
    Outcome        = $Outcome
    ItemsApplied   = $applied
    ItemsFailed    = [object[]]@($ItemsFailed)
    Advisory       = $Advisory
    RebootRequired = $RebootRequired
    DurationMs     = $DurationMs
    Error          = [string]::IsNullOrEmpty($ErrorMessage) ? $null : $ErrorMessage
  }
}

function New-EnvironmentInfo
{
  # Deployment/host context, captured once by the shell and threaded into the
  # pure core.
  [CmdletBinding()]
  param(
    [string] $OsBuild,
    [string] $OsVersion,
    [string] $PsVersion,
    [string] $ScriptVersion,
    [bool]   $IsElevated,
    [bool]   $IsInteractive,
    [string] $Locale,
    [string] $Region
  )
  [pscustomobject]@{
    PSTypeName    = 'WindowsMaintenance.Environment'
    OsBuild       = $OsBuild
    OsVersion     = $OsVersion
    PsVersion     = $PsVersion
    ScriptVersion = $ScriptVersion
    IsElevated    = $IsElevated
    IsInteractive = $IsInteractive
    Locale        = $Locale
    Region        = $Region
  }
}
