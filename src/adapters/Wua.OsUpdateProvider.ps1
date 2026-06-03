#requires -Version 7.4
#
# Windows OS update provider (driven, Automated) - the default OS-update path
# via the Windows Update Agent COM API (Microsoft.Update.Session). Zero
# external dependency, deterministic result codes, authoritative reboot signal.
# All COM lives in functions (never class methods) to avoid the
# [ref]-fails-silently-on-class-members trap.
#
# Search needs no elevation; download/install do - the composition root gates
# on that.
# Policy: install everything Windows Update offers EXCEPT drivers (those are
# managed separately / blocked by AtlasOS). Optional & preview quality/feature
# updates are NOT filtered out. -IncludeDrivers opts driver updates back in.
# Depends on: ValueObjects.ps1, Ports.ps1, RebootDetection.ps1.

function Get-WuaSearchCriteria
{
  # PURE: build the WUA search string. Drivers are excluded via Type='Software'
  # (reliable); optional/preview updates are deliberately NOT filtered out (the
  # BrowseOnly criterion is documented as unreliable, and the intent is
  # "everything WU offers, minus drivers").
  [OutputType([string])]
  [CmdletBinding()]
  param([bool] $IncludeDrivers)
  $IncludeDrivers ? "IsInstalled=0 and IsHidden=0" : "IsInstalled=0 and IsHidden=0 and Type='Software'"
}

function New-WuaOsUpdateProvider
{
  [CmdletBinding()]
  param([switch] $IncludeDrivers)

  $includeDrivers = [bool]$IncludeDrivers
  # The searched COM collection is cached between GetPlan and Apply (same
  # invocation).
  $state  = @{ Updates = $null }
  $target = New-UpdateTarget -Id 'windows-update' -DisplayName 'Windows Update' -Kind 'Automated'

  $getPlan = {
    param($ctx)
    $session  = New-Object -ComObject 'Microsoft.Update.Session'
    $searcher = $session.CreateUpdateSearcher()
    $found    = $searcher.Search((Get-WuaSearchCriteria -IncludeDrivers $includeDrivers))
    $state.Updates = $found.Updates

    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($u in $found.Updates)
    {
      $id = [string]$u.Identity.UpdateID
      $title = [string]$u.Title
      $items.Add((New-UpdateItem -Id $id -Name $title -To $title))
    }
    New-UpdatePlan -Items $items.ToArray()
  }.GetNewClosure()

  $apply = {
    param($ctx, $plan)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    if ($null -eq $state.Updates -or $state.Updates.Count -eq 0)
    {
      return New-UpdateResult -Target $target -Outcome 'NothingToDo' -DurationMs $sw.ElapsedMilliseconds
    }

    $session   = New-Object -ComObject 'Microsoft.Update.Session'
    $toInstall = New-Object -ComObject 'Microsoft.Update.UpdateColl'
    foreach ($u in $state.Updates)
    {
      if (-not $u.EulaAccepted)
      {
        $u.AcceptEula()
      }
      [void]$toInstall.Add($u)
    }

    $downloader = $session.CreateUpdateDownloader()
    $downloader.Updates = $toInstall
    [void]$downloader.Download()

    $installer = $session.CreateUpdateInstaller()
    $installer.Updates = $toInstall
    $installResult = $installer.Install()

    $applied = [System.Collections.Generic.List[object]]::new()
    $failed  = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $toInstall.Count; $i++)
    {
      $u    = $toInstall.Item($i)
      $code = $installResult.GetUpdateResult($i).ResultCode   # 2 Succeeded, 3 SucceededWithErrors
      $item = New-UpdateItem -Id ([string]$u.Identity.UpdateID) -Name ([string]$u.Title) -To ([string]$u.Title)
      if ($code -eq 2 -or $code -eq 3)
      {
        $applied.Add($item)
      } else
      {
        $failed.Add($item)
      }
    }

    # Per the lattice, any failure makes the target Failed (partial successes
    # are still recorded).
    $outcome =
    if ($failed.Count -gt 0)
    {
      'Failed'
    } elseif ($applied.Count -gt 0)
    {
      'Succeeded'
    } else
    {
      'Failed'
    }   # install ran but nothing applied => something went wrong

    $reboot = [bool]$installResult.RebootRequired -or (Test-RebootPending)
    New-UpdateResult -Target $target -Outcome $outcome `
      -ItemsApplied $applied.ToArray() -ItemsFailed $failed.ToArray() `
      -RebootRequired $reboot -DurationMs $sw.ElapsedMilliseconds
  }.GetNewClosure()

  New-UpdateProviderPort -Target $target -GetPlan $getPlan -Apply $apply
}
