#requires -Version 7.4
# Cross-platform: building a provider only constructs the port object (the
# COM/winget/CIM work happens inside GetPlan/Apply, which we don't invoke
# here). So we can assert every reference adapter satisfies the IUpdateProvider
# shape anywhere.

BeforeAll {
  $repo   = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
  $domain = Join-Path $repo 'src' 'domain'
  foreach ($f in 'Enums', 'ValueObjects', 'Outcome', 'Decisions', 'Projections', 'Formatting')
  {
    . (Join-Path $domain "$f.ps1")
  }
  . (Join-Path $repo 'src' 'ports' 'Ports.ps1')
  foreach ($a in 'RebootDetection', 'Wua.OsUpdateProvider', 'Winget.AppProvider',
    'Defender.SignatureProvider', 'ManualTask.Provider')
  {
    . (Join-Path $repo 'src' 'adapters' "$a.ps1")
  }
  function Assert-ValidProvider
  {
    param($Port, [string]$ExpectedId)
    { Confirm-Port -Port $Port -PSTypeName 'WindowsMaintenance.Port.UpdateProvider' -Members 'GetPlan', 'Apply' } |
      Should -Not -Throw
    $Port.Target.Id | Should -Be $ExpectedId
  }
}

Describe 'Reference provider factories produce well-formed IUpdateProvider ports' {
  It 'WUA OS update provider' { Assert-ValidProvider (New-WuaOsUpdateProvider) 'windows-update' }
  It 'winget app provider (curated)' {
    Assert-ValidProvider (New-WingetAppProvider -PackageId @('Example.App')) 'winget'
  }
  It 'winget app provider (all)' { Assert-ValidProvider (New-WingetAppProvider -All) 'winget' }
  It 'Defender provider' { Assert-ValidProvider (New-DefenderSignatureProvider) 'defender' }
  It 'manual task provider' {
    $p = New-ManualTaskProvider -Name 'MSI X670E BIOS' -Url 'https://msi.com/bios'
    Assert-ValidProvider $p 'manual:msi-x670e-bios'
    $p.Target.Kind.ToString()                | Should -Be 'ManualAdvisory'
    $p.Target.Capabilities.RequiresElevation | Should -BeFalse   # advisories never need elevation
  }
}
