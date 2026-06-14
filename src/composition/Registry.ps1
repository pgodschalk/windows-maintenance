#requires -Version 7.4
#
# Composition root - the ONLY place that knows concrete adapters exist.
# Everything else depends on ports. Adding a new update target is a localised
# change: write one adapter file, then add ONE line to Get-ProviderFactories.
# Nothing else changes (the use case, core, event schema, presenter and state
# store all iterate over results generically).
# Depends on: every adapter factory + the domain Environment reader.

function Get-ProviderFactories
{
  # Ordered list of () -> IUpdateProvider factories. Order == execution order.
  [OutputType([array])]
  [CmdletBinding()]
  param(
    [string[]] $WingetPackageId = @(),
    [string[]] $WingetExcludeId = @(),
    [switch]   $WingetMachineScope,
    [switch]   $IncludeDrivers,
    [string]   $BackupConfigPath = (Get-DefaultBackupConfigPath)
  )
  # Factories that need configuration capture it; the others are parameterless.
  $wuaFactory    = { New-WuaOsUpdateProvider -IncludeDrivers:$IncludeDrivers }.GetNewClosure()
  $wingetFactory = {
    # Default: upgrade everything winget reports. An explicit -WingetPackageId
    # restricts to a list.
    $common = @{ ExcludeId = $WingetExcludeId; MachineScope = $WingetMachineScope }
    if (@($WingetPackageId).Count -gt 0)
    {
      New-WingetAppProvider -PackageId $WingetPackageId @common
    } else
    {
      New-WingetAppProvider -All @common
    }
  }.GetNewClosure()
  $backupFactory    = { New-BackupProvider -ConfigPath $BackupConfigPath }.GetNewClosure()

  @(
    $wuaFactory                       # Windows OS updates (WUA COM) - all software, drivers excluded by default
    $wingetFactory                    # winget apps - upgrades all by default; -WingetPackageId restricts the set
    { New-DefenderSignatureProvider } # Microsoft Defender signatures
    #
    # Alert-only maintenance checks - run silently, surfaced to stdout only on
    # a problem:
    { New-EventHealthProvider }       # WHEA / Kernel-Power 41 / disk errors since last run
    { New-StartupDriftProvider }      # new autostart entries / scheduled tasks since last run
    { New-CrashDumpProvider }         # new BSOD minidumps + stop code since last run
    { New-TimeSyncProvider }          # clock not syncing (w32time)
    $backupFactory                    # encrypted restic backup -> S3 (alert-only; configured in backup-config.json)
    #
    # Manual-advisory targets (e.g. firmware/BIOS) come from the manual-tasks
    # JSON config, appended by New-WindowsMaintenanceComposition - see
    # New-ManualTaskProvider.
    #
    # To add a NEW automated target later:
    #   1. create src/adapters/Provider.<X>.ps1 exporting New-<X>Provider
    #   2. add a line here:           { New-<X>Provider }
  )
}

function Get-DefaultManualTasksPath
{
  [OutputType([string])]
  param()
  $base = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'WindowsMaintenance'
  Join-Path $base 'manual-tasks.json'
}

function Get-DefaultBackupConfigPath
{
  [OutputType([string])]
  param()
  $base = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'WindowsMaintenance'
  Join-Path $base 'backup-config.json'
}

function Get-DefaultStatePath
{
  [OutputType([string])]
  param()
  $base = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'WindowsMaintenance'
  Join-Path $base 'last-invocation.json'
}

function New-WindowsMaintenanceComposition
{
  # Wire the six injected dependencies for Invoke-UpdateRun. This is the
  # imperative shell's assembly point; it performs the system reads
  # (environment) and builds the driven adapters.
  [CmdletBinding()]
  param(
    [string]   $ScriptVersion = '0.0.0',
    [string[]] $WingetPackageId = @(),
    [string[]] $WingetExcludeId = @(),
    [switch]   $WingetMachineScope,
    [switch]   $IncludeDrivers,
    [string]   $BackupConfigPath = (Get-DefaultBackupConfigPath),
    [string]   $ManualTasksPath = (Get-DefaultManualTasksPath),
    [string]   $StatePath = (Get-DefaultStatePath),
    [string]   $EventLogName = 'WindowsMaintenance',
    [string]   $EventLogSource = 'WindowsMaintenance',
    [switch]   $Quiet   # suppress console narration (used by -Json so stdout carries only the payload)
  )

  $providers = @(
    Get-ProviderFactories -WingetPackageId $WingetPackageId -WingetExcludeId $WingetExcludeId `
      -WingetMachineScope:$WingetMachineScope -IncludeDrivers:$IncludeDrivers `
      -BackupConfigPath $BackupConfigPath |
      ForEach-Object { & $_ }
  )
  # Append one manual-advisory provider per configured manual task
  # (firmware/BIOS, Store, etc.).
  foreach ($task in (Get-ManualTaskConfig -Path $ManualTasksPath))
  {
    $providers += New-ManualTaskProvider -Name $task.Name -Url $task.Url -Category $task.Category
  }

  [pscustomobject]@{
    PSTypeName  = 'WindowsMaintenance.Composition'
    Providers   = $providers
    Clock       = New-SystemClock
    StateStore  = New-JsonStateStore -Path $StatePath
    EventSink   = New-EventLogEventSink -LogName $EventLogName -Source $EventLogSource
    Presenter   = New-ConsolePresenter -Silent:$Quiet
    Environment = Get-EnvironmentInfo -ScriptVersion $ScriptVersion
    HostName    = $env:COMPUTERNAME
  }
}
