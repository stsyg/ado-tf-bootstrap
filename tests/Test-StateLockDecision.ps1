<#
.SYNOPSIS
Runs the state-lock decision inside terraform-plan.yaml, unchanged, through every row of the
templates README's "State lock" table.

.DESCRIPTION
The decision (Get-StateLockDecision) is pure - inputs in, decision out - and fenced by markers, so it
is lifted out of the pipeline YAML verbatim. The rule it carries: never release a lock while another
run of the repository is in progress, release a stale PLAN lock (a plan writes no state), and never
release an APPLY lock on its own - an interrupted apply may have left the state incomplete.
#>
[CmdletBinding()]
param([string] $KitRoot = (Split-Path -Parent $PSScriptRoot))
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$templatePath = Join-Path $KitRoot "content\templates-repo\.pipelines\helpers\terraform-plan.yaml"
$lines = @(Get-Content -LiteralPath $templatePath)
$begin = -1; $end = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
  if ($lines[$i].TrimEnd().EndsWith("# >>> STATE LOCK DECISION BEGIN")) { $begin = $i } elseif ($lines[$i].TrimEnd().EndsWith("# <<< STATE LOCK DECISION END")) { $end = $i }
}
if ($begin -lt 0 -or $end -le $begin) { throw "Could not find the state lock decision in $templatePath." }
$indent = $lines[$begin].Substring(0, $lines[$begin].IndexOf("#"))
$body = $lines[($begin + 1)..($end - 1)] | ForEach-Object { if ($_.StartsWith($indent)) { $_.Substring($indent.Length) } else { $_.TrimStart() } }
. ([scriptblock]::Create(($body -join "`n")))

$issues = [System.Collections.Generic.List[string]]::new()
function Assert-Decision([string] $Case, [string] $Expected, [hashtable] $Arguments) {
  $actual = (Get-StateLockDecision @Arguments).action
  if ($actual -ne $Expected) { $issues.Add("$Case - expected '$Expected', got '$actual'.") }
}

$planLock = [pscustomobject]@{ ID = "11111111-aaaa"; Operation = "OperationTypePlan"; Who = "agent"; Created = "now" }
$applyLock = [pscustomobject]@{ ID = "22222222-bbbb"; Operation = "OperationTypeApply"; Who = "agent"; Created = "now" }

Assert-Decision "not locked" "proceed" @{ LeaseState = "available"; LockInfo = $null; OtherRunsActive = $false; ReleaseId = "" }
Assert-Decision "locked, another run in progress" "wait" @{ LeaseState = "leased"; LockInfo = $planLock; OtherRunsActive = $true; ReleaseId = "" }
Assert-Decision "locked, runs cannot be read" "wait" @{ LeaseState = "leased"; LockInfo = $planLock; OtherRunsActive = $null; ReleaseId = "" }
Assert-Decision "another run in progress beats a release id" "wait" @{ LeaseState = "leased"; LockInfo = $applyLock; OtherRunsActive = $true; ReleaseId = "22222222-bbbb" }
Assert-Decision "stale plan lock" "unlock" @{ LeaseState = "leased"; LockInfo = $planLock; OtherRunsActive = $false; ReleaseId = "" }
Assert-Decision "stale apply lock is never released on its own" "stop" @{ LeaseState = "leased"; LockInfo = $applyLock; OtherRunsActive = $false; ReleaseId = "" }
Assert-Decision "lease with no lock record" "stop" @{ LeaseState = "leased"; LockInfo = $null; OtherRunsActive = $false; ReleaseId = "" }
Assert-Decision "apply lock with the matching release id" "unlock" @{ LeaseState = "leased"; LockInfo = $applyLock; OtherRunsActive = $false; ReleaseId = "22222222-bbbb" }
Assert-Decision "apply lock with a release id for another lock" "stop" @{ LeaseState = "leased"; LockInfo = $applyLock; OtherRunsActive = $false; ReleaseId = "99999999-zzzz" }
Assert-Decision "release id is case sensitive" "stop" @{ LeaseState = "leased"; LockInfo = $applyLock; OtherRunsActive = $false; ReleaseId = "22222222-BBBB" }
Assert-Decision "break-lease for a lease with no record" "break-lease" @{ LeaseState = "leased"; LockInfo = $null; OtherRunsActive = $false; ReleaseId = "break-lease" }
Assert-Decision "break-lease does not release a recorded lock" "stop" @{ LeaseState = "leased"; LockInfo = $applyLock; OtherRunsActive = $false; ReleaseId = "break-lease" }

if ($issues.Count -gt 0) {
  Write-Host "$($issues.Count) state lock decision problem(s):`n - $($issues -join "`n - ")" -ForegroundColor Red
  exit 1
}
Write-Host "State lock decision: all 12 cases pass."
