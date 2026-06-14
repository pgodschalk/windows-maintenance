#requires -Version 7.4
#
# Orchestration tests. The use case takes its ports as parameters, so we inject
# FAKE ports built from test scriptblocks - no mocking framework. These assert
# the load-bearing invariants of the design:
#   * exactly one wide event is emitted on EVERY path (success / all-fail /
#     fail-fast)
#   * one provider throwing never aborts the others (resilient loop)
#   * first-run, corrupt-state, and state-save-failure all degrade gracefully
#   * the reboot prompt is interactive-guarded
# OS-agnostic: runs anywhere pwsh + Pester are installed.

BeforeAll {
  $root   = Split-Path $PSScriptRoot -Parent
  $domain = Join-Path $root 'src' 'domain'
  foreach ($f in 'Enums', 'ValueObjects', 'Outcome', 'Decisions', 'Projections', 'Formatting')
  {
    . (Join-Path $domain "$f.ps1")
  }
  . (Join-Path $root 'src' 'ports' 'Ports.ps1')
  . (Join-Path $root 'src' 'application' 'Invoke-UpdateRun.ps1')

  function New-FakeClock
  {
    param([datetimeoffset] $Start = [datetimeoffset]'2026-06-02T00:00:00Z', [int] $DurationMs = 1000)
    $s = @{ n = 0 }
    [pscustomobject]@{
      Now = { $s.n++; $s.n -eq 1 ? $Start : $Start.AddMilliseconds($DurationMs) }.GetNewClosure()
    }
  }
  function New-FakeStateStore
  {
    param([object] $Record = $null, [bool] $Corrupt = $false, [switch] $FailSave)
    $s = @{ Saved = $null; SaveCalled = $false }
    [pscustomobject]@{
      Load  = { [pscustomobject]@{ Record = $Record; Corrupt = $Corrupt } }.GetNewClosure()
      Save  = {
        param($rec)
        $s.SaveCalled = $true
        if ($FailSave)
        {
          throw 'disk full'
        }
        $s.Saved = $rec
      }.GetNewClosure()
      State = $s
    }
  }
  function New-FakeEventSink
  {
    $s = @{ Events = [System.Collections.Generic.List[object]]::new() }
    [pscustomobject]@{
      Emit  = { param($evt) $s.Events.Add($evt) }.GetNewClosure()
      State = $s
    }
  }
  function New-FakePresenter
  {
    param([bool] $RebootConfirmed = $false)
    $s = @{ LastRun = $null; RebootAsked = $false
      Progress = [System.Collections.Generic.List[string]]::new()
      Summary  = [System.Collections.Generic.List[string]]::new()
      Alerts   = [System.Collections.Generic.List[string]]::new()
    }
    [pscustomobject]@{
      ShowLastRun   = { param($t) $s.LastRun = $t }.GetNewClosure()
      ShowProgress  = { param($t) $s.Progress.Add($t) }.GetNewClosure()
      ShowSummary   = { param($t) $s.Summary.Add($t) }.GetNewClosure()
      ShowAlert     = { param($t) $s.Alerts.Add($t) }.GetNewClosure()
      ConfirmReboot = { param($p) $s.RebootAsked = $true; $RebootConfirmed }.GetNewClosure()
      State         = $s
    }
  }
  function New-FakeProvider
  {
    param(
      [string] $Id = 'p',
      [string] $Kind = 'Automated',
      [object] $Plan,
      [object] $Result,
      [switch] $ApplyThrows
    )
    $target  = New-UpdateTarget -Id $Id -DisplayName $Id -Kind $Kind
    $thePlan = $Plan ?? (New-UpdatePlan)
    [pscustomobject]@{
      Target  = $target
      GetPlan = { param($ctx) $thePlan }.GetNewClosure()
      Apply   = { param($ctx, $plan) if ($ApplyThrows)
        {
          throw 'apply failed'
        }; $Result }.GetNewClosure()
    }
  }
  function New-SuccessProvider
  {
    param([string] $Id = 'winget', [bool] $Reboot = $false, [int] $Applied = 1)
    $items  = 1..$Applied | ForEach-Object { New-UpdateItem -Id "pkg$_" -Name "Package $_" -From '1' -To '2' }
    $target = New-UpdateTarget -Id $Id -DisplayName $Id -Kind 'Automated'
    $result = New-UpdateResult -Target $target -Outcome 'Succeeded' -ItemsApplied @($items) `
      -RebootRequired $Reboot -DurationMs 5
    New-FakeProvider -Id $Id -Plan (New-UpdatePlan -Items @($items)) -Result $result
  }
  function New-Elevated
  {
    New-EnvironmentInfo -OsBuild b -OsVersion v -PsVersion p -ScriptVersion s `
      -IsElevated $true -IsInteractive $true -Locale l -Region r
  }
  function New-Unelevated
  {
    New-EnvironmentInfo -OsBuild b -OsVersion v -PsVersion p -ScriptVersion s `
      -IsElevated $false -IsInteractive $true -Locale l -Region r
  }
  function New-NonInteractive
  {
    New-EnvironmentInfo -OsBuild b -OsVersion v -PsVersion p -ScriptVersion s `
      -IsElevated $true -IsInteractive $false -Locale l -Region r
  }

  function Invoke-Run
  {
    param($Providers, $Clock, $StateStore, $EventSink, $Presenter, $Environment)
    Invoke-UpdateRun -Providers $Providers -Clock $Clock -StateStore $StateStore `
      -EventSink $EventSink -Presenter $Presenter -Environment $Environment -HostName 'TESTHOST'
  }
}

Describe 'Invoke-UpdateRun - the single-event invariant' {
  It 'emits exactly one wide event on a successful run' {
    $sink = New-FakeEventSink
    $report = Invoke-Run -Providers @(New-SuccessProvider) -Clock (New-FakeClock) `
      -StateStore (New-FakeStateStore) -EventSink $sink -Presenter (New-FakePresenter) -Environment (New-Elevated)

    $sink.State.Events.Count       | Should -Be 1
    $sink.State.Events[0].outcome  | Should -Be 'Succeeded'
    $report.OverallOutcome.ToString() | Should -Be 'Succeeded'
  }
  It 'emits exactly one Failed event on the fail-fast (not elevated) path' {
    $sink = New-FakeEventSink
    $result = Invoke-Run -Providers @(New-SuccessProvider) -Clock (New-FakeClock) `
      -StateStore (New-FakeStateStore) -EventSink $sink `
      -Presenter (New-FakePresenter) -Environment (New-Unelevated)

    $sink.State.Events.Count            | Should -Be 1
    $sink.State.Events[0].outcome       | Should -Be 'Failed'
    $sink.State.Events[0].failure_reason | Should -Be 'not_elevated'
    $result.OverallOutcome.ToString()   | Should -Be 'Failed'
    $result.FailFast                    | Should -BeTrue
  }
  It 'emits exactly one event even when every provider fails' {
    $sink = New-FakeEventSink
    $p1 = New-FakeProvider -Id a -Plan (New-UpdatePlan -Items @(New-UpdateItem -Id i -Name I -To '2')) -ApplyThrows
    $p2 = New-FakeProvider -Id b -Plan (New-UpdatePlan -Items @(New-UpdateItem -Id i -Name I -To '2')) -ApplyThrows
    $report = Invoke-Run -Providers @($p1, $p2) -Clock (New-FakeClock) `
      -StateStore (New-FakeStateStore) -EventSink $sink -Presenter (New-FakePresenter) -Environment (New-Elevated)

    $sink.State.Events.Count          | Should -Be 1
    $report.OverallOutcome.ToString() | Should -Be 'Failed'
  }
}

Describe 'Invoke-UpdateRun - resilient per-provider loop' {
  It 'demotes a throwing provider to Failed without aborting the others' {
    $item = New-UpdateItem -Id i -Name I -To '2'
    $bad  = New-FakeProvider -Id 'bad'  -Plan (New-UpdatePlan -Items @($item)) -ApplyThrows
    $good = New-SuccessProvider -Id 'good'
    $sink = New-FakeEventSink

    $report = Invoke-Run -Providers @($bad, $good) -Clock (New-FakeClock) `
      -StateStore (New-FakeStateStore) -EventSink $sink -Presenter (New-FakePresenter) -Environment (New-Elevated)

    $evt = $sink.State.Events[0]
    $evt.providers_total | Should -Be 2
    ($evt.providers | Where-Object { $_.id -eq 'bad' }).outcome  | Should -Be 'Failed'
    ($evt.providers | Where-Object { $_.id -eq 'bad' }).error    | Should -Match 'apply failed'
    ($evt.providers | Where-Object { $_.id -eq 'good' }).outcome | Should -Be 'Succeeded'
    $report.OverallOutcome.ToString() | Should -Be 'Failed'   # worst wins, but good still ran
  }
}

