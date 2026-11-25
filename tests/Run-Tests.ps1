<#
.SYNOPSIS
Runs every test of the project-bootstrap kit. Nothing is created in Azure or Azure DevOps and no
credentials are used.

.DESCRIPTION
1. Stages terraform\, content\ and tests\ into a scratch folder under $env:TEMP, then runs
   terraform fmt -check, init -backend=false, validate, and terraform test against mock providers
   (tests\bootstrap.tftest.hcl): names, roles, scopes, checks, authorisations, rendered files and
   the refusals.
2. Test-PlanSummaryRenderer.ps1 - lifts the plan-summary renderer out of the pipeline template and
   runs it, unchanged, on synthetic plans.
3. Test-StateLockDecision.ps1 - lifts the state-lock decision out of terraform-plan.yaml and runs it
   through every row of the README's table.
4. Test-TemplateSyntax.ps1 - parses every YAML file of both repositories' content and checks the
   template parameter contract between ci.yaml/cd.yaml and the templates.
5. Test-NewProjectBootstrap.ps1 - runs New-ProjectBootstrap.ps1 non-interactively from an answers
   file and checks the tfvars it writes, then validates the tfvars against the real variables.tf.

Exits 0 when everything passes, 1 otherwise. -KeepScratch leaves the scratch folder for debugging.
#>
[CmdletBinding()]
param(
  [string] $Terraform = "terraform",
  [switch] $KeepScratch
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$kit = Split-Path -Parent $PSScriptRoot
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("project-bootstrap-tests-" + [guid]::NewGuid().ToString("N").Substring(0, 8))

if (-not $env:TF_PLUGIN_CACHE_DIR) {
  $env:TF_PLUGIN_CACHE_DIR = Join-Path ([System.IO.Path]::GetTempPath()) "project-bootstrap-terraform-plugin-cache"
  New-Item -ItemType Directory -Path $env:TF_PLUGIN_CACHE_DIR -Force | Out-Null
}

function Invoke-Step {
  param([string] $Name, [scriptblock] $Body)
  Write-Host "`n=== $Name"
  & $Body
  if ($LASTEXITCODE -ne 0) { throw "$Name failed (exit $LASTEXITCODE)." }
}

$failed = $false
try {
  # The kit ships unrun: a state file, a working directory or a tfvars in it would be copied with it.
  $leftovers = Get-ChildItem -LiteralPath (Join-Path $kit "terraform") -Force |
    Where-Object { $_.Name -in @(".terraform", "terraform.tfstate", "terraform.tfstate.backup", "tfplan") -or $_.Name -like "*.tfvars" }
  if ($leftovers) { throw "The kit's terraform folder holds run artefacts: $($leftovers.Name -join ', '). Remove them." }

  Invoke-Step "terraform fmt -check (module and tests)" {
    & $Terraform fmt -check -recursive -diff (Join-Path $kit "terraform")
    if ($LASTEXITCODE -eq 0) { & $Terraform fmt -check -recursive -diff (Join-Path $kit "tests") }
  }

  New-Item -ItemType Directory -Path $scratch -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $kit "terraform") -Destination (Join-Path $scratch "terraform") -Recurse
  Copy-Item -LiteralPath (Join-Path $kit "content") -Destination (Join-Path $scratch "content") -Recurse
  Copy-Item -LiteralPath (Join-Path $kit "tests") -Destination (Join-Path $scratch "terraform\tests") -Recurse
  Push-Location (Join-Path $scratch "terraform")
  try {
    Invoke-Step "terraform init -backend=false" { & $Terraform init -backend=false -input=false -no-color }
    Invoke-Step "terraform validate" { & $Terraform validate -no-color }
    Invoke-Step "terraform test (mock providers)" { & $Terraform test -no-color }
  }
  finally { Pop-Location }

  Invoke-Step "PowerShell syntax of every script in the kit" {
    $bad = foreach ($file in Get-ChildItem -LiteralPath $kit -Recurse -Filter *.ps1 -File) {
      $errors = $null
      [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
      foreach ($e in $errors) { "$($file.Name):$($e.Extent.StartLineNumber) $($e.Message)" }
    }
    if ($bad) { $bad | ForEach-Object { Write-Host $_ -ForegroundColor Red }; $global:LASTEXITCODE = 1 } else { $global:LASTEXITCODE = 0 }
  }

  Invoke-Step "Test-ProjectBootstrap.ps1 smoke (both halves skipped: it must report nothing and exit 0)" {
    $fake = Join-Path $scratch "fake-output"
    New-Item -ItemType Directory -Path $fake -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $fake "outputs.json") -Value "{}" -Encoding utf8
    Set-Content -LiteralPath (Join-Path $fake "answers.json") -Value "{}" -Encoding utf8
    & pwsh -NoProfile -NonInteractive -File (Join-Path $kit "Test-ProjectBootstrap.ps1") -OutputPath $fake -SkipAzure -SkipAzureDevOps
  }

  foreach ($script in "Test-PlanSummaryRenderer.ps1", "Test-StateLockDecision.ps1", "Test-TemplateSyntax.ps1", "Test-AzureDevOpsToken.ps1", "Test-BootstrapBackup.ps1", "Test-NewProjectBootstrap.ps1") {
    Invoke-Step $script {
      $arguments = @("-NoProfile", "-NonInteractive", "-File", (Join-Path $PSScriptRoot $script), "-KitRoot", $kit)
      if ($script -eq "Test-NewProjectBootstrap.ps1") { $arguments += @("-Terraform", $Terraform) }
      & pwsh @arguments
    }
  }
  Write-Host "`nAll project-bootstrap tests passed."
}
catch {
  $failed = $true
  Write-Host "`nFAILED: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
  if ($KeepScratch) { Write-Host "Scratch kept: $scratch" }
  else { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
}
exit ($failed ? 1 : 0)
