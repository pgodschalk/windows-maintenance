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
  It 'preserves the timestamp date under a dd/MM locale (regression: month/day swap)' {
    $path    = New-TempPath
    $store   = New-JsonStateStore -Path $path
    $iso     = ([datetimeoffset]::new(2026, 6, 3, 10, 0, 0, [timespan]::FromHours(2))).ToString('o')
    $culture = [System.Threading.Thread]::CurrentThread.CurrentCulture
    try
    {
      & $store.Save ([pscustomobject]@{ outcome = 'Succeeded'; timestamp = $iso })
      # Load + parse under a day-month-first locale, exactly as the app does.
      [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::new('nl-NL')
      $when = [datetimeoffset]::Parse([string]((& $store.Load).Record.timestamp))
      $when.Month | Should -Be 6 -Because '3 June (06-03) must not be read back as 6 March'
      $when.Day   | Should -Be 3
    } finally
    {
      [System.Threading.Thread]::CurrentThread.CurrentCulture = $culture
      Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
    }
  }
}
