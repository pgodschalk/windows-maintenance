#requires -Version 7.4
#
# Module integration tests -- the guardrail for the closure/module-scope
# contract. The provider ports are closure records built with .GetNewClosure(),
# and such closures resolve unqualified function calls against GLOBAL scope,
# NOT the module's private scope. So every domain factory / helper a
# GetPlan/Apply closure calls must be EXPORTED, or the tool throws "X is not
# recognized" at run time on Windows. These tests load the real module (as
# production does) and exercise that path, so a regression in the export
# surface fails here instead of silently shipping. Cross-platform: only
# OS-agnostic provider paths (manual tasks, the maintenance GetPlan that just
# builds a plan) are exercised; the Windows I/O lives in Apply and is verified
# on Windows.

BeforeAll {
  $repo = Split-Path $PSScriptRoot -Parent
  Import-Module (Join-Path $repo 'WindowsMaintenance.psd1') -Force

  function New-NullPort
  {
    # Minimal real ports so we can drive the exported Invoke-UpdateRun end to
    # end.
    [pscustomobject]@{
      Clock     = [pscustomobject]@{ Now = { [datetimeoffset]::Parse('2026-06-02T00:00:00Z') } }
      State     = [pscustomobject]@{
        Load = { [pscustomobject]@{ Record = $null; Corrupt = $false } }
        Save = { param($r) }
      }
      Sink      = [pscustomobject]@{ Emit = { param($e) } }
      Presenter = [pscustomobject]@{
        ShowLastRun = { param($t) }; ShowProgress = { param($t) }
        ShowSummary = { param($t) }; ShowAlert = { param($t) }
        ConfirmReboot = { param($p) $false }
      }
    }
  }
}

Describe 'Module exports the closure-reachable functions' {
  It 'exports the domain factories the provider closures call' {
    foreach ($fn in 'New-UpdatePlan', 'New-UpdateResult', 'New-UpdateItem', 'New-ManualAdvisory')
    {
      Get-Command -Module WindowsMaintenance -Name $fn -ErrorAction SilentlyContinue |
        Should -Not -BeNullOrEmpty -Because "$fn must be exported for GetNewClosure'd closures"
    }
  }
}

Describe 'Provider closures resolve their dependencies under Import-Module' {
  It 'a manual-task provider runs GetPlan and yields its advisory (no "not recognized")' {
    $p = New-ManualTaskProvider -Name 'MSI X670E BIOS' -Category 'Updates' -Url 'https://msi.com/bios'
    $plan = & $p.GetPlan ([pscustomobject]@{})
    $plan.Advisory.Name | Should -Be 'MSI X670E BIOS'
  }
  It 'a maintenance provider builds its plan through the closure' {
    $plan = & (New-CrashDumpProvider).GetPlan ([pscustomobject]@{})
    $plan.PSTypeNames | Should -Contain 'WindowsMaintenance.UpdatePlan'
  }
}

Describe 'End-to-end: the real use case runs a provider built by the module' {
  It 'resolves the manual provider closure (regression: GetNewClosure + non-exported factory)' {
    $ports = New-NullPort
    $env   = Get-EnvironmentInfo -ScriptVersion 'test'
    $prov  = New-ManualTaskProvider -Name 'Test BIOS' -Category 'Updates' -Url 'https://x'
    $r = Invoke-UpdateRun -Providers @($prov) -Clock $ports.Clock -StateStore $ports.State `
      -EventSink $ports.Sink -Presenter $ports.Presenter -Environment $env -HostName 'H'

    $r.Results[0].Outcome.ToString() | Should -Be 'ManualActionRequired'
    $r.Results[0].Error              | Should -BeNullOrEmpty
  }
}