Describe 'Invoke-UpdateRun - last-run display' {
  It 'shows the persisted last-run line when state exists' {
    $record = [pscustomobject]@{ timestamp = '2026-06-01T00:00:00Z'; outcome = 'Succeeded'
      reboot_required = $false; updates_applied_total = 2
    }
    $presenter = New-FakePresenter
    Invoke-Run -Providers @(New-SuccessProvider) -Clock (New-FakeClock) `
      -StateStore (New-FakeStateStore -Record $record) -EventSink (New-FakeEventSink) `
      -Presenter $presenter -Environment (New-Elevated) | Out-Null

    $presenter.State.LastRun | Should -Match 'Last run: 2026-06-01'
  }
  It 'shows the first-run line when there is no state' {
    $presenter = New-FakePresenter
    Invoke-Run -Providers @(New-SuccessProvider) -Clock (New-FakeClock) `
      -StateStore (New-FakeStateStore) -EventSink (New-FakeEventSink) `
      -Presenter $presenter -Environment (New-Elevated) | Out-Null

    $presenter.State.LastRun | Should -Match 'never'
  }
  It 'treats corrupt state as first-run and flags it in the event' {
    $presenter = New-FakePresenter
    $sink = New-FakeEventSink
    Invoke-Run -Providers @(New-SuccessProvider) -Clock (New-FakeClock) `
      -StateStore (New-FakeStateStore -Corrupt $true) -EventSink $sink `
      -Presenter $presenter -Environment (New-Elevated) | Out-Null

    $presenter.State.LastRun            | Should -Match 'never'
    $sink.State.Events[0].state_load_corrupt | Should -BeTrue
  }
}

