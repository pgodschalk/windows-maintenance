#requires -Version 7.4
#
# Encrypted backup provider (driven, Automated, AlertOnly). During a run it
# pushes configured paths to an S3-compatible repository using restic
# Depends on: ValueObjects.ps1, Ports.ps1.

function ConvertFrom-ResticExitCode
{
  # PURE: restic exit code -> status. 0 = ok, 3 = some source files unreadable
  # (snapshot still made), anything else = failure.
  [OutputType([string])]
  [CmdletBinding()]
  param([Parameter(Mandatory)][int] $Code)
  switch ($Code)
  {
    0
    {
      'Succeeded'
    }
    3
    {
      'Partial'
    }
    default
    {
      'Failed'
    }
  }
}

function Get-ResticBackupArgs
{
  # PURE: build the `restic backup` argument list (the subcommand; global flags
  # are prepended by the caller).
  [OutputType([string[]])]
  [CmdletBinding()]
  param([string[]] $Paths = @(), [string[]] $Exclude = @(), [string] $Tag = 'windows-maintenance')
  $a = [System.Collections.Generic.List[string]]::new()
  $a.Add('backup')
  if ($Tag)
  {
    $a.Add('--tag'); $a.Add($Tag)
  }
  foreach ($e in @($Exclude))
  {
    if ($e)
    {
      $a.Add('--exclude'); $a.Add($e)
    }
  }
  foreach ($p in @($Paths))
  {
    if ($p)
    {
      $a.Add($p)
    }
  }
  $a.ToArray()
}

function Get-ResticForgetArgs
{
  # PURE: build `restic forget --prune` from a retention spec
  # (keepDaily/Weekly/Monthly). Returns @() when no retention is configured
  # (caller skips pruning).
  [OutputType([string[]])]
  [CmdletBinding()]
  param([object] $Retention)
  if ($null -eq $Retention)
  {
    return [string[]]@()
  }
  $a = [System.Collections.Generic.List[string]]::new()
  $a.Add('forget'); $a.Add('--prune')
  if ($Retention.keepDaily)
  {
    $a.Add('--keep-daily'); $a.Add([string][int]$Retention.keepDaily)
  }
  if ($Retention.keepWeekly)
  {
    $a.Add('--keep-weekly'); $a.Add([string][int]$Retention.keepWeekly)
  }
  if ($Retention.keepMonthly)
  {
    $a.Add('--keep-monthly'); $a.Add([string][int]$Retention.keepMonthly)
  }
  if ($a.Count -le 2)
  {
    return [string[]]@()
  }   # forget+prune with no keep-* rules would delete everything -- refuse
  $a.ToArray()
}

function ConvertFrom-BackupConfig
{
  # PURE: parse + validate backup-config JSON into a normalized object. Throws
  # on missing required fields (repository, secrets.resticPassword).
  [CmdletBinding()]
  param([string] $Json)
  if ([string]::IsNullOrWhiteSpace($Json))
  {
    throw 'backup config is empty'
  }
  $c = $Json | ConvertFrom-Json -ErrorAction Stop
  if ([string]::IsNullOrWhiteSpace([string]$c.repository))
  {
    throw "backup config missing 'repository'"
  }
  if (-not $c.secrets -or [string]::IsNullOrWhiteSpace([string]$c.secrets.resticPassword))
  {
    throw "backup config missing 'secrets.resticPassword' (an op:// reference)"
  }
  [pscustomobject]@{
    Repository  = [string]$c.repository
    Paths       = @([string[]]@($c.paths)   | Where-Object { $_ })
    Exclude     = @([string[]]@($c.exclude) | Where-Object { $_ })
    InsecureTls = [bool]$c.insecureTls
    Retention   = $c.retention
    Secrets     = [pscustomobject]@{
      ResticPassword     = [string]$c.secrets.resticPassword
      AwsAccessKeyId     = [string]$c.secrets.awsAccessKeyId
      AwsSecretAccessKey = [string]$c.secrets.awsSecretAccessKey
    }
  }
}

function Get-OpSecret
{
  # IMPURE: read a single secret from 1Password via `op read op://...`. Throws
  # on failure.
  [OutputType([string])]
  [CmdletBinding()]
  param([Parameter(Mandatory)][string] $Reference)
  if ([string]::IsNullOrWhiteSpace($Reference))
  {
    throw 'missing op:// reference'
  }
  $out = & op read $Reference 2>&1
  if ($LASTEXITCODE -ne 0)
  {
    throw "op read '$Reference' failed: $out"
  }
  [string]$out
}

