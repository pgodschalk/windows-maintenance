#requires -Version 7.4
# Cross-platform: file-based state store round-trip and graceful degradation.

BeforeAll {
  $repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
  . (Join-Path $repo 'src' 'ports' 'Ports.ps1')
  . (Join-Path $repo 'src' 'adapters' 'JsonStateStore.ps1')

  function New-TempPath
  {
    Join-Path ([System.IO.Path]::GetTempPath()) ("wu-test-$([guid]::NewGuid()).json")
  }
}

Describe 'JsonStateStore' {
  It 'reports first-run (null record, not corrupt) when the file is absent' {
    $store = New-JsonStateStore -Path (New-TempPath)
    $r = & $store.Load
    $r.Record  | Should -BeNullOrEmpty
    $r.Corrupt | Should -BeFalse
  }
  It 'round-trips a saved record' {
    $path  = New-TempPath
    $store = New-JsonStateStore -Path $path
    try
    {
      & $store.Save ([pscustomobject]@{ outcome = 'Succeeded'; updates_applied_total = 3 })
      $loaded = (& $store.Load).Record
      $loaded.outcome               | Should -Be 'Succeeded'
      $loaded.updates_applied_total | Should -Be 3
    } finally
    {
      Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
    }
  }
  It 'flags a corrupt file and degrades to first-run rather than throwing' {
    $path = New-TempPath
    Set-Content -LiteralPath $path -Value '{ not valid json' -Encoding utf8
    try
    {
      $r = & (New-JsonStateStore -Path $path).Load
      $r.Corrupt | Should -BeTrue
      $r.Record  | Should -BeNullOrEmpty
    } finally
    {
      Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
    }
  }
  It 'creates missing parent directories on save' {
    $dir   = Join-Path ([System.IO.Path]::GetTempPath()) "wu-test-$([guid]::NewGuid())"
    $path  = Join-Path $dir 'nested' 'state.json'
    $store = New-JsonStateStore -Path $path
    try
    {
      & $store.Save ([pscustomobject]@{ outcome = 'NothingToDo' })
      Test-Path -LiteralPath $path | Should -BeTrue
    } finally
    {
      Remove-Item -LiteralPath $dir -Recurse -ErrorAction SilentlyContinue
    }
  }
}
