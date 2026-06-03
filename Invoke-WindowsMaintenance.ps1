#requires -Version 7.4

<#
.SYNOPSIS
    Runs routine Windows maintenance: installs Windows + application updates,
    runs silent health checks, backs up configured paths, and lists the tasks
    you must do by hand.

.DESCRIPTION
    Thin driving adapter (composition root). It wires the dependencies and
    hands off to the Invoke-UpdateRun use case, which runs every configured
    maintenance provider in order:

      * Updates - Windows Update (all software; drivers excluded by default),
                  winget app upgrades, and Microsoft Defender signature updates.
      * Health  - silent checks that print to stdout ONLY when something is
                  wrong: storage (SMART) health, free space, Disk Cleanup,
                  system integrity (SFC/DISM), a full Defender scan, critical
                  event-log review, startup/scheduled-task drift, crash dumps,
                  and clock sync.
      * Backup  - an encrypted restic backup of configured paths to S3 (skipped
                  if not set up).
      * Manual  - reminders for what the tool cannot do itself (firmware/BIOS,
                  etc.), printed at the end with their links.

    Every invocation shows when the last run happened, emits exactly one
    canonical wide event to the Windows Event Log, and (per policy) prompts
    before rebooting when an interactive session requires one.

    Run from an ELEVATED PowerShell 7 session (Windows Update / Defender /
    machine-scope winget require administrator). It will not self-elevate; it
    fails fast with a clear message.

.PARAMETER WingetPackageId
    Restrict winget to these exact package IDs. If OMITTED (the default), every
    package winget reports as upgradable is upgraded ("upgrade everything").

.PARAMETER WingetExcludeId
    Package IDs to hold back / pin (skipped even in upgrade-everything mode),
    e.g. 'Foo.Bar'.

.PARAMETER WingetMachineScope
    Pass --scope machine to winget upgrades.

.PARAMETER IncludeDrivers
    Also install driver updates from Windows Update. OFF by default - drivers
    are managed separately (and AtlasOS blocks Windows Update driver delivery).
    Everything else Windows Update offers (including optional/preview quality &
    feature updates) is installed regardless.

.PARAMETER FreeSpaceMinPercent
    Free-space threshold (percent) for the silent storage check; alerts to
    stdout if any fixed drive is below it. Default 20 (keeps the Crucial T700's
    ~11% dynamic SLC cache + GC headroom).

.PARAMETER ManualTasksPath
    Override the manual-tasks JSON config (default:
    %ProgramData%\WindowsMaintenance\manual-tasks.json). Each entry is a name
    to check plus an optional url; they are listed at the end of the run. See
    manual-tasks.schema.json / manual-tasks.example.json.

.PARAMETER BackupConfigPath
    Override the encrypted-backup config (default:
    %ProgramData%\WindowsMaintenance\backup-config.json). Defines the paths +
    S3 repository; secrets are 1Password op:// references resolved at runtime
    via `op read`. See backup-config.schema.json. If the file is absent, backup
    is skipped.

.PARAMETER StatePath
    Override the last-invocation state file (default:
    %ProgramData%\WindowsMaintenance\last-invocation.json).

.PARAMETER Json
    Emit the canonical run event (the same wide event written to the Event Log)
    to stdout as JSON, and suppress the human narration so stdout is
    machine-parseable. Alerts still go to stderr.

.PARAMETER Quiet
    Suppress the human narration on stdout (alerts still go to stderr). Implied
    by -Json.

.PARAMETER Version
    Print the module version and exit, without running maintenance.

.EXAMPLE
    .\Invoke-WindowsMaintenance.ps1 -WhatIf
    Dry run: shows the last-run line and what each maintenance provider would
    do, changing nothing.

.EXAMPLE
    .\Invoke-WindowsMaintenance.ps1 -WingetPackageId 'Mozilla.Firefox','Git.Git'

.EXAMPLE
    .\Invoke-WindowsMaintenance.ps1 -Json | ConvertFrom-Json
    Machine-readable run: stdout carries only the canonical event.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [string[]] $WingetPackageId,
  [string[]] $WingetExcludeId,
  [switch]   $WingetMachineScope,
  [switch]   $IncludeDrivers,
  [int]      $FreeSpaceMinPercent = 20,
  [string]   $BackupConfigPath,
  [string]   $ManualTasksPath,
  [string]   $StatePath,
  [switch]   $Json,
  [switch]   $Quiet,
  [switch]   $Version
)

$ErrorActionPreference = 'Stop'

$module        = Import-Module (Join-Path $PSScriptRoot 'WindowsMaintenance.psd1') -Force -PassThru
$moduleVersion = $module.Version.ToString()

# --version: print and exit, without running maintenance.
if ($Version)
{
  [Console]::Out.WriteLine($moduleVersion)
  exit 0
}

$compositionArgs = @{ ScriptVersion = $moduleVersion }
# -Json owns stdout (only the event prints there), so narration is silenced;
# -Quiet does the same.
if ($Json -or $Quiet)
{
  $compositionArgs.Quiet = $true
}
if ($PSBoundParameters.ContainsKey('WingetPackageId'))
{
  $compositionArgs.WingetPackageId = $WingetPackageId
}
if ($PSBoundParameters.ContainsKey('WingetExcludeId'))
{
  $compositionArgs.WingetExcludeId = $WingetExcludeId
}
if ($WingetMachineScope)
{
  $compositionArgs.WingetMachineScope = $true
}
if ($IncludeDrivers)
{
  $compositionArgs.IncludeDrivers = $true
}
$compositionArgs.FreeSpaceMinPercent = $FreeSpaceMinPercent
if ($BackupConfigPath)
{
  $compositionArgs.BackupConfigPath = $BackupConfigPath
}
if ($ManualTasksPath)
{
  $compositionArgs.ManualTasksPath = $ManualTasksPath
}
if ($StatePath)
{
  $compositionArgs.StatePath = $StatePath
}

$composition = New-WindowsMaintenanceComposition @compositionArgs

$result = Invoke-UpdateRun `
  -Providers   $composition.Providers `
  -Clock       $composition.Clock `
  -StateStore  $composition.StateStore `
  -EventSink   $composition.EventSink `
  -Presenter   $composition.Presenter `
  -Environment $composition.Environment `
  -HostName $composition.HostName `
  -WhatIf:$WhatIfPreference

# -Json: emit the canonical event (the same one logged) to stdout as the
# machine payload.
if ($Json)
{
  [Console]::Out.WriteLine(($result.WideEvent | ConvertTo-Json -Depth 8))
}

# Outcome -> exit code. Manual/skip are EXPECTED states (a scheduled task
# shouldn't alarm on "go check your BIOS"), so only an actual Failed run is
# non-zero.
$exitCode = ($result.OverallOutcome.ToString() -eq 'Failed') ? 1 : 0

# The irreversible action happens LAST, after the wide event has already been
# emitted inside the use case (a reboot kills the process). Only when the user
# confirmed an interactive prompt.
if ($result.RebootDecision.ToString() -eq 'Confirmed')
{
  [Console]::Out.WriteLine('Restarting now to finish updates...')
  Restart-Computer -Force
}

exit $exitCode
