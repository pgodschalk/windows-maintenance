#requires -Version 7.4
#
# State store adapter (driven). Persists the trimmed InvocationRecord as JSON
# so the next run can render the "last run" line. Load maps "file absent" ->
# first run (Record null, not corrupt) and "unreadable" -> corrupt (Record
# null, corrupt true), never throwing - losing last-run memory must never block
# doing updates.
# Depends on: Ports.ps1. (File I/O only)

function New-JsonStateStore
{
  [CmdletBinding()]
  param([Parameter(Mandatory)][string] $Path)

  $load = {
    if (-not (Test-Path -LiteralPath $Path))
    {
      return [pscustomobject]@{ Record = $null; Corrupt = $false }
    }
    try
    {
      $record = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
      [pscustomobject]@{ Record = $record; Corrupt = $false }
    } catch
    {
      [pscustomobject]@{ Record = $null; Corrupt = $true }
    }
  }.GetNewClosure()

  $save = {
    param($Record)
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir))
    {
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $json = $Record | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $Path -Value $json -Encoding utf8 -ErrorAction Stop
  }.GetNewClosure()

  New-StateStorePort -Load $load -Save $save
}
