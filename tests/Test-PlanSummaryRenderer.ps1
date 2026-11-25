<#
.SYNOPSIS
Runs the plan summary renderer that ships inside terraform-plan-summary.yaml, unchanged, on synthetic plans.

.DESCRIPTION
The renderer is inline in the pipeline template because the templates repository is never checked
out at run time, so a sibling .ps1 would not exist on the agent. It reads its inputs from
environment variables only and is fenced by markers, so this script lifts it out verbatim: the thing
under test is the thing that ships. It asserts, never authors.

Cases: an empty plan says so; add / change / replace / destroy are each counted, destructive entries
lead and carry the replacement reason; no-op entries and data reads are not changes; a plan that changes
only outputs says why an approval is asked for, names but never values; objects changed outside
Terraform are information; a long plan announces its truncation; the deep links are all or nothing.
#>
[CmdletBinding()]
param([string] $KitRoot = (Split-Path -Parent $PSScriptRoot))
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$templatePath = Join-Path $KitRoot "content\templates-repo\.pipelines\helpers\terraform-plan-summary.yaml"
$beginMarker = "# >>> PLAN SUMMARY RENDERER BEGIN"
$endMarker = "# <<< PLAN SUMMARY RENDERER END"
$lines = @(Get-Content -LiteralPath $templatePath)
$begin = -1; $end = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
  if ($lines[$i].TrimEnd().EndsWith($beginMarker)) { $begin = $i } elseif ($lines[$i].TrimEnd().EndsWith($endMarker)) { $end = $i }
}
if ($begin -lt 0 -or $end -le $begin) { throw "Could not find the renderer between '$beginMarker' and '$endMarker' in $templatePath." }
$indent = $lines[$begin].Substring(0, $lines[$begin].IndexOf("#"))
$body = foreach ($line in $lines[($begin + 1)..($end - 1)]) {
  if ($line.StartsWith($indent)) { $line.Substring($indent.Length) }
  elseif ([string]::IsNullOrWhiteSpace($line)) { "" }
  else { throw "Renderer line is indented less than the marker: $line" }
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("pb-renderer-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$renderer = Join-Path $work "renderer.ps1"
Set-Content -LiteralPath $renderer -Value $body -Encoding utf8

function Invoke-Renderer {
  param([string] $Name, [hashtable] $Plan, [string] $PlanText, [switch] $WithPipelineContext, [string] $TaskId)
  $case = Join-Path $work $Name
  New-Item -ItemType Directory -Path $case -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $case "plan.json") -Value ($Plan | ConvertTo-Json -Depth 20) -Encoding utf8
  Set-Content -LiteralPath (Join-Path $case "plan.txt") -Value $PlanText -Encoding utf8
  $names = @("PLAN_JSON_PATH", "PLAN_TEXT_PATH", "PLAN_SUMMARY_PATH", "PLAN_LABEL", "PLAN_ARTIFACT_NAME", "PLAN_COLLECTION_URI", "PLAN_PROJECT", "PLAN_BUILD_ID", "PLAN_JOB_ID", "PLAN_TASK_ID")
  $env:PLAN_JSON_PATH = Join-Path $case "plan.json"; $env:PLAN_TEXT_PATH = Join-Path $case "plan.txt"
  $env:PLAN_SUMMARY_PATH = Join-Path $case "summary.md"; $env:PLAN_LABEL = "self test"; $env:PLAN_ARTIFACT_NAME = "plan-test"
  if ($WithPipelineContext) {
    $env:PLAN_COLLECTION_URI = "https://example.invalid/org/"; $env:PLAN_PROJECT = "a project"; $env:PLAN_BUILD_ID = "4242"; $env:PLAN_JOB_ID = "job-guid"
    if ($TaskId) { $env:PLAN_TASK_ID = $TaskId }
  }
  try { & $renderer | Out-Null } finally { foreach ($n in $names) { Remove-Item -LiteralPath "env:$n" -ErrorAction SilentlyContinue } }
  Get-Content -LiteralPath (Join-Path $case "summary.md") -Raw
}

$issues = [System.Collections.Generic.List[string]]::new()
# Ordinal Contains, not -like: the expected strings are markdown, and [ ] * are wildcards.
function Assert-Contains([string] $Text, [string] $Expected, [string] $Case) { if (-not $Text.Contains($Expected)) { $issues.Add("$Case - expected to find: $Expected") } }
function Assert-Missing([string] $Text, [string] $Unexpected, [string] $Case) { if ($Text.Contains($Unexpected)) { $issues.Add("$Case - should not contain: $Unexpected") } }

try {
  $empty = Invoke-Renderer -Name "empty" -PlanText "No changes." -Plan @{ format_version = "1.2"; resource_changes = @() }
  Assert-Contains $empty "**No changes.**" "empty"
  Assert-Missing $empty "Destructive actions" "empty"
  Assert-Missing $empty "### Output changes" "empty"

  $mixedPlan = @{
    format_version = "1.2"
    resource_changes = @(
      @{ address = "azurerm_resource_group.new"; type = "azurerm_resource_group"; change = @{ actions = @("create") } }
      @{ address = "azurerm_virtual_network.hub"; type = "azurerm_virtual_network"; change = @{ actions = @("update") } }
      @{ address = "azurerm_firewall.primary"; type = "azurerm_firewall"; action_reason = "replace_because_cannot_update"; change = @{ actions = @("delete", "create") } }
      @{ address = "azurerm_public_ip.retired"; type = "azurerm_public_ip"; change = @{ actions = @("delete") } }
      @{ address = "azurerm_key_vault.untouched"; type = "azurerm_key_vault"; change = @{ actions = @("no-op") } }
      @{ address = "data.azurerm_client_config.current"; type = "azurerm_client_config"; change = @{ actions = @("read") } }
    )
  }
  $mixed = Invoke-Renderer -Name "mixed" -PlanText "Terraform will perform the following actions:" -Plan $mixedPlan
  Assert-Contains $mixed "**1 to add | 1 to change | 1 to replace | 1 to destroy**" "counts"
  Assert-Contains $mixed "Destructive actions - read these first" "destructive"
  Assert-Contains $mixed "replace_because_cannot_update" "replacement reason"
  Assert-Missing $mixed "azurerm_key_vault.untouched" "no-op excluded"
  Assert-Missing $mixed "data.azurerm_client_config.current" "data read excluded"
  Assert-Missing $mixed "**No changes.**" "mixed"
  if ($mixed.IndexOf("Destructive actions") -gt $mixed.IndexOf("### All changes")) { $issues.Add("ordering - destructive actions must come before the full table.") }

  $long = Invoke-Renderer -Name "long" -PlanText ((1..900 | ForEach-Object { "  # line $_" }) -join "`n") -Plan $mixedPlan
  Assert-Contains $long "truncated at 800 of 900 lines" "truncation"

  Assert-Missing $mixed "_build/results" "no pipeline context, no links"
  $linked = Invoke-Renderer -Name "linked" -PlanText "x" -Plan $mixedPlan -WithPipelineContext -TaskId "task-guid"
  Assert-Contains $linked "[Open the full log](https://example.invalid/org/a%20project/_build/results?buildId=4242&view=logs&j=job-guid&t=task-guid)" "log link"
  Assert-Contains $linked "[Download the plan](https://example.invalid/org/a%20project/_build/results?buildId=4242&view=artifacts&type=publishedArtifacts)" "plan link"
  $unexpanded = Invoke-Renderer -Name "unexpanded" -PlanText "x" -Plan $mixedPlan -WithPipelineContext -TaskId '$(planTaskId)'
  Assert-Contains $unexpanded "&view=logs&j=job-guid)" "an unset task id falls back to the job"
  Assert-Missing $unexpanded "planTaskId" "an unset task id is never printed"

  # A plan that changes only outputs exits 2, so CD asks for an approval: the summary must say why,
  # and a value - here a secret - must never appear.
  $secret = "s3cr3t-value-never-rendered"
  $outputsOnly = Invoke-Renderer -Name "outputs" -PlanText "Changes to Outputs:" -Plan @{
    format_version = "1.2"
    resource_changes = @(@{ address = "azurerm_key_vault.untouched"; type = "azurerm_key_vault"; change = @{ actions = @("no-op") } })
    output_changes = [ordered]@{
      new_ids = @{ actions = @("create"); after = @{} }
      connection_secret = @{ actions = @("update"); before = "old"; after = $secret; before_sensitive = $true; after_sensitive = $true }
      retired = @{ actions = @("delete"); before = "x" }
      same = @{ actions = @("no-op"); before = "y"; after = "y" }
    }
  }
  Assert-Contains $outputsOnly "**No changes to Azure resources.** 3 outputs change - applying writes the new values to the Terraform state only." "output-only"
  Assert-Missing $outputsOnly "**No changes.**" "output-only"
  Assert-Contains $outputsOnly "| + add | ``new_ids`` |" "output add"
  Assert-Contains $outputsOnly "| ~ change | ``connection_secret`` |" "output change"
  Assert-Contains $outputsOnly "| - remove | ``retired`` |" "output remove"
  Assert-Missing $outputsOnly "``same``" "no-op output excluded"
  Assert-Missing $outputsOnly $secret "output values are never rendered"

  $drift = Invoke-Renderer -Name "drift" -PlanText "Note: Objects have changed outside of Terraform" -Plan @{
    format_version = "1.2"
    resource_drift = @(@{ address = "azurerm_firewall_policy.this"; type = "azurerm_firewall_policy"; change = @{ actions = @("update"); after = @{ secret = $secret } } })
    resource_changes = @()
  }
  Assert-Contains $drift "**No changes.**" "drift only"
  Assert-Contains $drift "### Changed outside Terraform" "drift"
  Assert-Contains $drift "This is information, not an action" "drift"
  Assert-Missing $drift $secret "drift values are never rendered"
}
finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }

if ($issues.Count -gt 0) {
  Write-Host "$($issues.Count) plan summary renderer problem(s):`n - $($issues -join "`n - ")" -ForegroundColor Red
  exit 1
}
Write-Host "Plan summary renderer: all cases pass."
