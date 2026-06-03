#requires -Version 7.4
#
# Presenter adapter (driven). The ONE place allowed to be chatty. It only
# WRITES strings the pure core already formatted -- no business logic, no
# Format-* here. Kept separate from the EventSink: human narration (many lines)
# is a different concern from machine telemetry (one event).
# Depends on: Ports.ps1, Formatting.ps1 (Test-ColorEnabled).

function New-ConsolePresenter
{
  [CmdletBinding()]
  param([switch] $Silent)

  # Decide colour ONCE, per stream, from the real environment.
  $noColor  = $null -ne $env:NO_COLOR
  $colorOut = Test-ColorEnabled -NoColor $noColor -Redirected ([Console]::IsOutputRedirected)
  $colorErr = Test-ColorEnabled -NoColor $noColor -Redirected ([Console]::IsErrorRedirected)
  $isSilent = [bool]$Silent

  # Pre-resolve ANSI codes (empty string when colour is off, so interpolation
  # is a no-op).
  $cyan     = $colorOut ? $PSStyle.Foreground.Cyan      : ''
  $resetOut = $colorOut ? $PSStyle.Reset                : ''
  $red      = $colorErr ? $PSStyle.Foreground.BrightRed : ''
  $resetErr = $colorErr ? $PSStyle.Reset                : ''

  New-PresenterPort `
    -ShowLastRun {
    param($Text)
    if (-not $isSilent)
    {
      [Console]::Out.WriteLine("${cyan}${Text}${resetOut}")
    }
  }.GetNewClosure() `
    -ShowProgress {
    param($Text)
    if (-not $isSilent)
    {
      [Console]::Out.WriteLine($Text)
    }
  }.GetNewClosure() `
    -ShowSummary {
    param($Text)
    if (-not $isSilent)
    {
      [Console]::Out.WriteLine(''); [Console]::Out.WriteLine($Text)
    }
  }.GetNewClosure() `
    -ShowAlert {
    param($Text)
    # Always emitted (even under -Silent): something is wrong, and it goes to
    # stderr.
    [Console]::Error.WriteLine("${red}${Text}${resetErr}")
  }.GetNewClosure() `
    -ConfirmReboot {
    param($Prompt)
    if ($isSilent)
    {
      return $false
    }   # machine mode never auto-reboots
    $yes = [System.Management.Automation.Host.ChoiceDescription]::new('&Yes', 'Restart the computer now')
    $no  = [System.Management.Automation.Host.ChoiceDescription]::new('&No', 'Do not restart now')
    # Default to No (index 1) -- never reboot by accident.
    ($Host.UI.PromptForChoice('Reboot required', $Prompt, @($yes, $no), 1)) -eq 0
  }.GetNewClosure()
}
