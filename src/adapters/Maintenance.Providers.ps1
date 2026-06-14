#requires -Version 7.4
#
# Alert-only maintenance providers (driven, Automated,
# Capabilities.AlertOnly = $true). They run silently - no progress/summary
# output - and are surfaced (to stdout, via Format-Alerts) only when their
# result Outcome is Failed. They are still recorded in the wide event like
# everything else.
#
# Each provider's risky LOGIC (count/parse decisions) is a PURE function,
# tested cross-platform; the impure system calls (event log, registry,
# w32tm) live in the closures.
# Depends on: ValueObjects.ps1, Ports.ps1.

# -----------------------------------------------------------------------------
# Pure decision/parse helpers (cross-platform testable)
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Providers (impure shell)
# -----------------------------------------------------------------------------

function New-MaintenanceTarget
{
  # Helper: an Automated target flagged AlertOnly (silent unless a problem).
  param([string] $Id, [string] $DisplayName)
  New-UpdateTarget -Id $Id -DisplayName $DisplayName -Kind 'Automated' -Capabilities @{ AlertOnly = $true }
}

function Get-EventHealthProblems
{
  # PURE: turn event counts (since the window) into problem messages ([] =
  # clean).
  [OutputType([string[]])]
  [CmdletBinding()]
  param([int] $Whea = 0, [int] $KernelPower41 = 0, [int] $DiskError = 0)
  $p = [System.Collections.Generic.List[string]]::new()
  if ($Whea -gt 0)
  {
    $p.Add("$Whea WHEA hardware error(s)")
  }
  if ($KernelPower41 -gt 0)
  {
    $p.Add("$KernelPower41 unexpected shutdown/reboot event(s) (Kernel-Power 41)")
  }
  if ($DiskError -gt 0)
  {
    $p.Add("$DiskError disk/filesystem error event(s)")
  }
  $p.ToArray()
}

function New-EventHealthProvider
{
  # Reviews the System log SINCE THE LAST RUN (ctx.LastRunAt; else the last
  # $FallbackDays) for WHEA hardware errors, Kernel-Power 41 (unexpected
  # reboots), and disk/filesystem errors.
  [CmdletBinding()]
  param([int] $FallbackDays = 7)
  $fallbackDays = [int]$FallbackDays
  $target = New-MaintenanceTarget -Id 'event-health' -DisplayName 'Critical event-log review'
  $getPlan = {
    param($ctx)
    New-UpdatePlan -Items @(New-UpdateItem -Id 'event-health' -Name 'Event-log review' -To 'scan')
  }.GetNewClosure()
  $apply = {
    param($ctx, $plan)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try
    {
      $since = ($null -ne $ctx.LastRunAt) `
        ? ([datetimeoffset]$ctx.LastRunAt).LocalDateTime `
        : (Get-Date).AddDays(-$fallbackDays)
      $whea = @(Get-WinEvent -ErrorAction SilentlyContinue -FilterHashtable @{
          LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $since
        }).Count
      $kp = @(Get-WinEvent -ErrorAction SilentlyContinue -FilterHashtable @{
          LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $since
        }).Count
      $disk = @(Get-WinEvent -ErrorAction SilentlyContinue -FilterHashtable @{
          LogName      = 'System'
          ProviderName = @('disk', 'Ntfs', 'volmgr', 'stornvme')
          Level        = @(1, 2)
          StartTime    = $since
        }).Count
      $problems = Get-EventHealthProblems -Whea $whea -KernelPower41 $kp -DiskError $disk
      $ms = $sw.ElapsedMilliseconds
      if (@($problems).Count -gt 0)
      {
        $msg = ($problems -join '; ') + " (since $($since.ToString('yyyy-MM-dd HH:mm')))"
        New-UpdateResult -Target $target -Outcome 'Failed' -ErrorMessage $msg -DurationMs $ms
      } else
      {
        New-UpdateResult -Target $target -Outcome 'Succeeded' -DurationMs $ms
      }
    } catch
    {
      $msg = "event-log review failed: $($_.Exception.Message)"
      New-UpdateResult -Target $target -Outcome 'Failed' -ErrorMessage $msg -DurationMs $sw.ElapsedMilliseconds
    }
  }.GetNewClosure()
  New-UpdateProviderPort -Target $target -GetPlan $getPlan -Apply $apply
}

