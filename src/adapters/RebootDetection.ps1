#requires -Version 7.4
#
# Shared reboot-pending probe used by the automated providers to set their
# reboot flag. Aggregates the WUA system signal with the canonical
# pending-reboot registry markers. Windows-only; returns $false elsewhere so
# the core stays portable for testing.

function Test-RebootPending
{
  [OutputType([bool])]
  [CmdletBinding()]
  param()
  if (-not $IsWindows)
  {
    return $false
  }

  try
  {
    if ((New-Object -ComObject 'Microsoft.Update.SystemInfo').RebootRequired)
    {
      return $true
    }
  } catch
  {
    Write-Verbose "WUA reboot probe unavailable: $_"
  }

  $keys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
  )
  foreach ($k in $keys)
  {
    if (Test-Path -LiteralPath $k)
    {
      return $true
    }
  }

  $pfro = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
      -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
  [bool]$pfro
}
