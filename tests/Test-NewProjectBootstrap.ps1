<#
.SYNOPSIS
Tests New-ProjectBootstrap.ps1: answers in, tfvars out - and that Terraform accepts what it wrote.

.DESCRIPTION
Runs the script in Configure mode (no Azure, no Azure DevOps, no Terraform apply) and checks:
  - an answers file produces a tfvars with every answer, lists as lists, tags as a map, no secrets;
  - the tfvars passes the real variable validations (terraform console -var-file on the real module);
  - HCL escaping: a tag value holding quotes, a backslash and ${...} comes back unchanged;
  - bad answers, unknown keys, a secret in the answers file and a missing required answer all stop the run;
  - a re-run on the same output folder reproduces the file from answers.json alone;
  - the interactive path, driven through stdin: Enter takes the default, a typed value wins.
#>
[CmdletBinding()]
param(
  [string] $KitRoot = (Split-Path -Parent $PSScriptRoot),
  [string] $Terraform = "terraform"
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script = Join-Path $KitRoot "New-ProjectBootstrap.ps1"
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("pb-script-tests-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$failures = [System.Collections.Generic.List[string]]::new()
function Assert-That([bool] $Condition, [string] $Message) {
  if ($Condition) { Write-Host "  ok   $Message" } else { Write-Host "  FAIL $Message" -ForegroundColor Red; $failures.Add($Message) }
}

function Invoke-Script([string[]] $Arguments, [string[]] $StandardInput, [hashtable] $Environment = @{}) {
  $psi = [System.Diagnostics.ProcessStartInfo]::new("pwsh")
  foreach ($a in @("-NoProfile", "-File", $script) + $Arguments) { $psi.ArgumentList.Add($a) }
  foreach ($name in $Environment.Keys) { $psi.Environment[$name] = [string]$Environment[$name] }
  $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $process = [System.Diagnostics.Process]::Start($psi)
  foreach ($line in $StandardInput) { $process.StandardInput.WriteLine($line) }
  $process.StandardInput.Close()
  $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
  if (-not $process.WaitForExit(120000)) { $process.Kill($true); throw "The script did not finish in two minutes (waiting for input?): $($Arguments -join ' ')" }
  [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $stdout.Result + $stderr.Result }
}

try {
  # The real module, initialised once, so terraform console can run its variable validations.
  $module = Join-Path $work "terraform"
  Copy-Item -LiteralPath (Join-Path $KitRoot "terraform") -Destination $module -Recurse
  Push-Location $module
  try { & $Terraform init -input=false -no-color "-backend-config=path=$(Join-Path $work 'console.tfstate')" | Out-Null; if ($LASTEXITCODE -ne 0) { throw "terraform init failed" } } finally { Pop-Location }
  function Get-TfValue([string] $VarFile, [string] $Expression) {
    $result = $Expression | & $Terraform "-chdir=$module" console "-var-file=$VarFile" -no-color 2>&1
    if ($LASTEXITCODE -ne 0) { throw "terraform console rejected $VarFile`: $($result -join "`n")" }
    ($result -join "`n").Trim()
  }

  # ---- 1. answers file -> tfvars
  Write-Host "`nAnswers file to tfvars"
  $out1 = Join-Path $work "out1"
  $run = Invoke-Script @("-AnswersFile", (Join-Path $KitRoot "answers.example.psd1"), "-OutputPath", $out1, "-NonInteractive", "-SkipAzureLookups") @()
  Assert-That ($run.ExitCode -eq 0) "exits 0 ($($run.ExitCode))"
  $tfvars = Join-Path $out1 "bootstrap.tfvars"
  Assert-That (Test-Path $tfvars) "writes bootstrap.tfvars"
  Assert-That (Test-Path (Join-Path $out1 "answers.json")) "writes answers.json"
  $text = Get-Content -LiteralPath $tfvars -Raw
  Assert-That ($text -match '(?m)^approvers\s+= \["first\.approver@contoso\.com", "second\.approver@contoso\.com"\]$') "a list is written as a list"
  Assert-That ($text -match '(?m)^target_subscription_ids\s+= \["00000000-0000-0000-0000-000000000000"\]$') "a one-item list stays a list"
  Assert-That ($text -match '(?m)^azure_devops_create_project\s+= true$' -and $text -match '(?m)^agent_container_instance_count\s+= 2$') "booleans and numbers are bare"
  Assert-That ($text -notmatch 'target_management_group_ids') "an empty optional list is left to the module's default"
  Assert-That ($text -notmatch "(?i)personal_access_token|agent_pat|mock-token") "no token appears in the file"
  Assert-That ($text -notmatch "`r") "LF line endings"
  Assert-That ((Get-TfValue $tfvars "jsonencode(var.approvers)") -eq '"[\"first.approver@contoso.com\",\"second.approver@contoso.com\"]"') "Terraform reads the approvers back"
  Assert-That ((Get-TfValue $tfvars "var.tags.costCentre") -eq '"1234"') "Terraform reads the tags back as a map"
  Assert-That ($text -match '(?m)^\s+"organizationName" = "Contoso"$' -and $text -match '(?m)^\s+"managedBy" = "Terraform"$') "the required tags are written"
  Assert-That ($text -match '(?m)^required_tag_names\s+= \["organizationName", "environment", "managedBy", "appContact"\]$') "the required tag names are written for Terraform to enforce"
  Assert-That ($text -notmatch '(?m)^\s+"repository" =') "the repository tag is not written as a value: Terraform fills it"
  Assert-That ($text -match '(?m)^# NOT written here: the ''repository'' tag, added automatically = dev\.azure\.com/contoso/Payments%20Platform/payments-infra$') "the file says what the repository tag will be"
  Assert-That ((Get-TfValue $tfvars "local.tags.repository") -eq '"dev.azure.com/contoso/Payments%20Platform/payments-infra"') "the script's repository tag value is the one Terraform builds"
  Assert-That ((Get-TfValue $tfvars "var.azure_devops_organization_url") -eq '"https://dev.azure.com/contoso"') "Terraform accepts the organization URL"
  Assert-That ($text -match '(?m)^container_registry_sku\s+= ""$' -and $text -match '(?m)^approver_entra_group_ids\s+= \[\]$') "the commented choices are written even when empty"
  Assert-That ($text -match '(?m)^use_nat_gateway\s+= true$' -and $text -match '(?m)^agent_route_table_id\s+= ""$' -and $text -match "RequestDisallowedByPolicy") "the NAT gateway and route table choices are written, with the policy reason"
  Assert-That ($text -match "(?m)^# LAB: one address" -and $text -match "(?m)^# PRODUCTION: two or more addresses, or approver_entra_group_ids") "the approvers carry the lab / production comment"
  Assert-That ($text -match '(?m)^#\s+"Basic"\s+~\$5/month' -and $text -match '(?m)^#\s+"Standard"\s+~\$20/month' -and $text -match '(?m)^#\s+"Premium"\s+~\$50/month' -and $text -match "PRIVATE ENDPOINT") "the registry SKUs are explained in the file"
  Assert-That ($text -match '(?m)^# .*LAB: 1\. PRODUCTION: 2 or more' -and $text -match '(?m)^agent_container_cpu\s+= 2$' -and $text -match '(?m)^agent_container_memory\s+= 4$') "instance count, cpu and memory are written with their cost"
  Assert-That ((Get-TfValue $tfvars "var.container_registry_sku") -eq '""') "Terraform accepts an empty (automatic) SKU"
  Assert-That ($run.Output -match "Rough monthly cost" -and $run.Output -match "Container registry Premium") "the script prints a cost estimate"

  # ---- 2. escaping
  Write-Host "`nHCL escaping"
  $hostile = @'
@{
  project_name = 'demo'
  bootstrap_subscription_id = '11111111-1111-1111-1111-111111111111'
  azure_devops_organization_url = 'contoso'
  tags = @{ note = 'say "hi" \ ${var.x} %{if}'; other = 'plain' }
  use_self_hosted_agents = $false
}
'@
  $hostileFile = Join-Path $work "hostile.psd1"; Set-Content -LiteralPath $hostileFile -Value $hostile -Encoding utf8
  $out2 = Join-Path $work "out2"
  $run = Invoke-Script @("-AnswersFile", $hostileFile, "-OutputPath", $out2, "-NonInteractive", "-SkipAzureLookups") @()
  Assert-That ($run.ExitCode -eq 0) "accepts the hostile tag value ($($run.ExitCode)): $($run.Output.Split("`n")[-3..-1] -join ' ')"
  $tf2 = Join-Path $out2 "bootstrap.tfvars"
  Assert-That ((Get-TfValue $tf2 "var.tags.note") -eq '"say \"hi\" \\ ${var.x} %{if}"') "quotes, backslash, dollar-brace and percent-brace survive the round trip"
  # With no token in the environment and no Azure CLI lookups, appContact takes the fallback written after the | in tag-defaults.psd1.
  $appContactFallback = [regex]::Match((Get-Content -LiteralPath (Join-Path $KitRoot "tag-defaults.psd1") -Raw), "azure_devops_user_email\|([^}]*)\}").Groups[1].Value
  Assert-That ($appContactFallback -ne "") "tag-defaults.psd1 gives appContact a fallback after the token"
  Assert-That ((Get-TfValue $tf2 "var.tags.appContact") -eq "`"$appContactFallback`"" -and (Get-TfValue $tf2 "var.tags.environment") -eq '"prd"' -and (Get-TfValue $tf2 "var.tags.organizationName") -eq '"contoso"') "required tags missing from the answers take the organization's defaults, filled from the other answers"
  Assert-That ((Get-TfValue $tf2 "var.azure_devops_organization_url") -eq '"https://dev.azure.com/contoso"') "an organization name becomes its URL"
  $defaults = Get-Content -LiteralPath $tf2 -Raw
  Assert-That ($defaults -match '(?m)^repository_name\s+= "demo-infra"$' -and $defaults -match '(?m)^templates_repository_name\s+= "demo-infra-templates"$') "repository names default from the project name"
  Assert-That ($defaults -match '(?m)^location_short\s+= "cac"$' -and $defaults -match '(?m)^pipeline_display_name\s+= "Demo"$') "region code and pipeline name default sensibly"
  Assert-That ($defaults -notmatch 'virtual_network_address_space') "network questions are skipped without self-hosted agents"

  # ---- 3. refusals
  Write-Host "`nRefusals"
  function Test-Refusal([string] $Name, [string] $Content, [string] $Expect) {
    $file = Join-Path $work "$Name.psd1"; Set-Content -LiteralPath $file -Value $Content -Encoding utf8
    $r = Invoke-Script @("-AnswersFile", $file, "-OutputPath", (Join-Path $work "out-$Name"), "-NonInteractive", "-SkipAzureLookups") @()
    Assert-That ($r.ExitCode -ne 0 -and $r.Output -match $Expect) "$Name is refused ($Expect)"
    Assert-That (-not (Test-Path (Join-Path $work "out-$Name\bootstrap.tfvars"))) "$Name writes nothing"
  }
  $base = "bootstrap_subscription_id = '11111111-1111-1111-1111-111111111111'; azure_devops_organization_url = 'contoso'"
  Test-Refusal "bad-project-name" "@{ project_name = 'Not_Valid'; $base }" "project_name"
  Test-Refusal "unknown-key" "@{ project_name = 'demo'; $base; projct_name = 'typo' }" "Unknown answer 'projct_name'"
  Test-Refusal "secret-in-file" "@{ project_name = 'demo'; $base; azure_devops_personal_access_token = 'x' }" "is a secret"
  Test-Refusal "missing-required" "@{ project_name = 'demo'; azure_devops_organization_url = 'contoso' }" "bootstrap_subscription_id"
  Test-Refusal "bad-organization" "@{ project_name = 'demo'; bootstrap_subscription_id = '11111111-1111-1111-1111-111111111111'; azure_devops_organization_url = 'not a url!' }" "azure_devops_organization_url"
  Test-Refusal "bad-subscription" "@{ project_name = 'demo'; bootstrap_subscription_id = 'nope'; azure_devops_organization_url = 'contoso' }" "bootstrap_subscription_id"
  Test-Refusal "bad-environment" "@{ project_name = 'demo'; $base; environment_name = 'production' }" "environment_name"
  $manyTags = (1..12 | ForEach-Object { "t$_ = 'x'" }) -join "; "
  Test-Refusal "too-many-tags" "@{ project_name = 'demo'; $base; tags = @{ $manyTags } }" "at most 15"
  Test-Refusal "bad-tag-name" "@{ project_name = 'demo'; $base; tags = @{ 'cost centre' = '1' } }" "Tag name 'cost centre'"
  Test-Refusal "empty-required-tag" "@{ project_name = 'demo'; $base; tags = @{ appContact = '' } }" "Required tag 'appContact'"
  Test-Refusal "long-tag-value" "@{ project_name = 'demo'; $base; tags = @{ note = '$('x' * 257)' } }" "longer than 256"
  Test-Refusal "bad-group-id" "@{ project_name = 'demo'; $base; approver_entra_group_ids = @('Finance DL') }" "approver_entra_group_ids"
  Test-Refusal "bad-sku" "@{ project_name = 'demo'; $base; container_registry_sku = 'Ultra' }" "container_registry_sku"

  # ---- 4. re-run from answers.json
  Write-Host "`nRe-run"
  $before = Get-Content -LiteralPath $tfvars -Raw
  Remove-Item -LiteralPath $tfvars
  $run = Invoke-Script @("-OutputPath", $out1, "-NonInteractive", "-SkipAzureLookups") @()
  Assert-That ($run.ExitCode -eq 0 -and (Get-Content -LiteralPath $tfvars -Raw) -eq $before) "an earlier answers.json rebuilds the identical tfvars with no other input"

  # ---- 5. interactive, through stdin
  Write-Host "`nInteractive"
  $out5 = Join-Path $work "out5"
  $lines = @(
    "",                                         # what to do after the questions: Configure
    "demo",                                     # project_name
    "", "", "", "",                            # environment, region, region code, instance: defaults
    "11111111-1111-1111-1111-111111111111",     # bootstrap_subscription_id
    "", "", "", "", "", "",                     # targets, management groups, roles, plan-writes-state, replication: defaults
    "contoso",                                  # organization
    "", "", "", "", "",                         # project, create, repository, templates, pipeline name: defaults
    "me@contoso.com",                           # approvers
    "",                                         # approver Entra groups: none
    "", "",                                     # branch policies, terraform version
    "Contoso Ltd",                                # tag organizationName (the default would be contoso)
    "", "", "",                                 # tags environment, managedBy, appContact: defaults
    "costCentre=99, team=infra",                # additional tags
    "n",                                        # self-hosted agents
    "Y"                                         # write these answers
  )
  $run = Invoke-Script @("-OutputPath", $out5, "-SkipAzureLookups") $lines
  Assert-That ($run.ExitCode -eq 0) "interactive run exits 0 ($($run.ExitCode)): $($run.Output.Split("`n")[-4..-1] -join ' ')"
  $tf5 = Join-Path $out5 "bootstrap.tfvars"
  if (Test-Path $tf5) {
    $t5 = Get-Content -LiteralPath $tf5 -Raw
    Assert-That ($t5 -match '(?m)^environment_name\s+= "prd"$' -and $t5 -match '(?m)^azure_location\s+= "canadacentral"$') "Enter takes the default"
    Assert-That ($t5 -match '(?m)^project_name\s+= "demo"$' -and $t5 -match '(?m)^approvers\s+= \["me@contoso.com"\]$') "a typed answer wins"
    Assert-That ($t5 -match '(?m)^use_self_hosted_agents\s+= false$' -and $t5 -notmatch "agent_container_instance_count") "'n' skips the agent questions"
    Assert-That ((Get-TfValue $tf5 "var.repository_name") -eq '"demo-infra"') "Terraform accepts the interactive result"
    Assert-That ((Get-TfValue $tf5 "var.tags.organizationName") -eq '"Contoso Ltd"' -and (Get-TfValue $tf5 "var.tags.environment") -eq '"prd"' -and (Get-TfValue $tf5 "var.tags.costCentre") -eq '"99"' -and (Get-TfValue $tf5 "var.tags.team") -eq '"infra"') "the tag questions: a typed value wins, Enter takes the default, extra tags are added"
    Assert-That ((Get-TfValue $tf5 "length(local.tags)") -eq "7") "four required + two extra + the automatic repository tag"
  }
  else { Assert-That $false "interactive run wrote bootstrap.tfvars" }
  $retry = Invoke-Script @("-OutputPath", (Join-Path $work "out6"), "-SkipAzureLookups") @("", "Not Valid", "demo", "", "", "", "", "", "11111111-1111-1111-1111-111111111111")
  Assert-That ($retry.Output -match "2-12 characters") "an invalid answer is explained and asked again"

  # ---- 6. the interactive tag question refuses too many tags, then accepts a shorter list
  Write-Host "`nInteractive tags"
  $manyExtras = (1..12 | ForEach-Object { "t$_=x" }) -join ","
  $tagLines = @("", "demo", "", "", "", "", "11111111-1111-1111-1111-111111111111", "", "", "", "", "", "", "contoso", "", "", "", "", "", "me@contoso.com", "", "", "", "", "", "", "", $manyExtras, "a=1", "n", "Y")
  $tagRun = Invoke-Script @("-OutputPath", (Join-Path $work "out7"), "-SkipAzureLookups") $tagLines
  Assert-That ($tagRun.Output -match "at most 15" -and $tagRun.ExitCode -eq 0) "16+ tags are refused with the reason, and a shorter list is then accepted ($($tagRun.ExitCode))"

  # ---- 7. another organization's tag standard
  Write-Host "`nOther tag standard"
  $standard = Join-Path $work "other-standard.psd1"
  Set-Content -LiteralPath $standard -Value "@{ RequiredTags = @( @{ Name = 'costCentre'; Default = ''; Help = 'x' }, @{ Name = 'owner'; Default = '{project_name}-team'; Help = 'y' } ) }" -Encoding utf8
  $hostileAnswers = Join-Path $work "other.psd1"
  Set-Content -LiteralPath $hostileAnswers -Value "@{ project_name = 'demo'; bootstrap_subscription_id = '11111111-1111-1111-1111-111111111111'; azure_devops_organization_url = 'contoso'; use_self_hosted_agents = `$false; tags = @{ costCentre = '77' } }" -Encoding utf8
  $other = Invoke-Script @("-AnswersFile", $hostileAnswers, "-TagDefaultsFile", $standard, "-OutputPath", (Join-Path $work "out8"), "-NonInteractive", "-SkipAzureLookups") @()
  $t8 = Join-Path $work "out8\bootstrap.tfvars"
  Assert-That ($other.ExitCode -eq 0 -and (Test-Path $t8)) "a different standard is accepted ($($other.ExitCode))"
  if (Test-Path $t8) {
    $o8 = Get-Content -LiteralPath $t8 -Raw
    Assert-That ($o8 -match '(?m)^required_tag_names\s+= \["costCentre", "owner"\]$' -and $o8 -match '"owner" = "demo-team"' -and $o8 -notmatch "managedBy") "its required tags and defaults replace the stock ones"
  }
  $noValue = Join-Path $work "novalue.psd1"
  Set-Content -LiteralPath $noValue -Value "@{ project_name = 'demo'; bootstrap_subscription_id = '11111111-1111-1111-1111-111111111111'; azure_devops_organization_url = 'contoso'; use_self_hosted_agents = `$false }" -Encoding utf8
  $missing = Invoke-Script @("-AnswersFile", $noValue, "-TagDefaultsFile", $standard, "-OutputPath", (Join-Path $work "out9"), "-NonInteractive", "-SkipAzureLookups") @()
  # ---- 8. appContact defaults to whoever runs it: the Azure CLI's signed-in user, here through a stand-in az
  Assert-That ($missing.ExitCode -ne 0 -and $missing.Output -match "Required tag 'costCentre'") "a required tag with no default and no answer stops a non-interactive run"
  Write-Host "`nappContact from the signed-in user"
  if ($IsWindows) {
    $fake = Join-Path $work "fakeaz"; New-Item -ItemType Directory -Path $fake -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $fake "az.cmd") -Encoding ascii -Value @(
      "@echo off",
      "if ""%1 %2""==""account show"" (echo {""id"":""11111111-1111-1111-1111-111111111111"",""user"":{""name"":""runner@contoso.com"",""type"":""user""}}& exit /b 0)",
      "if ""%1 %2""==""account list-locations"" (echo []& exit /b 0)",
      "if ""%1 %2""==""account list"" (echo []& exit /b 0)",
      "exit /b 1")
    $answersFile = Join-Path $work "novalue.psd1"
    $viaAz = Invoke-Script @("-AnswersFile", $answersFile, "-OutputPath", (Join-Path $work "out10"), "-NonInteractive") @() @{ PATH = "$fake;$env:PATH"; TF_VAR_azure_devops_personal_access_token = ""; AZDO_PERSONAL_ACCESS_TOKEN = "" }
    $t10 = Join-Path $work "out10\bootstrap.tfvars"
    Assert-That ($viaAz.ExitCode -eq 0 -and (Test-Path $t10) -and (Get-Content -LiteralPath $t10 -Raw) -match '"appContact" = "runner@contoso\.com"') "appContact defaults to the signed-in user ($($viaAz.ExitCode))"
  }
}
finally {
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) { Write-Host "`n$($failures.Count) check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "`nNew-ProjectBootstrap tests passed."