function Get-NewEntries
{
  # PURE: identifiers present in Current but not in Baseline (i.e. additions
  # since last run).
  [OutputType([string[]])]
  [CmdletBinding()]
  param([string[]] $Current = @(), [string[]] $Baseline = @())
  $base = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Baseline))
  [string[]]@([string[]]@($Current) | Where-Object { -not $base.Contains($_) } | Sort-Object -Unique)
}

function Get-StartupEntrySet
{
  # IMPURE: current autostart identifiers - Run/RunOnce keys, Startup folders,
  # and non-Microsoft scheduled tasks (built-in \Microsoft\ tasks are excluded
  # to cut noise).
  [OutputType([string[]])]
  param()
  if (-not $IsWindows)
  {
    return @()
  }
  $set = [System.Collections.Generic.List[string]]::new()

  $runKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
  )
  foreach ($k in $runKeys)
  {
    try
    {
      $props = Get-ItemProperty -LiteralPath $k -ErrorAction Stop
      foreach ($name in ($props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' }).Name)
      {
        $set.Add("Run:$k\$name")
      }
    } catch
    {
      Write-Verbose "could not read run key ${k}: $_"
    }
  }
  foreach ($f in @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup')))
  {
    if ($f -and (Test-Path -LiteralPath $f))
    {
      foreach ($item in (Get-ChildItem -LiteralPath $f -File -ErrorAction SilentlyContinue))
      {
        $set.Add("StartupFolder:$($item.Name)")
      }
    }
  }
  try
  {
    foreach ($t in (Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskPath -notlike '\Microsoft\*' }))
    {
      $set.Add("Task:$($t.TaskPath)$($t.TaskName)")
    }
  } catch
  {
    Write-Verbose "scheduled-task enumeration failed: $_"
  }

  @($set | Sort-Object -Unique)
}

function New-StartupDriftProvider
{
  # Alerts on NEW autostart entries / scheduled tasks since the last run, by
  # diffing against a persisted baseline (which it refreshes each run). First
  # run just establishes the baseline.
  [CmdletBinding()]
  param(
    [string] $BaselinePath = (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) `
        'WindowsMaintenance' 'startup-baseline.json')
  )
  $path = $BaselinePath
  $target = New-MaintenanceTarget -Id 'startup-drift' -DisplayName 'Startup / scheduled-task drift'
  $getPlan = {
    param($ctx)
    New-UpdatePlan -Items @(New-UpdateItem -Id 'startup-drift' -Name 'Startup drift' -To 'check')
  }.GetNewClosure()
  $apply = {
    param($ctx, $plan)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try
    {
      $current = Get-StartupEntrySet
      $baseline = @()
      $haveBaseline = $false
      if (Test-Path -LiteralPath $path)
      {
        try
        {
          $baseline = @([string[]](Get-Content -LiteralPath $path -Raw | ConvertFrom-Json))
          $haveBaseline = $true
        } catch
        {
          $haveBaseline = $false
        }
      }
      # Refresh the baseline to the current snapshot (best-effort).
      try
      {
        $dir = Split-Path -Path $path -Parent
        if ($dir -and -not (Test-Path -LiteralPath $dir))
        {
          New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Set-Content -LiteralPath $path -Value ($current | ConvertTo-Json -AsArray) -Encoding utf8
      } catch
      {
        Write-Verbose "could not refresh startup baseline: $_"
      }

      $ms = $sw.ElapsedMilliseconds
      if (-not $haveBaseline)
      {
        # First run: baseline established, nothing to compare against yet.
        return New-UpdateResult -Target $target -Outcome 'Succeeded' -DurationMs $ms
      }
      $new = Get-NewEntries -Current $current -Baseline $baseline
      if (@($new).Count -gt 0)
      {
        $msg = 'new autostart/task: ' + ($new -join ', ')
        New-UpdateResult -Target $target -Outcome 'Failed' -ErrorMessage $msg -DurationMs $ms
      } else
      {
        New-UpdateResult -Target $target -Outcome 'Succeeded' -DurationMs $ms
      }
    } catch
    {
      $msg = "startup drift check failed: $($_.Exception.Message)"
      New-UpdateResult -Target $target -Outcome 'Failed' -ErrorMessage $msg -DurationMs $sw.ElapsedMilliseconds
    }
  }.GetNewClosure()
  New-UpdateProviderPort -Target $target -GetPlan $getPlan -Apply $apply
}

function Get-CrashProblems
{
  # PURE: dump count + bugcheck stop codes -> problem message ([] = no new
  # crashes).
  [OutputType([string[]])]
  [CmdletBinding()]
  param([int] $DumpCount = 0, [string[]] $StopCodes = @())
  $codes = @([string[]]@($StopCodes) | Where-Object { $_ } | Select-Object -Unique)
  $p = [System.Collections.Generic.List[string]]::new()
  if ($DumpCount -gt 0 -or $codes.Count -gt 0)
  {
    $msg = "$DumpCount new crash dump(s)"
    if ($codes.Count -gt 0)
    {
      $msg += " (stop code: $($codes -join ', '))"
    }
    $p.Add($msg)
  }
  $p.ToArray()
}

function New-CrashDumpProvider
{
  # Flags new BSOD minidumps (and the bugcheck stop code) since the last run.
  [CmdletBinding()]
  param([int] $FallbackDays = 7)
  $fallbackDays = [int]$FallbackDays
  $target = New-MaintenanceTarget -Id 'crash-dumps' -DisplayName 'Crash dumps (BSOD)'
  $getPlan = {
    param($ctx)
    New-UpdatePlan -Items @(New-UpdateItem -Id 'crash-dumps' -Name 'Crash dumps' -To 'check')
  }.GetNewClosure()
  $apply = {
    param($ctx, $plan)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try
    {
      $since = ($null -ne $ctx.LastRunAt) `
        ? ([datetimeoffset]$ctx.LastRunAt).LocalDateTime `
        : (Get-Date).AddDays(-$fallbackDays)
      $dumpArgs = @{
        LiteralPath = "$env:SystemRoot\Minidump"
        Filter      = '*.dmp'
        ErrorAction = 'SilentlyContinue'
      }
      $dumps = @(Get-ChildItem @dumpArgs | Where-Object { $_.LastWriteTime -ge $since })
      $full = @(Get-Item -LiteralPath "$env:SystemRoot\MEMORY.DMP" -ErrorAction SilentlyContinue |
          Where-Object { $_.LastWriteTime -ge $since })
      $bugchecks = @(Get-WinEvent -ErrorAction SilentlyContinue -FilterHashtable @{
          LogName      = 'System'
          ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'
          Id           = 1001
          StartTime    = $since
        })
      $codes = @($bugchecks | ForEach-Object { if ($_.Message -match '0x[0-9A-Fa-f]{6,}')
          {
            $matches[0]
          } })
      $problems = Get-CrashProblems -DumpCount ($dumps.Count + $full.Count) -StopCodes $codes
      $ms = $sw.ElapsedMilliseconds
      if (@($problems).Count -gt 0)
      {
        $msg = ($problems -join '; ') + " (since $($since.ToString('yyyy-MM-dd HH:mm')))"
        New-UpdateResult -Target $target -Outcome 'Failed' -ErrorMessage $msg -DurationMs $ms
      } else
      {
        New-UpdateResult -Target $target -Outcome 'Succeeded' -DurationMs $ms
      }
    } catch
    {
      $msg = "crash-dump check failed: $($_.Exception.Message)"
      New-UpdateResult -Target $target -Outcome 'Failed' -ErrorMessage $msg -DurationMs $sw.ElapsedMilliseconds
    }
  }.GetNewClosure()
  New-UpdateProviderPort -Target $target -GetPlan $getPlan -Apply $apply
}

function Get-TimeSyncProblems
{
  # PURE: decide time-sync health from probed facts ([] = healthy).
  [OutputType([string[]])]
  [CmdletBinding()]
  param(
    [bool]   $ServiceRunning,
    [string] $Source = '',
    [bool]   $Synced = $false,
    [double] $SyncAgeHours = 0,
    [int]    $MaxAgeHours = 48
  )
  $p = [System.Collections.Generic.List[string]]::new()
  if (-not $ServiceRunning)
  {
    $p.Add('Windows Time service (w32time) is not running')
  } elseif (-not $Synced)
  {
    $p.Add('the clock has never successfully synced')
  } elseif ($SyncAgeHours -gt $MaxAgeHours)
  {
    $p.Add("last clock sync was ~$([int]$SyncAgeHours)h ago")
  }
  if ($Source -and ($Source -match 'Local CMOS Clock'))
  {
    $p.Add('time source is the local CMOS clock (not syncing from NTP)')
  }
  $p.ToArray()
}

function New-TimeSyncProvider
{
  # Warns if the system clock isn't being kept in sync (w32time stopped, never
  # synced, stale, or falling back to the local CMOS clock).
  [CmdletBinding()]
  param([int] $MaxSyncAgeHours = 48)
  $maxAge = [int]$MaxSyncAgeHours
  $target = New-MaintenanceTarget -Id 'time-sync' -DisplayName 'System clock sync'
  $getPlan = {
    param($ctx)
    New-UpdatePlan -Items @(New-UpdateItem -Id 'time-sync' -Name 'System clock sync' -To 'check')
  }.GetNewClosure()
  $apply = {
    param($ctx, $plan)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try
    {
      $svc     = Get-Service -Name 'w32time' -ErrorAction SilentlyContinue
      $running = [bool]($svc -and $svc.Status -eq 'Running')
      $status  = (& "$env:SystemRoot\System32\w32tm.exe" /query /status 2>&1 | Out-String)
      $source  = ($status -match 'Source:\s*(.+)') ? $matches[1].Trim() : ''
      $synced  = $false; $ageH = 0.0
      if ($status -match 'Last Successful Sync Time:\s*(.+)')
      {
        $lastTxt = $matches[1].Trim()
        if ($lastTxt -and $lastTxt -ne 'unspecified')
        {
          $synced = $true
          try
          {
            $ageH = ((Get-Date) - [datetime]::Parse($lastTxt)).TotalHours
          } catch
          {
            $ageH = 0
          }
        }
      }
      $problems = Get-TimeSyncProblems -ServiceRunning $running -Source $source -Synced $synced `
        -SyncAgeHours $ageH -MaxAgeHours $maxAge
      $ms = $sw.ElapsedMilliseconds
      if (@($problems).Count -gt 0)
      {
        $msg = $problems -join '; '
        New-UpdateResult -Target $target -Outcome 'Failed' -ErrorMessage $msg -DurationMs $ms
      } else
      {
        New-UpdateResult -Target $target -Outcome 'Succeeded' -DurationMs $ms
      }
    } catch
    {
      $msg = "time-sync check failed: $($_.Exception.Message)"
      New-UpdateResult -Target $target -Outcome 'Failed' -ErrorMessage $msg -DurationMs $sw.ElapsedMilliseconds
    }
  }.GetNewClosure()
  New-UpdateProviderPort -Target $target -GetPlan $getPlan -Apply $apply
}
