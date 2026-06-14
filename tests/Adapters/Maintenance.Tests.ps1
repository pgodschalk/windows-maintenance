#requires -Version 7.4
# Cross-platform: the PURE decision/parse helpers behind the alert-only
# maintenance checks, plus that each provider is a well-formed alert-only port.
# The impure system calls (event log/registry/w32tm) are not exercised here.

BeforeAll {
  $repo   = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
  $domain = Join-Path $repo 'src' 'domain'
  . (Join-Path $domain 'Enums.ps1')
  . (Join-Path $domain 'ValueObjects.ps1')
  . (Join-Path $repo 'src' 'ports' 'Ports.ps1')
  . (Join-Path $repo 'src' 'adapters' 'Maintenance.Providers.ps1')

  function Assert-AlertOnlyProvider
  {
    param($Port, [string] $ExpectedId)
    { Confirm-Port -Port $Port -PSTypeName 'WindowsMaintenance.Port.UpdateProvider' -Members 'GetPlan', 'Apply' } |
      Should -Not -Throw
    $Port.Target.Id                     | Should -Be $ExpectedId
    $Port.Target.Capabilities.AlertOnly | Should -BeTrue
  }
}

Describe 'Get-EventHealthProblems' {
  It 'is empty when all counts are zero' {
    Get-EventHealthProblems -Whea 0 -KernelPower41 0 -DiskError 0 | Should -BeNullOrEmpty
  }
  It 'reports each non-zero category and omits the zero ones' {
    $p = @(Get-EventHealthProblems -Whea 2 -KernelPower41 1 -DiskError 0)
    ($p -join '|') | Should -Match 'WHEA'
    ($p -join '|') | Should -Match 'Kernel-Power 41'
    ($p -join '|') | Should -Not -Match 'disk'
  }
}

Describe 'Get-NewEntries' {
  It 'returns identifiers added since the baseline' {
    @(Get-NewEntries -Current @('a', 'b', 'c') -Baseline @('a', 'b')) | Should -Be @('c')
  }
  It 'is empty when nothing is new (and ignores removals)' {
    Get-NewEntries -Current @('a') -Baseline @('a', 'b') | Should -BeNullOrEmpty
  }
}

Describe 'Get-CrashProblems' {
  It 'is empty with no dumps and no stop codes' {
    Get-CrashProblems -DumpCount 0 -StopCodes @() | Should -BeNullOrEmpty
  }
  It 'reports the dump count and de-duplicated stop code' {
    $m = (@(Get-CrashProblems -DumpCount 2 -StopCodes @('0x00000133', '0x00000133')) -join '|')
    $m | Should -Match '2 new crash dump'
    $m | Should -Match '0x00000133'
  }
  It 'reports even when only a bugcheck event (no dump file) is present' {
    Get-CrashProblems -DumpCount 0 -StopCodes @('0x000000ef') | Should -Not -BeNullOrEmpty
  }
}

Describe 'Get-TimeSyncProblems' {
  It 'is healthy when running, synced, recent, and NTP-sourced' {
    $ts = @{ ServiceRunning = $true; Source = 'time.windows.com'; Synced = $true; SyncAgeHours = 2 }
    Get-TimeSyncProblems @ts | Should -BeNullOrEmpty
  }
  It 'flags a stopped time service' {
    $ts = @{ ServiceRunning = $false; Synced = $true; SyncAgeHours = 1 }
    (@(Get-TimeSyncProblems @ts) -join '|') | Should -Match 'not running'
  }
  It 'flags never-synced and stale syncs' {
    (@(Get-TimeSyncProblems -ServiceRunning $true -Synced $false) -join '|') | Should -Match 'never'
    $stale = @{ ServiceRunning = $true; Synced = $true; SyncAgeHours = 100; MaxAgeHours = 48 }
    (@(Get-TimeSyncProblems @stale) -join '|') | Should -Match '100h'
  }
  It 'flags the local CMOS clock source' {
    $cmos = @{ ServiceRunning = $true; Source = 'Local CMOS Clock'; Synced = $true; SyncAgeHours = 1 }
    (@(Get-TimeSyncProblems @cmos) -join '|') | Should -Match 'CMOS'
  }
}

Describe 'Maintenance providers are well-formed alert-only ports' {
  It 'event-log review' { Assert-AlertOnlyProvider (New-EventHealthProvider) 'event-health' }
  It 'startup drift' { Assert-AlertOnlyProvider (New-StartupDriftProvider) 'startup-drift' }
  It 'crash dumps' { Assert-AlertOnlyProvider (New-CrashDumpProvider) 'crash-dumps' }
  It 'time sync' { Assert-AlertOnlyProvider (New-TimeSyncProvider) 'time-sync' }
}
