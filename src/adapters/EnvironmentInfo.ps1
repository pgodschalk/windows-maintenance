#requires -Version 7.4
#
# Environment adapter (driven). Reads host/deployment facts once and builds the
# immutable Environment value object the pure core consumes. Also exposes the
# elevation/interactivity probes the composition root uses for preconditions.
# Depends on: ValueObjects.ps1 (New-EnvironmentInfo).

function Test-IsElevated
{
  [OutputType([bool])]
  param()
  if (-not $IsWindows)
  {
    return $false
  }
  $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($identity)
  $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-IsInteractive
{
  [OutputType([bool])]
  param()
  # A scheduled/service session is not UserInteractive; a piped console has
  # redirected input.
  [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
}

function Get-EnvironmentInfo
{
  # Build the Environment VO. Pure-ish in spirit but lives in the shell because
  # it reads the machine. The version comes from the caller (the module
  # manifest), not hardcoded.
  [CmdletBinding()]
  param([string] $ScriptVersion = '0.0.0')

  $osBuild = 'unknown'; $osVersion = 'unknown'; $locale = ''; $region = ''

  if ($IsWindows)
  {
    try
    {
      $os  = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
      $cvPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
      $cv  = Get-ItemProperty -Path $cvPath -ErrorAction SilentlyContinue
      $ubr = $cv.UBR
      $osBuild   = $ubr ? "$($os.BuildNumber).$ubr" : [string]$os.BuildNumber
      $osVersion = ((@($os.Caption, $cv.DisplayVersion) | Where-Object { $_ }) -join ' ').Trim()
    } catch
    {
      Write-Verbose "could not read OS build/version: $_"
    }
  } else
  {
    $osVersion = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
    $osBuild   = [string][Environment]::OSVersion.Version
  }

  try
  {
    $locale = (Get-Culture).Name
  } catch
  {
    Write-Verbose "locale read failed: $_"
  }
  try
  {
    $region = [System.Globalization.RegionInfo]::new((Get-Culture).Name).TwoLetterISORegionName
  } catch
  {
    $region = ''
  }

  New-EnvironmentInfo `
    -OsBuild $osBuild -OsVersion $osVersion -PsVersion ($PSVersionTable.PSVersion.ToString()) `
    -ScriptVersion $ScriptVersion -IsElevated (Test-IsElevated) -IsInteractive (Test-IsInteractive) `
    -Locale $locale -Region $region
}
