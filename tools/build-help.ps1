#requires -Version 7.4
<#
.SYNOPSIS
  Builds the module's external help from the PlatyPS markdown in docs/help. The
  MAML (en-US/) is produced on any OS and is shipped in the module so Get-Help
  works offline. On Windows it also builds the updatable-help CAB +
  HelpInfo.xml that CI publishes to the HelpInfoUri (GitHub Pages).
.EXAMPLE
  pwsh tools/build-help.ps1 -Install
#>
[CmdletBinding()]
param(
  [switch] $Install,
  [string] $OutputPath
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$docs = Join-Path $repo 'docs' 'help'
$maml = Join-Path $repo 'en-US'
if (-not $OutputPath)
{
  $OutputPath = Join-Path $repo 'out' 'help'
}

if (-not (Get-Module -ListAvailable -Name platyPS))
{
  if (-not $Install)
  {
    throw 'platyPS not found. Re-run with -Install, or: Install-Module platyPS -Scope CurrentUser -Force'
  }
  Install-Module platyPS -Scope CurrentUser -Force
}
Import-Module platyPS

# MAML (cross-platform) -- shipped in the module so Get-Help works offline.
New-ExternalHelp -Path $docs -OutputPath $maml -Force | Out-Null
[Console]::Out.WriteLine("Built MAML -> $maml")

if (-not $IsWindows)
{
  Write-Warning 'Skipping CAB + HelpInfo.xml: New-ExternalHelpCab requires MakeCab (Windows only).'
  return
}

# Updatable-help CAB + HelpInfo.xml (Windows only) -- the payload published to
# the HelpInfoUri.
$null = New-Item -ItemType Directory -Path $OutputPath -Force
$landingPage = Join-Path $docs 'WindowsMaintenance.md'
New-ExternalHelpCab -CabFilesFolder $maml -LandingPagePath $landingPage -OutputFolder $OutputPath | Out-Null
[Console]::Out.WriteLine("Built CAB + HelpInfo.xml -> $OutputPath")
