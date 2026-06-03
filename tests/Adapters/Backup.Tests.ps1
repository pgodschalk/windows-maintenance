#requires -Version 7.4
# Cross-platform: the PURE backup helpers (config parse, restic arg/exit-code
# logic) and the provider shape. The impure bits (op read, restic) verify on
# Windows.

BeforeAll {
  # Import-Module (not dot-source): the provider's GetPlan closure is built
  # with .GetNewClosure(), which resolves functions against global scope, so
  # the exported domain factories it calls must come in via the module. (See
  # WindowsMaintenance.psm1.)
  $repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
  Import-Module (Join-Path $repo 'WindowsMaintenance.psd1') -Force
}

Describe 'ConvertFrom-ResticExitCode' {
  It 'maps 0 -> Succeeded, 3 -> Partial, anything else -> Failed' {
    ConvertFrom-ResticExitCode -Code 0 | Should -Be 'Succeeded'
    ConvertFrom-ResticExitCode -Code 3 | Should -Be 'Partial'
    ConvertFrom-ResticExitCode -Code 1 | Should -Be 'Failed'
  }
}

Describe 'Get-ResticBackupArgs' {
  It 'includes backup, the tag, excludes, and the paths' {
    $a = @(Get-ResticBackupArgs -Paths @('C:\a', 'C:\b') -Exclude @('*.tmp'))
    $a[0]          | Should -Be 'backup'
    ($a -join ' ') | Should -Match '--tag windows-maintenance'
    ($a -join ' ') | Should -Match '--exclude \*\.tmp'
    $a             | Should -Contain 'C:\a'
    $a             | Should -Contain 'C:\b'
  }
}

Describe 'Get-ResticForgetArgs' {
  It 'builds forget --prune with the keep rules' {
    $a = (@(Get-ResticForgetArgs -Retention ([pscustomobject]@{ keepDaily = 7; keepWeekly = 4 })) -join ' ')
    $a | Should -Match 'forget --prune'
    $a | Should -Match '--keep-daily 7'
    $a | Should -Match '--keep-weekly 4'
  }
  It 'returns nothing when no retention is configured' {
    Get-ResticForgetArgs -Retention $null | Should -BeNullOrEmpty
  }
  It 'refuses to prune with no keep rules (that would delete everything)' {
    Get-ResticForgetArgs -Retention ([pscustomobject]@{}) | Should -BeNullOrEmpty
  }
}

Describe 'ConvertFrom-BackupConfig' {
  It 'parses a valid config (secrets stay as op:// references)' {
    $json = @'
{ "repository": "s3:https://h/b", "paths": ["C:\\x"], "insecureTls": true,
  "secrets": { "resticPassword": "op://v/i/password", "awsAccessKeyId": "op://v/i/akid",
               "awsSecretAccessKey": "op://v/i/sec" } }
'@
    $c = ConvertFrom-BackupConfig -Json $json
    $c.Repository             | Should -Be 's3:https://h/b'
    $c.Paths                  | Should -Contain 'C:\x'
    $c.InsecureTls            | Should -BeTrue
    $c.Secrets.ResticPassword | Should -Be 'op://v/i/password'
  }
  It 'throws when repository is missing' {
    { ConvertFrom-BackupConfig -Json '{ "paths": [], "secrets": { "resticPassword": "op://x" } }' } | Should -Throw
  }
  It 'throws when the restic password reference is missing' {
    { ConvertFrom-BackupConfig -Json '{ "repository": "s3:.." , "secrets": {} }' } | Should -Throw
  }
}

Describe 'New-BackupProvider' {
  It 'is a well-formed alert-only port' {
    $p = New-BackupProvider -ConfigPath 'C:\nope\backup-config.json'
    { Confirm-Port -Port $p -PSTypeName 'WindowsMaintenance.Port.UpdateProvider' -Members 'GetPlan', 'Apply' } |
      Should -Not -Throw
    $p.Target.Id                     | Should -Be 'backup'
    $p.Target.Capabilities.AlertOnly | Should -BeTrue
  }
  It 'plans NothingToDo when no config file is present (silent when not set up)' {
    $missing = Join-Path ([System.IO.Path]::GetTempPath()) "no-such-$([guid]::NewGuid()).json"
    $plan = & (New-BackupProvider -ConfigPath $missing).GetPlan ([pscustomobject]@{})
    @($plan.Items).Count | Should -Be 0
  }
}
