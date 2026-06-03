#requires -Version 7.4
#
# Entry-script help guardrail. Invoke-WindowsMaintenance.ps1 is the documented
# entry point -- the README tells users to run
# `Get-Help ./Invoke-WindowsMaintenance.ps1`. PowerShell recognizes a script's
# comment-based help only when a blank line separates `#requires` from the `<#`
# block; remove that blank line (e.g. via a reformat) and Get-Help silently
# falls back to auto-generated syntax, dropping the authored help. The
# analyzer/formatter gate can't see that regression, so this test guards it.
# Get-Help reads comment-based help on any OS -- this is cross-platform.

BeforeAll {
  $repo = Split-Path $PSScriptRoot -Parent
  $script:EntryHelp = Get-Help (Join-Path $repo 'Invoke-WindowsMaintenance.ps1')
}

Describe 'Invoke-WindowsMaintenance.ps1 comment-based help' {
  It 'is the authored help, not auto-generated from the syntax' {
    # Auto-generated help uses the syntax line as the synopsis (it begins with
    # the script name); the authored .SYNOPSIS is prose, so it must not.
    $script:EntryHelp.Synopsis |
      Should -Not -Match '^Invoke-WindowsMaintenance\.ps1' -Because 'a blank line must separate #requires from <#'
  }

  It 'exposes a .DESCRIPTION' {
    $script:EntryHelp.Description |
      Should -Not -BeNullOrEmpty -Because 'recognized comment-based help populates .DESCRIPTION'
  }
}
