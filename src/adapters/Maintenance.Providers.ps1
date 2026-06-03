#requires -Version 7.4
#
# Alert-only maintenance providers (driven, Automated,
# Capabilities.AlertOnly = $true). They run silently - no progress/summary
# output - and are surfaced (to stdout, via Format-Alerts) only when their
# result Outcome is Failed. They are still recorded in the wide event like
# everything else.
#
# Each provider's risky LOGIC (health/threshold/parse decisions) is a PURE
# function, tested cross-platform; the impure system calls (CIM, cleanmgr,
# sfc/DISM, Defender) live in the closures.
# Depends on: ValueObjects.ps1, Ports.ps1.

# -----------------------------------------------------------------------------
# Pure decision/parse helpers (cross-platform testable)
# -----------------------------------------------------------------------------

function Get-StorageHealthProblems
{
  # PURE: given disk descriptors, return human-readable problem strings ([] =
  # all healthy).
  [OutputType([string[]])]
  [CmdletBinding()]
  param([object[]] $Disks = @())
  $problems = [System.Collections.Generic.List[string]]::new()
  foreach ($d in @($Disks))
  {
    if ($d.HealthStatus -and "$($d.HealthStatus)" -ne 'Healthy')
    {
      $problems.Add("$($d.Name): health is '$($d.HealthStatus)'")
    }
    if ($d.OperationalStatus -and "$($d.OperationalStatus)" -notin @('OK', 'Online'))
    {
      $problems.Add("$($d.Name): operational status '$($d.OperationalStatus)'")
    }
    if ($null -ne $d.WearPercent -and [int]$d.WearPercent -ge 90)
    {
      $problems.Add("$($d.Name): wear at $($d.WearPercent)%")
    }
  }
  $problems.ToArray()
}

function Get-LowFreeSpaceDrives
{
  # PURE: fixed drives below MinFreePercent. Returns { Drive; FreePercent }
  # records.
  [CmdletBinding()]
  param([object[]] $Volumes = @(), [int] $MinFreePercent = 20)
  $low = [System.Collections.Generic.List[object]]::new()
  foreach ($v in @($Volumes))
  {
    if ([long]$v.SizeBytes -le 0)
    {
      continue
    }
    $freePct = [math]::Round(([long]$v.FreeBytes / [long]$v.SizeBytes) * 100, 1)
    if ($freePct -lt $MinFreePercent)
    {
      $low.Add([pscustomobject]@{ Drive = $v.Drive; FreePercent = $freePct })
    }
  }
  $low.ToArray()
}

function Get-SafeCleanupHandlers
{
  # PURE: the Disk Cleanup (cleanmgr) handler keys we ENABLE. Deliberately
  # omits anything that touches user data: 'DirectX Shader Cache',
  # 'DownloadsFolder' and 'Recycle Bin'. VolumeCaches subkey names are fixed
  # English identifiers regardless of locale, so matching by name is safe.
  [OutputType([string[]])]
  param()
  @(
    'Temporary Files'
    'Temporary Setup Files'
    'Setup Log Files'
    'Update Cleanup'
    'Windows Update Cleanup'
    'Delivery Optimization Files'
    'Downloaded Program Files'
    'Temporary Internet Files'
    'Thumbnail Cache'
    'Thumbnails'
    'System error memory dump files'
    'System error minidump files'
    'Windows Error Reporting Files'
    'Windows Error Reporting System Archive Files'
    'Windows Error Reporting System Queue Files'
    'Windows Error Reporting Temp Files'
    'Old ChkDsk Files'
    'Windows Upgrade Log Files'
  )
}

function Test-CleanupHandlerEnabled
{
  # PURE: should this cleanmgr handler be selected? (Allowlist membership;
  # shader cache etc. excluded.)
  [OutputType([bool])]
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string] $Name,
    [string[]] $Allowlist = (Get-SafeCleanupHandlers)
  )
  $Name -in $Allowlist
}

function Get-IntegrityStatus
{
  # PURE: classify `sfc /scannow` output. (SFC emits UTF-16 with interleaved
  # nulls when captured, so strip them first.) -> Clean | Repaired |
  # Unrepairable | Unknown.
  [OutputType([string])]
  [CmdletBinding()]
  param([string] $SfcOutput)
  $t = ([string]$SfcOutput) -replace "`0", ''
  if ($t -match 'did not find any integrity violations')
  {
    return 'Clean'
  }
  if ($t -match 'unable to fix some')
  {
    return 'Unrepairable'
  }
  if ($t -match 'found corrupt files and successfully repaired')
  {
    return 'Repaired'
  }
  'Unknown'
}

function Test-DefenderClean
{
  # PURE: clean when there are no active threats.
  [OutputType([bool])]
  [CmdletBinding()]
  param([object[]] $ActiveThreats = @())
  @($ActiveThreats).Count -eq 0
}

# -----------------------------------------------------------------------------
# Providers (impure shell)
# -----------------------------------------------------------------------------

