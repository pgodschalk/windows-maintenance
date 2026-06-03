#requires -Version 7.4
#
# Closed sets of the ubiquitous language. These are the ONLY classes in the
# domain: enums are value types with integer backing, which gives the outcome
# lattice its ordering for free and serializes cleanly (ConvertTo-Json
# -EnumsAsStrings).
#
# This file MUST be dot-sourced before any file that uses these types as
# parameter constraints (e.g. [UpdateOutcome] in ValueObjects.ps1) - enum types
# are resolved at parse time, when the consuming file is dot-sourced.

# The severity lattice. "Overall outcome" of a run is the maximum (worst) over
# its per-target results, so the ascending integer order IS the business
# ordering: a benign no-op < a success < a benign skip < a known manual gap <
# an unexpected failure.
enum UpdateOutcome
{
  NothingToDo          = 0
  Succeeded            = 1
  Skipped              = 2
  ManualActionRequired = 3
  Failed               = 4
}

# How a target is updated. Automated targets are driven to completion by the
# tool; ManualAdvisory targets can only be observed and reported (e.g.
# UEFI/BIOS firmware).
enum ProviderKind
{
  Automated      = 0
  ManualAdvisory = 1
}

# What happened about a required reboot. Orthogonal to UpdateOutcome on
# purpose: a run can succeed AND need a reboot, so reboot is never folded into
# the outcome.
enum RebootDecision
{
  NotRequired               = 0
  NotPromptedNonInteractive = 1
  Confirmed                 = 2
  Declined                  = 3
}
