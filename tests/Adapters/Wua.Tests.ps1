#requires -Version 7.4
# Cross-platform: the PURE Windows-Update search-criteria builder, isolated
# from the COM call. Policy: install everything Windows Update offers EXCEPT
# drivers (managed separately / blocked by AtlasOS). Optional/preview quality &
# feature updates are NOT filtered out - only drivers are.

BeforeAll {
  $repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
  . (Join-Path $repo 'src' 'adapters' 'Wua.OsUpdateProvider.ps1')
}

Describe 'Get-WuaSearchCriteria' {
  It 'excludes drivers by default (Type=Software), keeping all other software updates' {
    $c = Get-WuaSearchCriteria -IncludeDrivers $false
    $c | Should -Match "Type='Software'"
    $c | Should -Match 'IsInstalled=0'
    $c | Should -Match 'IsHidden=0'
  }
  It 'does not restrict Type when drivers are explicitly opted in' {
    $c = Get-WuaSearchCriteria -IncludeDrivers $true
    $c | Should -Not -Match 'Type='
    $c | Should -Match 'IsInstalled=0'
    $c | Should -Match 'IsHidden=0'
  }
  It 'never filters BrowseOnly/optional in the query (so optional & preview updates are included)' {
    (Get-WuaSearchCriteria -IncludeDrivers $false) | Should -Not -Match 'BrowseOnly'
    (Get-WuaSearchCriteria -IncludeDrivers $true)  | Should -Not -Match 'BrowseOnly'
  }
}
