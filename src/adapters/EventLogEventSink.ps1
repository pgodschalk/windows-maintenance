#requires -Version 7.4
#
# Event sink adapter (driven). Emits the ONE canonical wide event per run to a
# custom Windows Event Log source, with the compact JSON as the message. Uses
# the .NET System.Diagnostics .EventLog API directly (the New-EventLog /
# Write-EventLog cmdlets do not exist in PS 7).
#
# If the source can't be registered (e.g. an unelevated first run) or the write
# fails (or the platform has no Windows Event Log), it degrades to stderr so
# the event is never lost and Emit never throws.
# Depends on: Ports.ps1.

function New-EventLogEventSink
{
  [CmdletBinding()]
  param(
    [string] $LogName = 'WindowsMaintenance',
    [string] $Source  = 'WindowsMaintenance'
  )

  $emit = {
    param($EventObject)
    $json = $EventObject | ConvertTo-Json -Depth 8 -Compress
    try
    {
      if (-not [System.Diagnostics.EventLog]::SourceExists($Source))
      {
        [System.Diagnostics.EventLog]::CreateEventSource($Source, $LogName)   # one-time; needs admin
      }
      $entryType = switch ($EventObject.outcome)
      {
        'Failed'
        {
          [System.Diagnostics.EventLogEntryType]::Error
        }
        'ManualActionRequired'
        {
          [System.Diagnostics.EventLogEntryType]::Warning
        }
        default
        {
          $EventObject.reboot_required `
            ? [System.Diagnostics.EventLogEntryType]::Warning `
            : [System.Diagnostics.EventLogEntryType]::Information
        }
      }
      $eventId = switch ($EventObject.outcome)
      {
        'Failed'
        {
          1002
        }
        'ManualActionRequired'
        {
          1001
        }
        default
        {
          1000
        }
      }
      [System.Diagnostics.EventLog]::WriteEntry($Source, $json, $entryType, $eventId)
    } catch
    {
      # Telemetry transport must never crash a run - fall back to stderr.
      [Console]::Error.WriteLine("windows-maintenance-event: $json")
    }
  }.GetNewClosure()

  New-EventSinkPort -Emit $emit
}
