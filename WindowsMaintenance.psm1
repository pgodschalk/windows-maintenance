#requires -Version 7.4
#
# Root module. Dot-sources the layers IN DEPENDENCY ORDER and exposes the
# public surface. Order is load-bearing: Enums.ps1 defines the types used as
# parameter constraints by later files, so it must come first; Ports before
# adapters; adapters before the composition root.

$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot 'src'

$loadOrder = @(
  # Domain (functional core) - pure, no I/O.
  'domain/Enums.ps1'
  'domain/ValueObjects.ps1'
  'domain/Outcome.ps1'
  'domain/Decisions.ps1'
  'domain/Projections.ps1'
  'domain/Formatting.ps1'
  # Ports (contracts).
  'ports/Ports.ps1'
  # Application (use case / imperative shell).
  'application/Invoke-UpdateRun.ps1'
  # Adapters (driven, imperative shell). Shared helpers before the providers
  # that use them.
  'adapters/RebootDetection.ps1'
  'adapters/EnvironmentInfo.ps1'
  'adapters/SystemClock.ps1'
  'adapters/JsonStateStore.ps1'
  'adapters/ConsolePresenter.ps1'
  'adapters/EventLogEventSink.ps1'
  'adapters/Wua.OsUpdateProvider.ps1'
  'adapters/Winget.AppProvider.ps1'
  'adapters/Defender.SignatureProvider.ps1'
  'adapters/ManualTask.Provider.ps1'
  'adapters/Maintenance.Providers.ps1'
  'adapters/Backup.Provider.ps1'
  # Composition root.
  'composition/Registry.ps1'
)

foreach ($relative in $loadOrder)
{
  . (Join-Path $src $relative)
}

# Export every function. This is load-bearing, not laziness: the provider ports
# re closure records built with .GetNewClosure(), and such closures resolve
# unqualified function calls against the GLOBAL scope -- NOT this module's
# private scope. So every domain factory and helper a GetPlan/Apply closure
# calls (New-UpdatePlan, New-UpdateResult, the Get-*Problems checks, ...) must
# be exported, or the closure throws "X is not recognized" at run time.
# (Enums/value-object TYPES are still not importable by Import-Module; callers
# pass enum values as strings and read them via .ToString().)
Export-ModuleMember -Function '*'