function New-MaintenanceTarget
{
  # Helper: an Automated target flagged AlertOnly (silent unless a problem).
  # -LongRunning marks the slow checks (SFC/DISM, full scan) so the use case
  # can announce when they start -- they would otherwise look hung.
  param([string] $Id, [string] $DisplayName, [switch] $LongRunning)
  $caps = @{ AlertOnly = $true }
  if ($LongRunning)
  {
    $caps.LongRunning = $true
  }
  New-UpdateTarget -Id $Id -DisplayName $DisplayName -Kind 'Automated' -Capabilities $caps
}

function New-StorageHealthProvider
{
  [CmdletBinding()]
  param()
  $target = New-MaintenanceTarget -Id 'storage-health' -DisplayName 'Storage health (SMART)'
  $getPlan = {
    param($ctx)
    New-UpdatePlan -Items @(New-UpdateItem -Id 'storage-health' -Name 'Storage health' -To 'check')
  }.GetNewClosure()
  $apply = {
    param($ctx, $plan)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try
    {
      $disks = foreach ($pd in (Get-PhysicalDisk -ErrorAction Stop))
      {
        $wear = $null
        try
        {
          $wear = [int]($pd | Get-StorageReliabilityCounter -ErrorAction Stop).Wear
        } catch
        {
          Write-Verbose "no wear counter for $($pd.FriendlyName): $_"
        }
        [pscustomobject]@{
          Name              = [string]$pd.FriendlyName
          HealthStatus      = [string]$pd.HealthStatus
          OperationalStatus = [string]$pd.OperationalStatus
          WearPercent       = $wear
        }
      }
      $problems = Get-StorageHealthProblems -Disks @($disks)
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
      $msg = "storage health check failed: $($_.Exception.Message)"
      New-UpdateResult -Target $target -Outcome 'Failed' -ErrorMessage $msg -DurationMs $sw.ElapsedMilliseconds
    }
  }.GetNewClosure()
  New-UpdateProviderPort -Target $target -GetPlan $getPlan -Apply $apply
}

function New-FreeSpaceProvider
{
  # MinFreePercent default 20 - keeps the Crucial T700's dynamic SLC cache
  # (~11% of capacity) plus GC/TRIM headroom; tune to taste.
  [CmdletBinding()]
  param([int] $MinFreePercent = 20)
  $min = [int]$MinFreePercent
  $target = New-MaintenanceTarget -Id 'free-space' -DisplayName 'Free disk space'
  $getPlan = {
    param($ctx)
    New-UpdatePlan -Items @(New-UpdateItem -Id 'free-space' -Name 'Free disk space' -To 'check')
  }.GetNewClosure()
  $apply = {
    param($ctx, $plan)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try
    {
      $fixed = Get-Volume -ErrorAction Stop |
        Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter }
      $vols = foreach ($v in $fixed)
      {
        [pscustomobject]@{
          Drive     = "$($v.DriveLetter):"
          SizeBytes = [long]$v.Size
          FreeBytes = [long]$v.SizeRemaining
        }
      }
      $low = Get-LowFreeSpaceDrives -Volumes @($vols) -MinFreePercent $min
      $ms = $sw.ElapsedMilliseconds
      if (@($low).Count -gt 0)
      {
        $detail = (@($low) | ForEach-Object { "$($_.Drive) $($_.FreePercent)% free" }) -join '; '
        $msg = "$detail (recommend >= $min% for sustained SSD performance)"
        New-UpdateResult -Target $target -Outcome 'Failed' -ErrorMessage $msg -DurationMs $ms
      } else
      {
        New-UpdateResult -Target $target -Outcome 'Succeeded' -DurationMs $ms
      }
    } catch
    {
      $msg = "free-space check failed: $($_.Exception.Message)"
      New-UpdateResult -Target $target -Outcome 'Failed' -ErrorMessage $msg -DurationMs $sw.ElapsedMilliseconds
    }
  }.GetNewClosure()
  New-UpdateProviderPort -Target $target -GetPlan $getPlan -Apply $apply
}

