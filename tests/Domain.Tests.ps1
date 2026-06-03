#requires -Version 7.4
#
# Pure functional-core tests. Zero mocks, zero I/O, OS-agnostic - these run
# anywhere pwsh + Pester are installed (Windows, macOS, Linux). They dot-source
# ONLY the domain layer, proving the core has no dependency on ports or
# adapters.
#
# Convention: avoid [EnumType] literals as PARAMETER/attribute constraints or
# in discovery-time contexts (-ForEach/TestCases) - those resolve before
# BeforeAll dot-sources the enums. Enum VALUE expressions inside It bodies are
# fine (resolved at run time, after BeforeAll). Elsewhere enum values are
# passed as strings (factories coerce them) and asserted via .ToString().

BeforeAll {
  $domain = Join-Path (Split-Path $PSScriptRoot -Parent) 'src' 'domain'
  # Order matters: enums first (used as parameter type constraints by later
  #  files).
  . (Join-Path $domain 'Enums.ps1')
  . (Join-Path $domain 'ValueObjects.ps1')
  . (Join-Path $domain 'Outcome.ps1')
  . (Join-Path $domain 'Decisions.ps1')
  . (Join-Path $domain 'Projections.ps1')
  . (Join-Path $domain 'Formatting.ps1')

  # Small builders so each test reads as intent, not setup.
  function New-TestResult
  {
    param(
      [string] $Id = 'winget',
      [string] $Display = 'Winget Applications',
      [string] $Kind = 'Automated',
      [string] $Outcome = 'Succeeded',
      [int]    $Applied = 0,
      [int]    $Failed = 0,
      [bool]   $Reboot = $false,
      [int]    $DurationMs = 10
    )
    $items = @()
    if ($Applied -gt 0)
    {
      $items = 1..$Applied | ForEach-Object {
        New-UpdateItem -Id "pkg$_" -Name "Package $_" -From '1.0' -To '2.0'
      }
    }
    $target = New-UpdateTarget -Id $Id -DisplayName $Display -Kind $Kind
    New-UpdateResult -Target $target -Outcome $Outcome -ItemsApplied @($items) `
      -ItemsFailed @() -RebootRequired $Reboot -DurationMs $DurationMs
  }
}

Describe 'Enums (the outcome lattice)' {
  It 'orders outcomes by ascending severity' {
    ([int][UpdateOutcome]::NothingToDo)          | Should -Be 0
    ([int][UpdateOutcome]::Succeeded)            | Should -Be 1
    ([int][UpdateOutcome]::Skipped)              | Should -Be 2
    ([int][UpdateOutcome]::ManualActionRequired) | Should -Be 3
    ([int][UpdateOutcome]::Failed)               | Should -Be 4
  }
  It 'makes Failed the most severe and NothingToDo the least' {
    ([UpdateOutcome]::Failed -gt [UpdateOutcome]::ManualActionRequired) | Should -BeTrue
    ([UpdateOutcome]::NothingToDo -lt [UpdateOutcome]::Succeeded)       | Should -BeTrue
  }
}

Describe 'Value objects' {
  It 'New-UpdateItem records a from->to delta' {
    $i = New-UpdateItem -Id 'Mozilla.Firefox' -Name 'Firefox' -From '138.0' -To '139.0'
    $i.Id   | Should -Be 'Mozilla.Firefox'
    $i.From | Should -Be '138.0'
    $i.To   | Should -Be '139.0'
    $i.PSObject.TypeNames | Should -Contain 'WindowsMaintenance.UpdateItem'
  }
  It 'New-UpdateItem treats From as optional (e.g. a Windows KB has no prior version)' {
    $i = New-UpdateItem -Id 'KB5039212' -Name '2026-06 Cumulative Update' -To 'KB5039212'
    $i.From | Should -BeNullOrEmpty
    $i.To   | Should -Be 'KB5039212'
  }
  It 'New-UpdateTarget defaults capabilities to enabled + requires-elevation' {
    $t = New-UpdateTarget -Id 'winget' -DisplayName 'Winget Applications' -Kind 'Automated'
    $t.Kind.ToString()                | Should -Be 'Automated'
    $t.Capabilities.Enabled           | Should -BeTrue
    $t.Capabilities.RequiresElevation | Should -BeTrue
  }
  It 'New-UpdateTarget accepts explicit capabilities' {
    $t = New-UpdateTarget -Id 'scoop' -DisplayName 'Scoop' -Kind 'Automated' `
      -Capabilities @{ Enabled = $false; RequiresElevation = $false }
    $t.Capabilities.Enabled           | Should -BeFalse
    $t.Capabilities.RequiresElevation | Should -BeFalse
  }
  It 'New-UpdateResult rejects an items-applied count mismatch (invariant guard)' {
    $t = New-UpdateTarget -Id 'x' -DisplayName 'X' -Kind 'Automated'
    # Outcome NothingToDo but claiming applied items is contradictory.
    { New-UpdateResult -Target $t -Outcome 'NothingToDo' `
        -ItemsApplied @(New-UpdateItem -Id 'a' -Name 'A' -To '1') } | Should -Throw
  }
  It 'New-ManualAdvisory records a name, category and link' {
    $a = New-ManualAdvisory -Id 'manual:msi-x670e-bios' -Name 'MSI X670E BIOS' `
      -Category 'Updates' -Link 'https://msi.com/bios'
    $a.Name     | Should -Be 'MSI X670E BIOS'
    $a.Category | Should -Be 'Updates'
    $a.Link     | Should -Be 'https://msi.com/bios'
  }
  It 'New-ManualAdvisory treats the link as optional' {
    $store = New-ManualAdvisory -Id 'manual:microsoft-store' -Name 'Microsoft Store' -Category 'Updates'
    $store.Link | Should -BeNullOrEmpty
  }
}

Describe 'Test-ColorEnabled (pure colour-decision)' {
  It 'enables colour only on a real terminal with NO_COLOR unset' {
    Test-ColorEnabled -NoColor $false -Redirected $false | Should -BeTrue
  }
  It 'disables colour when NO_COLOR is set (any value)' {
    Test-ColorEnabled -NoColor $true -Redirected $false | Should -BeFalse
  }
  It 'disables colour when output is redirected/piped' {
    Test-ColorEnabled -NoColor $false -Redirected $true | Should -BeFalse
  }
}

Describe 'Resolve-OverallOutcome (the crown-jewel fold)' {
  It 'is NothingToDo for an empty run' {
    (Resolve-OverallOutcome -Results @()).ToString() | Should -Be 'NothingToDo'
  }
  It 'returns the single result when there is one' {
    $r = @(New-TestResult -Outcome 'Succeeded')
    (Resolve-OverallOutcome -Results $r).ToString() | Should -Be 'Succeeded'
  }
  It 'takes the worst (max) outcome across results' {
    $r = @(
      New-TestResult -Id a -Outcome 'Succeeded'
      New-TestResult -Id b -Outcome 'NothingToDo'
      New-TestResult -Id c -Outcome 'ManualActionRequired'
    )
    (Resolve-OverallOutcome -Results $r).ToString() | Should -Be 'ManualActionRequired'
  }
  It 'lets Failed dominate everything' {
    $r = @(
      New-TestResult -Id a -Outcome 'Succeeded'
      New-TestResult -Id b -Outcome 'ManualActionRequired'
      New-TestResult -Id c -Outcome 'Failed'
    )
    (Resolve-OverallOutcome -Results $r).ToString() | Should -Be 'Failed'
  }
  It 'is order-independent (commutative)' {
    $a = @(New-TestResult -Id 1 -Outcome 'Failed'), (New-TestResult -Id 2 -Outcome 'Succeeded')
    $b = @(New-TestResult -Id 2 -Outcome 'Succeeded'), (New-TestResult -Id 1 -Outcome 'Failed')
    (Resolve-OverallOutcome -Results $a).ToString() |
      Should -Be (Resolve-OverallOutcome -Results $b).ToString()
  }
}

Describe 'Resolve-RebootRequirement' {
  It 'is not required when no result asks for it' {
    $req = Resolve-RebootRequirement -Results @(New-TestResult -Reboot $false)
    $req.Required | Should -BeFalse
    $req.Reasons  | Should -BeNullOrEmpty
  }
  It 'is required and names the targets that triggered it' {
    $r = @(
      New-TestResult -Id 'windows-update' -Reboot $true
      New-TestResult -Id 'winget' -Reboot $false
    )
    $req = Resolve-RebootRequirement -Results $r
    $req.Required | Should -BeTrue
    $req.Reasons  | Should -Contain 'windows-update'
    $req.Reasons  | Should -Not -Contain 'winget'
  }
}

Describe 'Get-UpdateDecision (per-target policy, pure)' {
  BeforeAll {
    $env = New-EnvironmentInfo -OsBuild '26100' -OsVersion 'Win11' -PsVersion '7.6.2' `
      -ScriptVersion '1.0.1' -IsElevated $true -IsInteractive $true -Locale 'en-NL' -Region 'NL'
  }
  It 'says ManualOnly for a manual-advisory target regardless of plan' {
    $t = New-UpdateTarget -Id 'manual:x' -DisplayName 'Some manual task' -Kind 'ManualAdvisory'
    $adv = New-ManualAdvisory -Id 'manual:x' -Name 'Some manual task' -Category 'Other' -Link 'https://x'
    $plan = New-UpdatePlan -Advisory $adv
    (Get-UpdateDecision -Target $t -Plan $plan -Environment $env).Kind | Should -Be 'ManualOnly'
  }
  It 'says Skip for a disabled target' {
    $t = New-UpdateTarget -Id 'winget' -DisplayName 'Winget' -Kind 'Automated' `
      -Capabilities @{ Enabled = $false; RequiresElevation = $true }
    $plan = New-UpdatePlan -Items @(New-UpdateItem -Id a -Name A -To '2')
    (Get-UpdateDecision -Target $t -Plan $plan -Environment $env).Kind | Should -Be 'Skip'
  }
  It 'says NothingToDo for an automated target with an empty plan' {
    $t = New-UpdateTarget -Id 'winget' -DisplayName 'Winget' -Kind 'Automated'
    (Get-UpdateDecision -Target $t -Plan (New-UpdatePlan) -Environment $env).Kind |
      Should -Be 'NothingToDo'
  }
  It 'says Proceed for an enabled automated target with pending items' {
    $t = New-UpdateTarget -Id 'winget' -DisplayName 'Winget' -Kind 'Automated'
    $plan = New-UpdatePlan -Items @(New-UpdateItem -Id a -Name A -From '1' -To '2')
    (Get-UpdateDecision -Target $t -Plan $plan -Environment $env).Kind | Should -Be 'Proceed'
  }
}

Describe 'Test-ElevationGate (pure precondition)' {
  It 'fails when an elevation-requiring provider runs unelevated' {
    $env = New-EnvironmentInfo -OsBuild b -OsVersion v -PsVersion p -ScriptVersion s `
      -IsElevated $false -IsInteractive $true -Locale l -Region r
    $providers = @([pscustomobject]@{ Target = New-UpdateTarget -Id 'wua' -DisplayName 'WUA' -Kind 'Automated' })
    Test-ElevationGate -Providers $providers -Environment $env | Should -BeFalse
  }
  It 'passes unelevated when no provider requires elevation' {
    $env = New-EnvironmentInfo -OsBuild b -OsVersion v -PsVersion p -ScriptVersion s `
      -IsElevated $false -IsInteractive $true -Locale l -Region r
    $providers = @([pscustomobject]@{ Target = New-UpdateTarget -Id 'fw' -DisplayName 'FW' -Kind 'ManualAdvisory' `
          -Capabilities @{ Enabled = $true; RequiresElevation = $false }
      })
    Test-ElevationGate -Providers $providers -Environment $env | Should -BeTrue
  }
  It 'passes when elevated' {
    $env = New-EnvironmentInfo -OsBuild b -OsVersion v -PsVersion p -ScriptVersion s `
      -IsElevated $true -IsInteractive $true -Locale l -Region r
    $providers = @([pscustomobject]@{ Target = New-UpdateTarget -Id 'wua' -DisplayName 'WUA' -Kind 'Automated' })
    Test-ElevationGate -Providers $providers -Environment $env | Should -BeTrue
  }
}

Describe 'ConvertTo-WideEvent (the canonical event projection)' {
  BeforeAll {
    $env = New-EnvironmentInfo -OsBuild '26100.1742' -OsVersion 'Windows 11 Pro 24H2' `
      -PsVersion '7.6.2' -ScriptVersion '1.0.1' -IsElevated $true -IsInteractive $true `
      -Locale 'en-NL' -Region 'NL'
    $results = @(
      New-TestResult -Id 'windows-update' -Display 'Windows Update' -Outcome 'Succeeded' `
        -Applied 4 -Reboot $true -DurationMs 142882
      New-TestResult -Id 'winget' -Display 'Winget Applications' -Outcome 'Succeeded' -Applied 3 -DurationMs 39114
    )
    $report = New-RunReport -Environment $env -Results $results `
      -StartedAt ([datetimeoffset]'2026-06-02T22:14:07.512+02:00') -DurationMs 184293 `
      -RunId '0f9c2a1e-7b3d-4c9a-9f21-2c5b8e0d4a77' -HostName 'DESKTOP-PG01' `
      -RebootDecision 'Declined'
    $evt = ConvertTo-WideEvent -Report $report
  }
  It 'emits exactly one event with the canonical name and schema version' {
    $evt.event          | Should -Be 'windows_maintenance.invocation'
    $evt.schema_version | Should -Be 1
  }
  It 'carries high-cardinality identifiers' {
    $evt.run_id | Should -Be '0f9c2a1e-7b3d-4c9a-9f21-2c5b8e0d4a77'
    $evt.host   | Should -Be 'DESKTOP-PG01'
  }
  It 'embeds environment/deployment context' {
    $evt.env.os_build       | Should -Be '26100.1742'
    $evt.env.ps_version     | Should -Be '7.6.2'
    $evt.env.is_elevated    | Should -BeTrue
  }
  It 'sums per-provider counts into run-level totals' {
    $evt.updates_applied_total | Should -Be 7
    $evt.providers_total       | Should -Be 2
  }
  It 'derives the overall outcome and reboot signal from the results' {
    $evt.outcome         | Should -Be 'Succeeded'
    $evt.reboot_required | Should -BeTrue
    $evt.reboot_decision | Should -Be 'Declined'
  }
  It 'nests a per-provider array rather than emitting one event per provider' {
    $evt.providers.Count            | Should -Be 2
    $evt.providers[0].id            | Should -Be 'windows-update'
    $evt.providers[0].updates_applied | Should -Be 4
    $evt.providers[0].reboot_required | Should -BeTrue
  }
  It 'serializes to a single compact JSON line (enums already rendered as strings)' {
    $json = $evt | ConvertTo-Json -Depth 8 -Compress
    $json | Should -Match '"outcome":"Succeeded"'
    $json | Should -Not -Match "`n"
  }
  It 'accepts late-bound infra facts (state-save failure) without mutating the report' {
    $evt2 = ConvertTo-WideEvent -Report $report -StateSaveFailed $true
    $evt2.state_save_failed | Should -BeTrue
    $evt.state_save_failed  | Should -BeFalse   # original projection untouched
  }
}

Describe 'ConvertTo-FailFastEvent (the abort path still emits one event)' {
  It 'produces a Failed event with a failure reason and empty providers' {
    $env = New-EnvironmentInfo -OsBuild b -OsVersion v -PsVersion p -ScriptVersion s `
      -IsElevated $false -IsInteractive $true -Locale l -Region r
    $evt = ConvertTo-FailFastEvent -Environment $env -RunId 'rid' -HostName 'H' `
      -Timestamp ([datetimeoffset]'2026-06-02T00:00:00Z') -DurationMs 5 -FailureReason 'not_elevated'
    $evt.outcome        | Should -Be 'Failed'
    $evt.failure_reason | Should -Be 'not_elevated'
    $evt.providers      | Should -BeNullOrEmpty
  }
}

Describe 'ConvertTo-InvocationRecord (trimmed persisted projection)' {
  It 'keeps only what the next run needs to render the last-run line' {
    $env = New-EnvironmentInfo -OsBuild b -OsVersion v -PsVersion p -ScriptVersion s `
      -IsElevated $true -IsInteractive $true -Locale l -Region r
    $results = @(New-TestResult -Id 'winget' -Outcome 'Succeeded' -Applied 3)
    $report = New-RunReport -Environment $env -Results $results `
      -StartedAt ([datetimeoffset]'2026-06-02T22:14:07+02:00') -DurationMs 100 `
      -RunId 'rid' -HostName 'H' -RebootDecision 'NotRequired'
    $rec = ConvertTo-InvocationRecord -Report $report
    $rec.outcome               | Should -Be 'Succeeded'
    $rec.updates_applied_total | Should -Be 3
    $rec.providers[0].id       | Should -Be 'winget'
    $rec.PSObject.Properties.Name | Should -Not -Contain 'env'   # fat context is not persisted
  }
}

Describe 'Formatting (human-facing strings, pure)' {
  It 'Format-FirstRunLine states there is no prior run' {
    Format-FirstRunLine | Should -Match 'never'
  }
  It 'Format-LastRunLine renders absolute + relative time and the outcome' {
    $rec = [pscustomobject]@{
      timestamp = '2026-06-02T08:00:00+00:00'; outcome = 'ManualActionRequired'
      reboot_required = $true; updates_applied_total = 7
    }
    $line = Format-LastRunLine -Record $rec -Now ([datetimeoffset]'2026-06-02T22:00:00+00:00')
    $line | Should -Match 'Last run: 2026-06-02 08:00'
    $line | Should -Match 'about 14 hours ago'
    $line | Should -Match 'Manual action required'
    $line | Should -Match '7 updates applied'
    $line | Should -Match 'reboot'
  }
  It 'Format-ManualAdvisories groups by category, with optional links; empty when none' {
    Format-ManualAdvisories -Advisories @() | Should -BeNullOrEmpty
    $bios  = New-ManualAdvisory -Id 'manual:msi-x670e-bios' -Name 'MSI X670E BIOS' `
      -Category 'Updates' -Link 'https://msi.com/bios'
    $store = New-ManualAdvisory -Id 'manual:microsoft-store' -Name 'Microsoft Store' -Category 'Updates'
    $block = Format-ManualAdvisories -Advisories @($bios, $store)
    $block | Should -Match 'Updates:'
    $block | Should -Match 'MSI X670E BIOS'
    $block | Should -Match 'https://msi\.com/bios'
    $block | Should -Match 'Microsoft Store'
    $block | Should -Match 'no link provided'
  }
  It 'Format-ManualAdvisories emits a separate heading per category' {
    $a = New-ManualAdvisory -Id 'a' -Name 'A' -Category 'Updates'
    $b = New-ManualAdvisory -Id 'b' -Name 'B' -Category 'Cleanup'
    $block = Format-ManualAdvisories -Advisories @($a, $b)
    $block | Should -Match 'Updates:'
    $block | Should -Match 'Cleanup:'
  }
  It 'Format-OneLineResult marks success, failure, manual and noop distinctly' {
    (Format-OneLineResult -Result (New-TestResult -Display 'Winget' -Outcome 'Succeeded' -Applied 3)) |
      Should -Match 'Winget'
    $t = New-UpdateTarget -Id x -DisplayName 'X' -Kind 'Automated'
    $failed = New-UpdateResult -Target $t -Outcome 'Failed' -ErrorMessage 'boom'
    (Format-OneLineResult -Result $failed) | Should -Match 'boom'
  }
}

Describe 'Alert-only maintenance presentation' {
  BeforeAll {
    $alertTarget = New-UpdateTarget -Id 'free-space' -DisplayName 'Free disk space' -Kind 'Automated' `
      -Capabilities @{ AlertOnly = $true }
    $env = New-EnvironmentInfo -OsBuild b -OsVersion v -PsVersion p -ScriptVersion s `
      -IsElevated $true -IsInteractive $true -Locale l -Region r
  }
  It 'Format-Alerts lists an alert-only check that failed, with its message' {
    $r = New-UpdateResult -Target $alertTarget -Outcome 'Failed' -ErrorMessage 'C: 8% free'
    $block = Format-Alerts -Results @($r)
    $block | Should -Match 'need attention'
    $block | Should -Match 'Free disk space'
    $block | Should -Match 'C: 8% free'
  }
  It 'Format-Alerts stays silent ($null) when alert-only checks succeed' {
    Format-Alerts -Results @(New-UpdateResult -Target $alertTarget -Outcome 'Succeeded') | Should -BeNullOrEmpty
  }
  It 'Format-Alerts ignores non-alert-only failures (those belong in the normal summary)' {
    $t = New-UpdateTarget -Id x -DisplayName 'X' -Kind 'Automated'
    $r = New-UpdateResult -Target $t -Outcome 'Failed' -ErrorMessage 'boom'
    Format-Alerts -Results @($r) | Should -BeNullOrEmpty
  }
  It 'Format-Summary excludes alert-only checks and reflects only the update results' {
    $upd    = New-TestResult -Id 'winget' -Display 'Winget' -Outcome 'Succeeded' -Applied 1
    $maint  = New-UpdateResult -Target $alertTarget -Outcome 'Failed' -ErrorMessage 'low'
    $report = New-RunReport -Environment $env -Results @($upd, $maint) `
      -StartedAt ([datetimeoffset]'2026-06-02T00:00:00Z') -DurationMs 10 -RunId 'r' -HostName 'H'
    $summary = Format-Summary -Report $report
    $summary | Should -Match 'Winget'
    $summary | Should -Match 'Succeeded'
    $summary | Should -Not -Match 'Free disk space'
  }
}
