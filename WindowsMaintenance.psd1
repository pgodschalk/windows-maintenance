@{
  RootModule        = 'WindowsMaintenance.psm1'
  ModuleVersion     = '1.0.0'
  GUID              = '5c3a2ea7-0127-4bc3-89ed-f3f9e38b7954'
  Author            = 'Patrick Godschalk'
  Copyright         = '(c) Patrick Godschalk. EUPL-1.2 license.'
  Description       = 'Updates Windows and installed apps, runs silent health checks, and lists manual tasks.'
  PowerShellVersion = '7.4'

  # Export everything. This is an APPLICATION module (driven by
  # Invoke-WindowsMaintenance.ps1, never consumed as a library), and the
  # closure-record port pattern REQUIRES it: a provider's GetPlan/Apply
  # scriptblocks are produced with .GetNewClosure(), which rebinds them to a
  # new dynamic module whose unqualified function lookup falls back to the
  # GLOBAL scope -- so every domain factory / helper a closure calls
  # (New-UpdatePlan, New-UpdateResult, ...) must be in scope after
  # Import-Module, i.e. exported. A wildcard also preserves the framework's
  # core property: adding a target stays "one adapter file + one registry
  # line" with no export edits.
  FunctionsToExport = '*'
  CmdletsToExport   = @()
  VariablesToExport = @()
  AliasesToExport   = @()

  PrivateData       = @{
    PSData = @{
      Tags         = @('Windows', 'Updates', 'winget', 'WindowsUpdate', 'Defender', 'Maintenance')
      ProjectUri   = ''
      ReleaseNotes = 'WUA, winget, Defender, silent maintenance checks, encrypted backup, and manual tasks.'
    }
  }
}
