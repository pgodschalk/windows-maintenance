#requires -Version 7.4
#
# Config-driven manual-task provider (driven, ManualAdvisory). Each configured
# task - a name plus an OPTIONAL url - becomes a ManualAdvisory target that the
# tool cannot action itself but surfaces in the end-of-run "check these
# manually" block.
#
# Config shape (see manual-tasks.schema.json):
#   { "$schema": "...", "manualTasks": [
#     { "name": "Microsoft Store" },
#     { "name": "MSI X670E BIOS", "url": "https://..." }
#   ] }
# Depends on: ValueObjects.ps1, Ports.ps1.

function ConvertFrom-ManualTaskConfig
{
  # PURE: parse the manual-tasks JSON text into {Name, Url} records. Items
  # without a non-empty name are skipped; url is optional (null when absent).
  # Throws on malformed JSON (the caller decides how to degrade).
  [OutputType([object[]])]
  [CmdletBinding()]
  param([string] $Json)

  if ([string]::IsNullOrWhiteSpace($Json))
  {
    return @()
  }
  $parsed = $Json | ConvertFrom-Json -ErrorAction Stop

  $tasks = [System.Collections.Generic.List[object]]::new()
  foreach ($item in @($parsed.manualTasks))
  {
    if ($null -eq $item -or [string]::IsNullOrWhiteSpace([string]$item.name))
    {
      continue
    }
    $url      = ($item.PSObject.Properties.Name -contains 'url')      ? [string]$item.url      : $null
    $category = ($item.PSObject.Properties.Name -contains 'category') ? [string]$item.category : $null
    $tasks.Add([pscustomobject]@{
        Name     = [string]$item.name
        Url      = [string]::IsNullOrWhiteSpace($url) ? $null : $url
        Category = [string]::IsNullOrWhiteSpace($category) ? 'Other' : $category
      })
  }
  $tasks.ToArray()
}

function Get-ManualTaskConfig
{
  # IMPURE: read and parse the manual-tasks config file. Resilient - a missing
  # file yields no tasks, and an unreadable/invalid file degrades to no tasks
  # (manual reminders must never block or crash a run). Returns an array of
  # {Name, Url}.
  [OutputType([object[]])]
  [CmdletBinding()]
  param([Parameter(Mandatory)][string] $Path)

  if (-not (Test-Path -LiteralPath $Path))
  {
    return [object[]]@()
  }
  try
  {
    $json = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    [object[]]@(ConvertFrom-ManualTaskConfig -Json $json)
  } catch
  {
    Write-Warning "Manual-tasks config at '$Path' could not be read: $($_.Exception.Message)"
    [object[]]@()
  }
}

function New-ManualTaskProvider
{
  # Build a ManualAdvisory provider for one configured task.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string] $Name,
    [string] $Url,
    [string] $Category = 'Other'
  )
  $slug   = ($Name.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
  $id     = "manual:$slug"
  $target = New-UpdateTarget -Id $id -DisplayName $Name -Kind 'ManualAdvisory'
  $advisory = New-ManualAdvisory -Id $id -Name $Name -Category $Category -Link $Url

  $getPlan = { param($ctx) New-UpdatePlan -Advisory $advisory }.GetNewClosure()
  # Never invoked for a ManualAdvisory target (the orchestrator short-circuits
  # on ManualOnly), but the port shape requires it.
  $apply = {
    param($ctx, $plan)
    New-UpdateResult -Target $target -Outcome 'ManualActionRequired' -Advisory $plan.Advisory
  }.GetNewClosure()

  New-UpdateProviderPort -Target $target -GetPlan $getPlan -Apply $apply
}