Describe 'Invoke-UpdateRun - best-effort persistence' {
  It 'records state_save_failed but still completes and emits' {
    $sink = New-FakeEventSink
    $report = Invoke-Run -Providers @(New-SuccessProvider) -Clock (New-FakeClock) `
      -StateStore (New-FakeStateStore -FailSave) -EventSink $sink `
      -Presenter (New-FakePresenter) -Environment (New-Elevated)

    $sink.State.Events.Count              | Should -Be 1
    $sink.State.Events[0].state_save_failed | Should -BeTrue
    $report.OverallOutcome.ToString()     | Should -Be 'Succeeded'
  }
}

Describe 'Invoke-UpdateRun - alert-only checks surface via ShowAlert (stderr), not the summary' {
  It 'routes a failing alert-only check to ShowAlert and keeps it out of the summary' {
    $alertTarget = New-UpdateTarget -Id 'crash-dumps' -DisplayName 'Crash dumps (BSOD)' -Kind 'Automated' `
      -Capabilities @{ AlertOnly = $true }
    $failResult = New-UpdateResult -Target $alertTarget -Outcome 'Failed' -ErrorMessage '1 new crash dump(s)'
    $plan       = New-UpdatePlan -Items @(New-UpdateItem -Id 'crash-dumps' -Name 'check' -To 'x')
    $provider   = [pscustomobject]@{
      Target  = $alertTarget
      GetPlan = { param($ctx) $plan }.GetNewClosure()
      Apply   = { param($ctx, $plan) $failResult }.GetNewClosure()
    }
    $presenter = New-FakePresenter
    Invoke-Run -Providers @($provider) -Clock (New-FakeClock) `
      -StateStore (New-FakeStateStore) -EventSink (New-FakeEventSink) `
      -Presenter $presenter -Environment (New-Elevated) | Out-Null

    ($presenter.State.Alerts -join "`n")  | Should -Match 'Crash dumps'
    ($presenter.State.Alerts -join "`n")  | Should -Match 'crash dump'
    ($presenter.State.Summary -join "`n") | Should -Not -Match 'Crash dumps'
  }
}

Describe 'Invoke-UpdateRun - reboot prompt is interactive-guarded' {
  It 'prompts and records Confirmed when interactive and the user agrees' {
    $presenter = New-FakePresenter -RebootConfirmed $true
    $sink = New-FakeEventSink
    $report = Invoke-Run -Providers @(New-SuccessProvider -Reboot $true) -Clock (New-FakeClock) `
      -StateStore (New-FakeStateStore) -EventSink $sink -Presenter $presenter -Environment (New-Elevated)

    $presenter.State.RebootAsked         | Should -BeTrue
    $report.RebootDecision.ToString()    | Should -Be 'Confirmed'
    $sink.State.Events[0].reboot_decision | Should -Be 'Confirmed'
    $sink.State.Events[0].reboot_required | Should -BeTrue
  }
  It 'records Declined when interactive and the user refuses' {
    $presenter = New-FakePresenter -RebootConfirmed $false
    $report = Invoke-Run -Providers @(New-SuccessProvider -Reboot $true) -Clock (New-FakeClock) `
      -StateStore (New-FakeStateStore) -EventSink (New-FakeEventSink) `
      -Presenter $presenter -Environment (New-Elevated)

    $presenter.State.RebootAsked      | Should -BeTrue
    $report.RebootDecision.ToString() | Should -Be 'Declined'
  }
  It 'does NOT prompt on a non-interactive session (so scheduled runs never hang)' {
    $presenter = New-FakePresenter -RebootConfirmed $true
    $report = Invoke-Run -Providers @(New-SuccessProvider -Reboot $true) -Clock (New-FakeClock) `
      -StateStore (New-FakeStateStore) -EventSink (New-FakeEventSink) `
      -Presenter $presenter -Environment (New-NonInteractive)

    $presenter.State.RebootAsked      | Should -BeFalse
    $report.RebootDecision.ToString() | Should -Be 'NotPromptedNonInteractive'
  }
}

