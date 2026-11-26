<#
.SYNOPSIS
Checks the YAML the bootstrap commits: it parses, and the pipelines and templates agree on their parameters.

.DESCRIPTION
Azure DevOps refuses a run at compile time for a missing required template parameter, an unexpected
parameter, or a helper template that does not exist - and it does so only when the pipeline first
runs. This reads the same files and checks the same contract beforehand:

  - every .yaml in content\ parses (the .tftpl files are rendered with sample values first);
  - what ci.yaml / cd.yaml pass to the template is declared by it, and every parameter the template
    requires (declares without a default) is passed;
  - what the templates pass to their helpers is declared by the helper, every required helper
    parameter is passed, and every helper exists;
  - the required-template check in terraform\locals.tf names files the templates repository has;
  - the CD apply stage is skipped when the plan has no changes, and the plan step publishes the flag it reads;
  - nothing ALZ-specific is left in what the kit ships.

Needs the powershell-yaml module; without it the test says so and fails rather than passing blind.
#>
[CmdletBinding()]
param([string] $KitRoot = (Split-Path -Parent $PSScriptRoot))
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Get-Module -ListAvailable powershell-yaml)) { Write-Host "Install-Module powershell-yaml is needed to parse the YAML." -ForegroundColor Red; exit 1 }
Import-Module powershell-yaml

$issues = [System.Collections.Generic.List[string]]::new()
function Add-Issue([string] $Text) { $issues.Add($Text) }

$templates = Join-Path $KitRoot "content\templates-repo"
$main = Join-Path $KitRoot "content\main-repo"

$sample = @{
  project_name = "demo"; environment_name = "prd"; pipeline_display_name = "Demo"; project_reference = "Demo Project"
  repository_name = "demo-infra"; templates_repository = "demo-infra-templates"; terraform_cli_version = "latest"
  agent_pool_name = "demo-prd"; variable_group_name = "demo-prd"; plan_environment = "demo-prd-plan"; apply_environment = "demo-prd-apply"
  plan_connection = "sc-demo-prd-plan"; apply_connection = "sc-demo-prd-apply"; tenant_id = "00000000-0000-0000-0000-000000000000"
  subscription_id = "11111111-1111-1111-1111-111111111111"; azure_location = "canadacentral"; approvers_group = "demo-prd-approvers"
  organization_url = "https://dev.azure.com/contoso"; plan_state_lock = "false"
}

function Read-Rendered([string] $Path) {
  $text = Get-Content -LiteralPath $Path -Raw
  if ($Path.EndsWith(".tftpl")) {
    $text = [regex]::Replace($text, '(?<!\$)\$\{(\w+)\}', { param($m) if ($sample.ContainsKey($m.Groups[1].Value)) { $sample[$m.Groups[1].Value] } else { "UNRESOLVED:$($m.Groups[1].Value)" } })
    $text = $text.Replace('$${', '${')
  }
  $text
}

function Read-Yaml([string] $Path) {
  try { ConvertFrom-Yaml (Read-Rendered $Path) -Ordered }
  catch { Add-Issue "$Path does not parse as YAML: $($_.Exception.Message)"; $null }
}

# ---- 1. every YAML parses
$yamlFiles = @(Get-ChildItem -LiteralPath $templates, $main -Recurse -File -Force | Where-Object { $_.Name -match "\.ya?ml(\.tftpl)?$" })
if ($yamlFiles.Count -lt 8) { Add-Issue "Expected the pipeline files and templates under content\, found $($yamlFiles.Count) YAML files." }
$parsed = @{}
foreach ($file in $yamlFiles) {
  $doc = Read-Yaml $file.FullName
  if ($null -ne $doc) { $parsed[$file.FullName] = $doc }
  if ((Read-Rendered $file.FullName) -match "UNRESOLVED:(\w+)") { Add-Issue "$($file.Name) uses a variable the bootstrap does not pass: $($Matches[1])" }
}

function Get-Declared($Doc) {
  $declared = @{}
  if ($Doc -and $Doc.Contains("parameters")) {
    foreach ($p in @($Doc["parameters"])) { $declared[$p["name"]] = $p.Contains("default") }
  }
  $declared
}

function Find-TemplateCalls($Node, [System.Collections.Generic.List[object]] $Found) {
  if ($Node -is [System.Collections.IDictionary]) {
    if ($Node.Contains("template") -and $Node["template"] -is [string]) { $Found.Add($Node) }
    foreach ($key in $Node.Keys) { Find-TemplateCalls $Node[$key] $Found }
  }
  elseif ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) { foreach ($item in $Node) { Find-TemplateCalls $item $Found } }
}

function Test-Call([string] $Caller, [string] $Callee, $Passed, $Doc) {
  $declared = Get-Declared $Doc
  $passedNames = @(); if ($null -ne $Passed) { $passedNames = @($Passed.Keys | Where-Object { $_ -notmatch '^\$\{\{' }) }
  foreach ($name in $passedNames) { if (-not $declared.ContainsKey($name)) { Add-Issue "$Caller passes '$name' which $Callee does not declare." } }
  foreach ($name in $declared.Keys) {
    if (-not $declared[$name] -and $name -notin $passedNames) { Add-Issue "$Caller does not pass '$name', which $Callee requires (no default)." }
  }
}

