#requires -Version 7.4
<#
.SYNOPSIS
    The quality gate: PSScriptAnalyzer (settings-driven), an Invoke-Formatter
    check, then the Pester suite. Domain/application/most adapter tests are
    OS-agnostic; only WUA/Defender/Event Log behaviour needs Windows.
.EXAMPLE
    pwsh tools/run-tests.ps1 -Install
.EXAMPLE
    pwsh tools/run-tests.ps1 -SkipLint   # run the tests only
#>
[CmdletBinding()]
param(
  [string] $Path = (Join-Path (Split-Path $PSScriptRoot -Parent) 'tests'),
  [switch] $Install,
  [switch] $SkipLint
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent

function Write-Line
{
  param([string] $Text) [Console]::Out.WriteLine($Text)
}

function Install-IfMissing
{
  param([Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][string] $MinVersion)
  $have = Get-Module -ListAvailable -Name $Name |
    Where-Object { $_.Version -ge [version]$MinVersion } | Select-Object -First 1
  if ($have)
  {
    return
  }
  if (-not $Install)
  {
    $hint = "Install-Module $Name -MinimumVersion $MinVersion -Scope CurrentUser -Force"
    throw "$Name $MinVersion+ not found. Re-run with -Install, or: $hint"
  }
  Install-Module $Name -MinimumVersion $MinVersion -Scope CurrentUser -Force -SkipPublisherCheck
}

if (-not $SkipLint)
{
  $settings = Join-Path $repo 'PSScriptAnalyzerSettings.psd1'
  Install-IfMissing -Name PSScriptAnalyzer -MinVersion '1.21.0'
  Import-Module PSScriptAnalyzer -MinimumVersion 1.21.0

  Write-Line 'PSScriptAnalyzer...'
  $findings = Invoke-ScriptAnalyzer -Path $repo -Recurse -Settings $settings
  if ($findings)
  {
    Write-Line (($findings | Format-Table -AutoSize | Out-String))
    throw "PSScriptAnalyzer reported $(@($findings).Count) finding(s)."
  }

  Write-Line 'Invoke-Formatter (format check)...'
  $files = Get-ChildItem -Path $repo -Recurse -Include *.ps1, *.psm1, *.psd1 |
    Where-Object FullName -notlike '*/.git/*'
  $unformatted = [System.Collections.Generic.List[string]]::new()
  foreach ($file in $files)
  {
    $orig = Get-Content -Raw -LiteralPath $file.FullName
    if ([string]::IsNullOrEmpty($orig))
    {
      continue
    }
    if ((Invoke-Formatter -ScriptDefinition $orig -Settings $settings) -ne $orig)
    {
      $unformatted.Add($file.FullName)
    }
  }
  if ($unformatted.Count -gt 0)
  {
    $unformatted | ForEach-Object { Write-Line $_ }
    throw "$($unformatted.Count) file(s) are not formatted (run Invoke-Formatter with the repo settings)."
  }
}

Install-IfMissing -Name Pester -MinVersion '5.0.0'
Import-Module Pester -MinimumVersion 5.0.0

$config = New-PesterConfiguration
$config.Run.Path = $Path
$config.Run.Exit = $true
$config.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $config