function New-DiskCleanupProvider
{
  # Runs Windows Disk Cleanup via a dedicated sageset profile, selecting only
  # the safe allowlist (NOT DirectX Shader Cache / Downloads / Recycle Bin).
  # Silent unless cleanmgr errors.
  [CmdletBinding()]
  param([int] $SagesetProfile = 99)
  $profileId = [int]$SagesetProfile
  $target = New-MaintenanceTarget -Id 'disk-cleanup' -DisplayName 'Disk Cleanup'
  $getPlan = {
    param($ctx)
    New-UpdatePlan -Items @(New-UpdateItem -Id 'disk-cleanup' -Name 'Disk Cleanup' -To 'run')
  }.GetNewClosure()
  $apply = {
    param($ctx, $plan)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try
    {
      $base = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
      $flag = 'StateFlags{0:D4}' -f $profileId
      foreach ($key in (Get-ChildItem -LiteralPath $base -ErrorAction Stop))
      {
        $name  = Split-Path -Path $key.Name -Leaf
        $value = (Test-CleanupHandlerEnabled -Name $name) ? 2 : 0
        New-ItemProperty -LiteralPath $key.PSPath -Name $flag -PropertyType DWord -Value $value -Force |
          Out-Null
      }
      $proc = Start-Process -FilePath "$env:SystemRoot\System32\cleanmgr.exe" `
        -ArgumentList "/sagerun:$profileId" -Wait -PassThru -WindowStyle Hidden
      $ms = $sw.ElapsedMilliseconds
      if ($proc.ExitCode -ne 0)
      {
        $msg = "cleanmgr exited with code $($proc.ExitCode)"
        New-UpdateResult -Target $target -Outcome 'Failed' -ErrorMessage $msg -DurationMs $ms
      } else
      {
        New-UpdateResult -Target $target -Outcome 'Succeeded' -DurationMs $ms
      }
    } catch
    {
      $msg = "disk cleanup failed: $($_.Exception.Message)"
      New-UpdateResult -Target $target -Outcome 'Failed' -ErrorMessage $msg -DurationMs $sw.ElapsedMilliseconds
    }
  }.GetNewClosure()
  New-UpdateProviderPort -Target $target -GetPlan $getPlan -Apply $apply
}

function New-SystemIntegrityProvider
{
  # DISM /RestoreHealth then sfc /scannow. Alerts if SFC found corruption
  # (repaired or not).
  [CmdletBinding()]
  param()
  $target = New-MaintenanceTarget -Id 'system-integrity' -DisplayName 'System integrity (SFC/DISM)' -LongRunning
  $getPlan = {
    param($ctx)
    New-UpdatePlan -Items @(New-UpdateItem -Id 'system-integrity' -Name 'System integrity' -To 'scan')
  }.GetNewClosure()
  $apply = {
    param($ctx, $plan)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try
    {
      $dism = Start-Process -FilePath "$env:SystemRoot\System32\Dism.exe" `
        -ArgumentList '/Online', '/Cleanup-Image', '/RestoreHealth' -Wait -PassThru -WindowStyle Hidden
      $sfcRaw = (& "$env:SystemRoot\System32\sfc.exe" /scannow 2>&1 | Out-String)
      $ms = $sw.ElapsedMilliseconds
      switch (Get-IntegrityStatus -SfcOutput $sfcRaw)
      {
        'Clean'
        {
          New-UpdateResult -Target $target -Outcome 'Succeeded' -DurationMs $ms
        }
        'Repaired'
        {
          $msg = 'SFC found and repaired corrupt system files (see CBS.log).'
          New-UpdateResult -Target $target -Outcome 'Failed' -ErrorMessage $msg -DurationMs $ms
        }
        'Unrepairable'
        {
          $msg = 'SFC found corrupt files it could NOT repair (see CBS.log).'
          New-UpdateResult -Target $target -Outcome 'Failed' -ErrorMessage $msg -DurationMs $ms
        }
        default
        {
          if ($dism.ExitCode -ne 0)
          {
            $msg = "DISM RestoreHealth exit code $($dism.ExitCode); SFC result unclear."
            New-UpdateResult -Target $target -Outcome 'Failed' -ErrorMessage $msg -DurationMs $ms
          } else
          {
            New-UpdateResult -Target $target -Outcome 'Succeeded' -DurationMs $ms
          }
        }
      }
    } catch
    {
      $msg = "integrity check failed: $($_.Exception.Message)"
      New-UpdateResult -Target $target -Outcome 'Failed' -ErrorMessage $msg -DurationMs $sw.ElapsedMilliseconds
    }
  }.GetNewClosure()
  New-UpdateProviderPort -Target $target -GetPlan $getPlan -Apply $apply
}

function New-DefenderFullScanProvider
{
  # Full Defender scan (slow). Alerts if active threats are found.
  [CmdletBinding()]
  param()
  $target = New-MaintenanceTarget -Id 'defender-full-scan' -DisplayName 'Defender full scan' -LongRunning
  $getPlan = {
    param($ctx)
    New-UpdatePlan -Items @(New-UpdateItem -Id 'defender-full-scan' -Name 'Defender full scan' -To 'scan')
  }.GetNewClosure()
  $apply = {
    param($ctx, $plan)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try
    {
      Start-MpScan -ScanType FullScan -ErrorAction Stop
      $active = @(Get-MpThreat -ErrorAction SilentlyContinue | Where-Object { $_.IsActive })
      $ms = $sw.ElapsedMilliseconds
      if (Test-DefenderClean -ActiveThreats $active)
      {
        New-UpdateResult -Target $target -Outcome 'Succeeded' -DurationMs $ms
      } else
      {
        $names = (@($active) | ForEach-Object { [string]$_.ThreatName } | Select-Object -Unique) -join '; '
        $msg = "Defender found active threats: $names"
        New-UpdateResult -Target $target -Outcome 'Failed' -ErrorMessage $msg -DurationMs $ms
      }
    } catch
    {
      $msg = "Defender full scan failed: $($_.Exception.Message)"
      New-UpdateResult -Target $target -Outcome 'Failed' -ErrorMessage $msg -DurationMs $sw.ElapsedMilliseconds
    }
  }.GetNewClosure()
  New-UpdateProviderPort -Target $target -GetPlan $getPlan -Apply $apply
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