# ---- 2. pipelines -> templates
foreach ($pipeline in "ci", "cd") {
  $file = Join-Path $main ".pipelines\$pipeline.yaml.tftpl"
  $doc = Read-Yaml $file
  $templateFile = Join-Path $templates ".pipelines\$pipeline-template.yaml"
  if (-not (Test-Path $templateFile)) { Add-Issue "$pipeline-template.yaml is missing from the templates repository."; continue }
  $extends = $doc["extends"]
  if ($extends["template"] -ne ".pipelines/$pipeline-template.yaml@templates") { Add-Issue "$pipeline.yaml extends '$($extends["template"])'." }
  Test-Call "$pipeline.yaml" "$pipeline-template.yaml" $extends["parameters"] (Read-Yaml $templateFile)
}

# ---- 3. templates -> helpers
foreach ($templateName in "ci-template", "cd-template") {
  $file = Join-Path $templates ".pipelines\$templateName.yaml"
  $found = [System.Collections.Generic.List[object]]::new()
  Find-TemplateCalls (Read-Yaml $file) $found
  if ($found.Count -eq 0) { Add-Issue "$templateName.yaml calls no helper template." }
  foreach ($call in $found) {
    $helper = Join-Path (Join-Path $templates ".pipelines") ($call["template"] -replace "/", "\")
    if (-not (Test-Path -LiteralPath $helper)) { Add-Issue "$templateName.yaml calls $($call["template"]), which does not exist."; continue }
    $passed = if ($call.Contains("parameters")) { $call["parameters"] } else { $null }
    Test-Call "$templateName.yaml" $call["template"] $passed (Read-Yaml $helper)
  }
}
$helpersDir = Join-Path $templates ".pipelines\helpers"
foreach ($helper in Get-ChildItem -LiteralPath $helpersDir -Filter *.yaml) {
  $found = [System.Collections.Generic.List[object]]::new()
  Find-TemplateCalls (Read-Yaml $helper.FullName) $found
}

# ---- 4. the required-template check names real files
$locals = Get-Content -LiteralPath (Join-Path $KitRoot "terraform\locals.tf") -Raw
foreach ($name in "ci_template_path", "cd_template_path") {
  if ($locals -notmatch "$name\s+= `"\`$\{local\.pipelines_folder\}/([\w.-]+)`"") { Add-Issue "locals.tf does not define $name."; continue }
  if (-not (Test-Path (Join-Path $templates ".pipelines\$($Matches[1])"))) { Add-Issue "$name names $($Matches[1]), which the templates repository does not have." }
}
if ($locals -notmatch 'pipelines_folder\s+= "\.pipelines"') { Add-Issue "locals.tf pipelines_folder is not .pipelines." }

# ---- 5. no apply without changes
$cd = Get-Content -LiteralPath (Join-Path $templates ".pipelines\cd-template.yaml") -Raw
if ($cd -notmatch "condition: and\(succeeded\(\), eq\(dependencies\.plan\.outputs\['plan\.plan\.tfplan\.planHasChanges'\], 'true'\)\)") { Add-Issue "The apply stage is not conditional on planHasChanges." }
$plan = Get-Content -LiteralPath (Join-Path $templates ".pipelines\helpers\terraform-plan.yaml") -Raw
if ($plan -notmatch "name: tfplan" -or $plan -notmatch "variable=planHasChanges;isOutput=true") { Add-Issue "The plan step must be named tfplan and publish planHasChanges as an output." }
if ($plan -notmatch '-detailed-exitcode') { Add-Issue "terraform plan must run with -detailed-exitcode." }

# ---- 6. nothing ALZ-specific ships
$shipped = Get-ChildItem -LiteralPath $KitRoot -Recurse -File -Force |
  Where-Object { $_.FullName -notmatch "\\(tests|\.terraform|output)\\" -and $_.Extension -in @(".tf", ".tftpl", ".yaml", ".md", ".ps1", ".psd1", ".hcl") -and $_.Name -notin @("README.md", ".terraform.lock.hcl", "tag-defaults.psd1") }
foreach ($file in $shipped) {
  $hit = Select-String -LiteralPath $file.FullName -Pattern "\balz\b|landing.zone|alz-mgmt" -SimpleMatch:$false | Select-Object -First 1
  if ($hit) { Add-Issue "$($file.FullName.Substring($KitRoot.Length + 1)):$($hit.LineNumber) mentions something project-specific: $($hit.Line.Trim())" }
}

if ($issues.Count -gt 0) {
  Write-Host "$($issues.Count) template problem(s):`n - $($issues -join "`n - ")" -ForegroundColor Red
  exit 1
}
Write-Host "Templates: $($yamlFiles.Count) YAML files parse; parameter contracts hold; the apply is skipped without changes; nothing project-specific ships."
