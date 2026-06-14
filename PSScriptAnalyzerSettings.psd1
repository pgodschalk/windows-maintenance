@{
  # Settings for BOTH Invoke-ScriptAnalyzer (linting) and Invoke-Formatter
  # (formatting). All built-in rules run by default; the entries below tune,
  # exclude, and configure them. Report everything; CI (tools/run-tests.ps1)
  # decides which severities fail the build.
  Severity     = @('Error', 'Warning', 'Information')

  # Rules excluded as deliberate architectural choices. Each is justified --
  # these are not blanket suppressions but false positives for this codebase's
  # patterns.
  ExcludeRules = @(
    # The New-* functions here are PURE object factories (value objects and
    # closure-record ports); they construct data and change no system state, so
    # -WhatIf/ShouldProcess on them would be misleading. The code that DOES
    # change state (provider Apply scriptblocks, Restart-Computer) is gated by
    # Invoke-UpdateRun's ShouldProcess and the reboot prompt.
    'PSUseShouldProcessForStateChangingFunctions'

    # Closure-record ports and their test doubles must declare parameters that
    # match the port contract even when a given adapter ignores one, e.g.
    # GetPlan = { param($ctx) ... } invoked as  & $port.GetPlan $ctx . The
    # analyzer cannot see usage across the closure boundary, so every hit is a
    # false positive. (Verified: Registry's factory parameters ARE used --
    # inside .GetNewClosure() scriptblocks the analyzer does not follow.)
    'PSReviewUnusedParameter'

    # Internal helpers that return collections use plural nouns intentionally
    # (Get-*Problems, Get-NewEntries, Format-ManualAdvisories). They read as
    # "return the set of X"; renaming to singular would mislead.
    'PSUseSingularNouns'

    # Information-level. Scriptblock invocation (& $port.Member $arg) has no
    # named-parameter form, and Join-Path is idiomatically positional. Our own
    # functions are called by name.
    'PSAvoidUsingPositionalParameters'

    # Pester shares variables from a BeforeAll block into its child It blocks
    # at run time, a data flow static analysis cannot follow -- so every
    # current hit is a false positive (the variable IS read, just in a sibling
    # scriptblock). Genuine dead locals in src are caught in review.
    'PSUseDeclaredVarsMoreThanAssignments'

    # FunctionsToExport = '*' is deliberate, not lazy. The provider ports are
    # closure records built with .GetNewClosure(), and such closures resolve
    # unqualified calls against GLOBAL scope -- so every domain factory /
    # helper a closure calls must be exported or the tool throws at run time
    # (see WindowsMaintenance.psm1). The wildcard-perf concern this rule guards
    # (Get-Module -ListAvailable enumerating a library) does not apply to an
    # app module that is always fully loaded, and the wildcard keeps "add a
    # target = one adapter + one registry line" true (no export edits).
    # Module.Tests.ps1 guards the real surface instead.
    'PSUseToExportFieldsInManifest'
  )

  Rules        = @{
    # Common-practice line length for PowerShell (this rule's own default; also
    # the PowerShell/PowerShell repo convention). There is no 80-column
    # tradition in PowerShell.
    PSAvoidLongLines           = @{
      Enable            = $true
      MaximumLineLength = 120
    }

    # --- Formatter rules (consumed by Invoke-Formatter) ----------------------
    # 2-space indent
    PSUseConsistentIndentation = @{
      Enable              = $true
      Kind                = 'space'
      IndentationSize     = 2
      PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
    }
    # Whitespace hygiene. CheckOperator is OFF on purpose: it collapses the
    # multiple spaces this codebase uses to align '=' in hashtables/param
    # blocks, which PSAlignAssignmentStatement is responsible for instead. The
    # two rules conflict, so we let alignment win.
    PSUseConsistentWhitespace  = @{
      Enable                                  = $true
      CheckInnerBrace                         = $true
      CheckOpenBrace                          = $true
      CheckOpenParen                          = $true
      CheckOperator                           = $false
      CheckPipe                               = $true
      CheckPipeForRedundantWhitespace         = $false
      CheckSeparator                          = $true
      CheckParameter                          = $false
      IgnoreAssignmentOperatorInsideHashTable = $true
    }
    # Keep the aligned '=' columns
    PSAlignAssignmentStatement = @{
      Enable         = $true
      CheckHashtable = $true
    }
    # Allman brace style (function/if/loop braces on their own line). Hashtable
    # @{ literals are unaffected and stay on the same line.
    PSPlaceOpenBrace           = @{
      Enable             = $true
      OnSameLine         = $false
      NewLineAfter       = $true
      IgnoreOneLineBlock = $true
    }
    PSPlaceCloseBrace          = @{
      Enable             = $true
      NewLineAfter       = $false
      IgnoreOneLineBlock = $true
      NoEmptyLineBefore  = $false
    }
  }
}