function New-BackupProvider
{
  [CmdletBinding()]
  param([string] $ConfigPath)
  if (-not $ConfigPath)
  {
    $dir = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'WindowsMaintenance'
    $ConfigPath = Join-Path $dir 'backup-config.json'
  }
  $cfgPath = $ConfigPath
  $targetArgs = @{
    Id           = 'backup'
    DisplayName  = 'Encrypted backup (restic -> S3)'
    Kind         = 'Automated'
    Capabilities = @{ AlertOnly = $true }
  }
  $target = New-UpdateTarget @targetArgs

  # No config file => backups not set up => NothingToDo (stays silent).
  $getPlan = {
    param($ctx)
    if (Test-Path -LiteralPath $cfgPath)
    {
      New-UpdatePlan -Items @(New-UpdateItem -Id 'backup' -Name 'Encrypted backup' -To 'run')
    } else
    {
      New-UpdatePlan
    }
  }.GetNewClosure()

  $apply = {
    param($ctx, $plan)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $restoreEnv = @{}
    try
    {
      $cfg = ConvertFrom-BackupConfig -Json (Get-Content -LiteralPath $cfgPath -Raw -ErrorAction Stop)
      if (@($cfg.Paths).Count -eq 0)
      {
        # nothing configured to back up
        return New-UpdateResult -Target $target -Outcome 'Succeeded' -DurationMs $sw.ElapsedMilliseconds
      }
      if (-not (Get-Command op -CommandType Application -ErrorAction SilentlyContinue))
      {
        $msg = "1Password CLI 'op' not found (needed to read the backup secrets)."
        $ms = $sw.ElapsedMilliseconds
        return New-UpdateResult -Target $target -Outcome 'Failed' -ErrorMessage $msg -DurationMs $ms
      }
      if (-not (Get-Command restic -CommandType Application -ErrorAction SilentlyContinue))
      {
        $msg = 'restic was not found on this system.'
        $ms = $sw.ElapsedMilliseconds
        return New-UpdateResult -Target $target -Outcome 'Failed' -ErrorMessage $msg -DurationMs $ms
      }

      # Resolve secrets from 1Password and inject them into the (child) process
      # environment.
      $values = [ordered]@{
        RESTIC_REPOSITORY     = $cfg.Repository
        RESTIC_PASSWORD       = (Get-OpSecret -Reference $cfg.Secrets.ResticPassword)
        AWS_ACCESS_KEY_ID     = (Get-OpSecret -Reference $cfg.Secrets.AwsAccessKeyId)
        AWS_SECRET_ACCESS_KEY = (Get-OpSecret -Reference $cfg.Secrets.AwsSecretAccessKey)
      }
      foreach ($k in $values.Keys)
      {
        $restoreEnv[$k] = [Environment]::GetEnvironmentVariable($k)
        [Environment]::SetEnvironmentVariable($k, $values[$k])
      }

      $global = $cfg.InsecureTls ? @('--insecure-tls') : @()

      # Initialise the repo on first use.
      & restic @global cat config *> $null
      if ($LASTEXITCODE -ne 0)
      {
        & restic @global init *> $null
        if ($LASTEXITCODE -ne 0)
        {
          $msg = 'restic could not open or initialise the repository (check endpoint/credentials).'
          $ms = $sw.ElapsedMilliseconds
          return New-UpdateResult -Target $target -Outcome 'Failed' -ErrorMessage $msg -DurationMs $ms
        }
      }

      # Back up.
      $backupArgs = Get-ResticBackupArgs -Paths $cfg.Paths -Exclude $cfg.Exclude
      $out = (& restic @global @backupArgs 2>&1 | Out-String)
      $status = ConvertFrom-ResticExitCode -Code $LASTEXITCODE
      if ($status -eq 'Failed')
      {
        $tail = (($out -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 2) -join ' ')
        $msg = "restic backup failed (exit $LASTEXITCODE): $tail"
        $ms = $sw.ElapsedMilliseconds
        return New-UpdateResult -Target $target -Outcome 'Failed' -ErrorMessage $msg -DurationMs $ms
      }

      # Retention (optional, best-effort - a prune failure must not fail a good
      # backup).
      $forgetArgs = Get-ResticForgetArgs -Retention $cfg.Retention
      if (@($forgetArgs).Count -gt 0)
      {
        & restic @global @forgetArgs *> $null
      }

      New-UpdateResult -Target $target -Outcome 'Succeeded' -DurationMs $sw.ElapsedMilliseconds
    } catch
    {
      $msg = "backup failed: $($_.Exception.Message)"
      New-UpdateResult -Target $target -Outcome 'Failed' -ErrorMessage $msg -DurationMs $sw.ElapsedMilliseconds
    } finally
    {
      foreach ($k in $restoreEnv.Keys)
      {
        [Environment]::SetEnvironmentVariable($k, $restoreEnv[$k])
      }
    }
  }.GetNewClosure()

  New-UpdateProviderPort -Target $target -GetPlan $getPlan -Apply $apply
}
