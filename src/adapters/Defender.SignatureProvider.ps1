#requires -Version 7.4
#
# Microsoft Defender signature provider (driven, Automated). Update-MpSignature
# is quiet on success and throws on failure, so "did anything change / nothing
# to do" is decided by comparing the signature version before and after.
# Depends on: ValueObjects.ps1, Ports.ps1.

function New-DefenderSignatureProvider
{
  [CmdletBinding()]
  param()

  $target = New-UpdateTarget -Id 'defender' -DisplayName 'Defender Signatures' -Kind 'Automated'

  # A single placeholder item so the core decides Proceed; whether anything
  # actually changed is determined in Apply by the version comparison.
  $getPlan = {
    param($ctx)
    New-UpdatePlan -Items @(
      New-UpdateItem -Id 'defender-signatures' -Name 'Defender security intelligence' -To 'latest'
    )
  }.GetNewClosure()

  $apply = {
    param($ctx, $plan)
    $sw     = [System.Diagnostics.Stopwatch]::StartNew()
    $before = (Get-MpComputerStatus -ErrorAction Stop).AntivirusSignatureVersion
    Update-MpSignature -ErrorAction Stop | Out-Null
    $after  = (Get-MpComputerStatus -ErrorAction Stop).AntivirusSignatureVersion

    if ([string]$after -ne [string]$before)
    {
      $item = New-UpdateItem -Id 'defender-signatures' -Name 'Defender security intelligence' `
        -From ([string]$before) -To ([string]$after)
      $ms = $sw.ElapsedMilliseconds
      New-UpdateResult -Target $target -Outcome 'Succeeded' -ItemsApplied @($item) -DurationMs $ms
    } else
    {
      New-UpdateResult -Target $target -Outcome 'NothingToDo' -DurationMs $sw.ElapsedMilliseconds
    }
  }.GetNewClosure()

  New-UpdateProviderPort -Target $target -GetPlan $getPlan -Apply $apply
}
