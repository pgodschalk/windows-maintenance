#requires -Version 7.4
#
# Application update provider (driven, Automated). Two modes:
#   * "upgrade everything" (default, -All): discover every upgradable package
#      via `winget upgrade` and upgrade each by --id (so the wide event gets
#      real from->to deltas).
#   * curated (-PackageId <ids>): upgrade only the listed IDs.
# -ExcludeId pins/holds packages back in either mode.
#
# winget is driven per-package by --id --exact and branched on EXIT CODE;
# `winget upgrade` has no usable JSON, so discovery parses its table. The
# parser is pure + locale-robust (keys off the dashed separator and column
# POSITIONS, not localized header text).
# Depends on: ValueObjects.ps1, Ports.ps1.

function ConvertFrom-WingetExitCode
{
  # PURE: map a winget process exit code to an intent. Normalises the (possibly
  # negative, signed) int in $LASTEXITCODE to the documented unsigned code.
  [CmdletBinding()]
  param([Parameter(Mandatory)][long] $Code)

  # The case literals MUST carry the L (Int64) suffix: bare 0x8A15002B parses
  # as a NEGATIVE Int32, which never equals the POSITIVE Int64 $u, so every
  # code would fall through to Failed.
  $u = $Code -band 0xFFFFFFFFL
  switch ($u)
  {
    0x0L
    {
      [pscustomobject]@{ Status = 'Applied'; Reboot = $false }
    }  # success
    0x8A15002BL
    {
      [pscustomobject]@{ Status = 'NoOp'; Reboot = $false }
    }  # no applicable update
    0x8A150109L
    {
      [pscustomobject]@{ Status = 'Applied'; Reboot = $true }
    }   # reboot required
    0x8A15010AL
    {
      [pscustomobject]@{ Status = 'Applied'; Reboot = $true }
    }   # reboot required to finish
    0x8A15010BL
    {
      [pscustomobject]@{ Status = 'Applied'; Reboot = $true }
    }   # restart then retry
    default
    {
      [pscustomobject]@{ Status = 'Failed'; Reboot = $false }
    }
  }
}

function Format-WingetFailures
{
  # PURE: summarise failed winget upgrades into one error string -- per package,
  # its id, the normalised unsigned hex exit code, and (when present) winget's
  # own last output line. This is what populates the wide event's `error`;
  # without it a non-zero winget exit was reported as a silent Failed.
  [OutputType([string])]
  [CmdletBinding()]
  param([Parameter(Mandatory)][object[]] $Failures)
  $parts = [System.Collections.Generic.List[string]]::new()
  foreach ($f in $Failures)
  {
    $hex    = '0x{0:X8}' -f ([long]$f.Code -band 0xFFFFFFFFL)
    $detail = $f.Detail ? " -- $($f.Detail)" : ''
    $parts.Add("$($f.Id): winget exited $hex$detail")
  }
  $parts -join '; '
}

function Get-WingetColumnStart
{
  # PURE: column start indices = positions in the header where a non-space
  # follows a space.
  [OutputType([int[]])]
  [CmdletBinding()]
  param([Parameter(Mandatory)][string] $Header)
  $starts = [System.Collections.Generic.List[int]]::new()
  for ($i = 0; $i -lt $Header.Length; $i++)
  {
    if ($Header[$i] -ne ' ' -and ($i -eq 0 -or $Header[$i - 1] -eq ' '))
    {
      $starts.Add($i)
    }
  }
  $starts.ToArray()
}

function Get-WingetField
{
  # PURE: slice column $Index out of a fixed-width row using the header column
  # starts.
  [OutputType([string])]
  [CmdletBinding()]
  param([string] $Line, [int[]] $Starts, [int] $Index)
  $from = $Starts[$Index]
  if ($from -ge $Line.Length)
  {
    return ''
  }
  $to = ($Index + 1 -lt $Starts.Count) ? $Starts[$Index + 1] : $Line.Length
  if ($to -gt $Line.Length)
  {
    $to = $Line.Length
  }
  $Line.Substring($from, $to - $from).Trim()
}

function ConvertFrom-WingetUpgradeTable
{
  # PURE: parse `winget upgrade` table output into {Id,Name,Version,Available}
  # descriptors. Locale-robust: finds the dashed/box separator, reads the
  # header line above it, derives column boundaries from the header's
  # whitespace, and maps by POSITION (col 1 = Id, 2 = Version, 3 = Available).
  # winget localises the labels but not the column order. Handles multiple
  # table sections (e.g. the "explicit targeting" group).
  [CmdletBinding()]
  param([string[]] $Output)

  $rows   = [System.Collections.Generic.List[object]]::new()
  $lines  = @($Output)
  $starts = $null   # non-null => currently inside a table body

  for ($i = 0; $i -lt $lines.Count; $i++)
  {
    $line    = ([string]$lines[$i]) -replace "`r", ''
    $trimmed = $line.Trim()

    # A separator line: only punctuation/symbols (ASCII dashes or box-drawing),
    # length >= 4.
    if ($trimmed.Length -ge 4 -and $trimmed -match '^[\p{P}\p{S}]+$')
    {
      $header = $null
      for ($j = $i - 1; $j -ge 0; $j--)
      {
        $h = ([string]$lines[$j]) -replace "`r", ''
        if (-not [string]::IsNullOrWhiteSpace($h))
        {
          $header = $h; break
        }
      }
      $starts = $header ? (Get-WingetColumnStart -Header $header) : $null
      continue
    }

    if ($null -eq $starts)
    {
      continue
    }                                    # not in a table body
    if ([string]::IsNullOrWhiteSpace($line))
    {
      $starts = $null; continue
    } # blank ends the body
    if ($starts.Count -lt 4 -or $line.Length -lt $starts[1])
    {
      continue
    }  # too short to be a row

    $id = Get-WingetField -Line $line -Starts $starts -Index 1
    if (-not [string]::IsNullOrWhiteSpace($id))
    {
      $rows.Add([pscustomobject]@{
          Id        = $id
          Name      = Get-WingetField -Line $line -Starts $starts -Index 0
          Version   = Get-WingetField -Line $line -Starts $starts -Index 2
          Available = Get-WingetField -Line $line -Starts $starts -Index 3
        })
    }
  }
  $rows.ToArray()
}

