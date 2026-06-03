#requires -Version 7.4
# Cross-platform: the PURE decision/parse helpers behind the alert-only
# maintenance checks, plus that each provider is a well-formed alert-only port.
# The impure system calls (CIM/cleanmgr/sfc/Defender) are not exercised here.

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

Describe 'Get-StorageHealthProblems' {
  It 'is empty when every disk is healthy' {
    Get-StorageHealthProblems -Disks @(
      [pscustomobject]@{ Name = 'D1'; HealthStatus = 'Healthy'; OperationalStatus = 'OK'; WearPercent = 10 }
    ) | Should -BeNullOrEmpty
  }
  It 'flags unhealthy status and high wear' {
    $disks = @(
      [pscustomobject]@{ Name = 'Bad'; HealthStatus = 'Unhealthy'; OperationalStatus = 'OK'; WearPercent = 10 }
      [pscustomobject]@{ Name = 'Worn'; HealthStatus = 'Healthy'; OperationalStatus = 'OK'; WearPercent = 95 }
    )
    $p = @(Get-StorageHealthProblems -Disks $disks)
    ($p -join '|') | Should -Match 'Bad'
    ($p -join '|') | Should -Match 'Worn'
  }
}

Describe 'Get-LowFreeSpaceDrives' {
  It 'flags only drives below the threshold, with the percentage' {
    $low = @(Get-LowFreeSpaceDrives -Volumes @(
        [pscustomobject]@{ Drive = 'C:'; SizeBytes = 1000; FreeBytes = 120 },   # 12%
        [pscustomobject]@{ Drive = 'D:'; SizeBytes = 1000; FreeBytes = 500 }    # 50%
      ) -MinFreePercent 20)
    $low.Count          | Should -Be 1
    $low[0].Drive       | Should -Be 'C:'
    $low[0].FreePercent | Should -Be 12
  }
  It 'is empty when all drives are above the threshold' {
    $vol = [pscustomobject]@{ Drive = 'C:'; SizeBytes = 1000; FreeBytes = 300 }
    Get-LowFreeSpaceDrives -Volumes @($vol) -MinFreePercent 20 | Should -BeNullOrEmpty
  }
}

Describe 'Test-CleanupHandlerEnabled' {
  It 'NEVER enables DirectX Shader Cache' {
    Test-CleanupHandlerEnabled -Name 'DirectX Shader Cache' | Should -BeFalse
  }
  It 'never enables user-data handlers (Downloads, Recycle Bin)' {
    Test-CleanupHandlerEnabled -Name 'DownloadsFolder' | Should -BeFalse
    Test-CleanupHandlerEnabled -Name 'Recycle Bin'     | Should -BeFalse
  }
  It 'enables safe system caches' {
    Test-CleanupHandlerEnabled -Name 'Temporary Files' | Should -BeTrue
    Test-CleanupHandlerEnabled -Name 'Update Cleanup'  | Should -BeTrue
  }
}

Describe 'Get-IntegrityStatus' {
  It 'classifies clean / repaired / unrepairable SFC output' {
    $clean    = 'Windows Resource Protection did not find any integrity violations.'
    $repaired = 'Windows Resource Protection found corrupt files and successfully repaired them.'
    $unrep    = 'Windows Resource Protection found corrupt files but was unable to fix some of them.'
    Get-IntegrityStatus -SfcOutput $clean    | Should -Be 'Clean'
    Get-IntegrityStatus -SfcOutput $repaired | Should -Be 'Repaired'
    Get-IntegrityStatus -SfcOutput $unrep    | Should -Be 'Unrepairable'
  }
  It 'tolerates the interleaved null bytes SFC emits when captured' {
    Get-IntegrityStatus -SfcOutput "d`0i`0d not find any integrity violations" | Should -Be 'Clean'
  }
}

Describe 'Test-DefenderClean' {
  It 'is clean with no active threats' { Test-DefenderClean -ActiveThreats @() | Should -BeTrue }
  It 'is not clean when threats are present' {
    Test-DefenderClean -ActiveThreats @([pscustomobject]@{ ThreatName = 'X' }) | Should -BeFalse
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
  It 'storage health' { Assert-AlertOnlyProvider (New-StorageHealthProvider) 'storage-health' }
  It 'free space' { Assert-AlertOnlyProvider (New-FreeSpaceProvider -MinFreePercent 25) 'free-space' }
  It 'disk cleanup' { Assert-AlertOnlyProvider (New-DiskCleanupProvider) 'disk-cleanup' }
  It 'system integrity' { Assert-AlertOnlyProvider (New-SystemIntegrityProvider) 'system-integrity' }
  It 'defender full scan' { Assert-AlertOnlyProvider (New-DefenderFullScanProvider) 'defender-full-scan' }
  It 'event-log review' { Assert-AlertOnlyProvider (New-EventHealthProvider) 'event-health' }
  It 'startup drift' { Assert-AlertOnlyProvider (New-StartupDriftProvider) 'startup-drift' }
  It 'crash dumps' { Assert-AlertOnlyProvider (New-CrashDumpProvider) 'crash-dumps' }
  It 'time sync' { Assert-AlertOnlyProvider (New-TimeSyncProvider) 'time-sync' }
}
