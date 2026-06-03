#requires -Version 7.4
#
# Clock adapter (driven). The only place in the system that reads wall-clock
# time, so the pure core can stay deterministic (time is injected).
# DateTimeOffset = unambiguous instants.
# Depends on: Ports.ps1.

function New-SystemClock
{
  [CmdletBinding()]
  param()
  New-ClockPort -Now { [datetimeoffset]::Now }
}