function Resolve-WingetPath
{
  # winget can be unresolvable under SYSTEM / non-interactive sessions; fall
  # back to its full path under WindowsApps.
  [OutputType([string])]
  param()
  $cmd = Get-Command winget -CommandType Application -ErrorAction SilentlyContinue
  if ($cmd)
  {
    return $cmd.Source
  }
  $candidate = Get-ChildItem -Path "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*\winget.exe" `
    -ErrorAction SilentlyContinue | Select-Object -First 1
  $candidate ? $candidate.FullName : $null
}

function Get-WingetUpgradable
{
  # IMPURE: list upgradable packages via winget, then parse them. Returns
  # descriptors.
  [CmdletBinding()]
  param([Parameter(Mandatory)][string] $WingetPath)
  $raw  = & $WingetPath upgrade --include-unknown --disable-interactivity --accept-source-agreements 2>&1
  $text = $raw | Out-String
  ConvertFrom-WingetUpgradeTable -Output ($text -split "`n")
}

function New-WingetAppProvider
{
  [CmdletBinding()]
  param(
    [string[]] $PackageId = @(),   # curated allow-list (when not -All)
    [switch]   $All,               # upgrade everything winget reports
    [string[]] $ExcludeId = @(),   # pin/hold: skip these IDs in either mode
    [switch]   $MachineScope
  )

  $target  = New-UpdateTarget -Id 'winget' -DisplayName 'Winget Applications' -Kind 'Automated'
  $ids     = [string[]]@($PackageId)
  $exclude = [string[]]@($ExcludeId)
  $all     = [bool]$All
  $scope   = [bool]$MachineScope

  # Discovery decides the item set; Apply is mode-agnostic (it upgrades each
  # plan item by ID).
  $getPlan = {
    param($ctx)
    $winget = Resolve-WingetPath
    if (-not $winget)
    {
      return New-UpdatePlan
    }   # can't discover -> NothingToDo

    $items = [System.Collections.Generic.List[object]]::new()
    if ($all)
    {
      foreach ($pkg in (Get-WingetUpgradable -WingetPath $winget))
      {
        if ($exclude -contains $pkg.Id)
        {
          continue
        }
        $name = [string]::IsNullOrWhiteSpace($pkg.Name) ? $pkg.Id : $pkg.Name
        $items.Add((New-UpdateItem -Id $pkg.Id -Name $name -From $pkg.Version -To $pkg.Available))
      }
    } else
    {
      foreach ($id in $ids)
      {
        if ($exclude -contains $id)
        {
          continue
        }
        $items.Add((New-UpdateItem -Id $id -Name $id -To 'latest'))
      }
    }
    New-UpdatePlan -Items $items.ToArray()
  }.GetNewClosure()

  $apply = {
    param($ctx, $plan)
    $sw     = [System.Diagnostics.Stopwatch]::StartNew()
    $winget = Resolve-WingetPath
    if (-not $winget)
    {
      return New-UpdateResult -Target $target -Outcome 'Failed' `
        -ErrorMessage 'winget (App Installer) was not found on this system.' -DurationMs $sw.ElapsedMilliseconds
    }

    $applied  = [System.Collections.Generic.List[object]]::new()
    $failed   = [System.Collections.Generic.List[object]]::new()
    $failures = [System.Collections.Generic.List[object]]::new()
    $reboot   = $false

    foreach ($item in $plan.Items)
    {
      $argv = @('upgrade', '--id', $item.Id, '--exact', '--silent',
        '--accept-source-agreements', '--accept-package-agreements',
        '--include-unknown', '--disable-interactivity')
      if ($scope)
      {
        $argv += @('--scope', 'machine')
      }

      # Capture winget's output (2>&1) instead of discarding it (*> $null), so a
      # non-zero exit is reported with its code + message, never silently.
      $out  = & $winget @argv 2>&1
      $code = [long]$LASTEXITCODE
      $res  = ConvertFrom-WingetExitCode -Code $code
      switch ($res.Status)
      {
        'Applied'
        {
          $applied.Add($item); if ($res.Reboot)
          {
            $reboot = $true
          }
        }
        'Failed'
        {
          $failed.Add($item)
          $lines  = @($out | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
          $detail = $lines ? $lines[-1] : ''
          $failures.Add([pscustomobject]@{ Id = $item.Id; Code = $code; Detail = $detail })
        }
        'NoOp'
        {
        }   # already current
      }
    }

    $outcome =
    if ($failed.Count -gt 0)
    {
      'Failed'
    } elseif ($applied.Count -gt 0)
    {
      'Succeeded'
    } else
    {
      'NothingToDo'
    }

    $resultArgs = @{
      Target         = $target
      Outcome        = $outcome
      ItemsApplied   = $applied.ToArray()
      ItemsFailed    = $failed.ToArray()
      RebootRequired = $reboot
      DurationMs     = $sw.ElapsedMilliseconds
    }
    if ($failures.Count -gt 0)
    {
      $resultArgs.ErrorMessage = Format-WingetFailures -Failures $failures.ToArray()
    }
    New-UpdateResult @resultArgs
  }.GetNewClosure()

  New-UpdateProviderPort -Target $target -GetPlan $getPlan -Apply $apply
}
