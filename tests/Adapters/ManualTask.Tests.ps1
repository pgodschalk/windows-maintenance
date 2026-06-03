#requires -Version 7.4
# Cross-platform: the PURE manual-tasks config parser and the provider it
# feeds, isolated from the file system. Loaded via Import-Module (not
# dot-source) so the provider's GetPlan closure -- built with .GetNewClosure(),
# which resolves functions against global scope -- can find the exported domain
# factories it calls. (See WindowsMaintenance.psm1 for why everything exports.)

BeforeAll {
  $repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
  Import-Module (Join-Path $repo 'WindowsMaintenance.psd1') -Force
}

Describe 'ConvertFrom-ManualTaskConfig' {
  It 'parses name, category and optional url' {
    $json = @'
{ "manualTasks": [ { "name": "MSI X670E BIOS", "category": "Updates", "url": "https://msi.com/bios" } ] }
'@
    $t = @(ConvertFrom-ManualTaskConfig -Json $json)
    $t.Count       | Should -Be 1
    $t[0].Name     | Should -Be 'MSI X670E BIOS'
    $t[0].Category | Should -Be 'Updates'
    $t[0].Url      | Should -Be 'https://msi.com/bios'
  }
  It 'defaults category to Other and url to null when omitted' {
    $t = @(ConvertFrom-ManualTaskConfig -Json '{ "manualTasks": [ { "name": "Microsoft Store" } ] }')
    $t[0].Category | Should -Be 'Other'
    $t[0].Url      | Should -BeNullOrEmpty
  }
  It 'skips items without a name' {
    $t = @(ConvertFrom-ManualTaskConfig -Json '{ "manualTasks": [ { "url": "https://x" }, { "name": "Keep" } ] }')
    $t.Count   | Should -Be 1
    $t[0].Name | Should -Be 'Keep'
  }
  It 'returns nothing for empty or task-less input' {
    @(ConvertFrom-ManualTaskConfig -Json '')                       | Should -BeNullOrEmpty
    @(ConvertFrom-ManualTaskConfig -Json '{ "manualTasks": [] }')  | Should -BeNullOrEmpty
  }
  It 'throws on malformed JSON so the caller can degrade' {
    { ConvertFrom-ManualTaskConfig -Json '{ not json' } | Should -Throw
  }
}

Describe 'New-ManualTaskProvider' {
  It 'builds a ManualAdvisory provider whose plan carries the categorised advisory' {
    $p = New-ManualTaskProvider -Name 'Microsoft Store' -Category 'Updates'
    $p.Target.Kind.ToString() | Should -Be 'ManualAdvisory'
    $p.Target.Id              | Should -Be 'manual:microsoft-store'
    $plan = & $p.GetPlan ([pscustomobject]@{})
    $plan.Advisory.Name     | Should -Be 'Microsoft Store'
    $plan.Advisory.Category | Should -Be 'Updates'
    $plan.Advisory.Link     | Should -BeNullOrEmpty
  }
}
