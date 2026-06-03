#requires -Version 7.4
# Cross-platform: the PURE winget bits - exit-code interpreter and the
# upgrade-table parser - isolated from the actual winget process.

BeforeAll {
  $repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
  . (Join-Path $repo 'src' 'adapters' 'Winget.AppProvider.ps1')

  # Build a fixed-width line by placing each field at a given column start
  # (mimics winget's aligned table) so the parser's column-offset logic is
  # exercised faithfully.
  function New-FixedWidthLine
  {
    param([string[]] $Fields, [int[]] $Starts)
    $sb = ''
    for ($k = 0; $k -lt $Fields.Count; $k++)
    {
      if ($sb.Length -lt $Starts[$k])
      {
        $sb = $sb.PadRight($Starts[$k])
      }
      $sb += $Fields[$k]
    }
    $sb
  }
}

Describe 'ConvertFrom-WingetExitCode' {
  It 'maps 0 to an applied success' {
    (ConvertFrom-WingetExitCode -Code 0).Status | Should -Be 'Applied'
  }
  It 'maps 0x8A15002B (no applicable update) to a no-op' {
    (ConvertFrom-WingetExitCode -Code ([long]0x8A15002B)).Status | Should -Be 'NoOp'
  }
  It 'normalises the signed-int form of a high unsigned code' {
    $signed = [long]0x8A15002B - 0x100000000
    (ConvertFrom-WingetExitCode -Code $signed).Status | Should -Be 'NoOp'
  }
  It 'flags reboot-required codes' {
    (ConvertFrom-WingetExitCode -Code ([long]0x8A150109)).Reboot | Should -BeTrue
  }
  It 'treats unknown non-zero codes as failure' {
    (ConvertFrom-WingetExitCode -Code 1).Status | Should -Be 'Failed'
  }
}

Describe 'ConvertFrom-WingetUpgradeTable' {
  BeforeAll {
    $starts = @(0, 21, 47, 61, 74)
    $header = New-FixedWidthLine @('Name', 'Id', 'Version', 'Available', 'Source') $starts
    $row1   = New-FixedWidthLine @('Mozilla Firefox', 'Mozilla.Firefox', '138.0', '139.0', 'winget') $starts
    $row2   = New-FixedWidthLine @('Git', 'Git.Git', '2.49.0', '2.50.0', 'winget') $starts
  }
  It 'parses ids and from/to versions by column position' {
    $out = @($header, ('-' * 86), $row1, $row2, '', '2 upgrades available.')
    $r = @(ConvertFrom-WingetUpgradeTable -Output $out)
    $r.Count            | Should -Be 2
    $r[0].Id            | Should -Be 'Mozilla.Firefox'
    $r[0].Name          | Should -Be 'Mozilla Firefox'   # internal space preserved
    $r[0].Version       | Should -Be '138.0'
    $r[0].Available     | Should -Be '139.0'
    $r[1].Id            | Should -Be 'Git.Git'
  }
  It 'recognises a Unicode box-drawing separator (locale/rendering robustness)' {
    $out = @($header, ([string][char]0x2500 * 86), $row1)
    (@(ConvertFrom-WingetUpgradeTable -Output $out))[0].Id | Should -Be 'Mozilla.Firefox'
  }
  It 'returns nothing when there is no table (e.g. all up to date)' {
    @(ConvertFrom-WingetUpgradeTable -Output @('No installed package found matching input criteria.')) |
      Should -BeNullOrEmpty
  }
  It 'parses a second section (explicit-targeting group)' {
    $row3 = New-FixedWidthLine @('Some Tool', 'Vendor.Tool', 'Unknown', '5.0', 'winget') $starts
    $out  = @(
      $header, ('-' * 86), $row1, '',
      'The following packages require explicit targeting:', '',
      $header, ('-' * 86), $row3, '', '2 upgrades available.'
    )
    $ids = @(ConvertFrom-WingetUpgradeTable -Output $out).Id
    $ids | Should -Contain 'Mozilla.Firefox'
    $ids | Should -Contain 'Vendor.Tool'
  }
}
