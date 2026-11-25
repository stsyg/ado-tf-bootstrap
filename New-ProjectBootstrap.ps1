<#
.SYNOPSIS
Asks a few questions, writes the Terraform variables file from the answers, and (when you say so)
builds the Azure and Azure DevOps foundation for a Terraform project: remote state, plan and apply
identities, service connections, repositories, pipelines, approvals and self-hosted agents.

.DESCRIPTION
Run it with no arguments and it asks. Every question has a default, shows what it is for, and is
checked before the next one, so a wrong value is caught here and not half-way through an apply.

  Mode Configure  asks, writes <OutputPath>\bootstrap.tfvars and answers.json, stops.
  Mode Plan       also signs in, runs terraform init and plan, and stops. Nothing is created.
  Mode Apply      also applies - after showing the plan and asking you to type 'apply'.

With no -Mode it asks which. -AnswersFile (a .psd1 or .json whose keys are the variable names in
terraform\variables.tf) answers the questions ahead of time; -NonInteractive never prompts, so a
question with no answer and no default stops the run. Run again with the same -OutputPath and the
earlier answers are the defaults: changing one value is one Enter-Enter-Enter-type-Enter.

Secrets are never written to a file. The two Azure DevOps personal access tokens are read from
TF_VAR_azure_devops_personal_access_token / TF_VAR_azure_devops_agent_pat (or AZDO_PERSONAL_ACCESS_TOKEN),
or asked for, and exist only in this process's environment while terraform runs.

The bootstrap's own Terraform state is a local file in <OutputPath>, because the state storage account
it creates may accept no public traffic. Keep that folder: it is what changes or removes what was built.

.EXAMPLE
.\New-ProjectBootstrap.ps1

.EXAMPLE
.\New-ProjectBootstrap.ps1 -AnswersFile .\answers.psd1 -Mode Plan -NonInteractive
#>
[CmdletBinding()]
param(
  # .psd1 or .json; keys are variable names from terraform\variables.tf.
  [string] $AnswersFile,
  # Where bootstrap.tfvars, answers.json, the state, the plan and outputs.json go. Default: .\output\<project>-<environment>.
  [string] $OutputPath,
  [ValidateSet("Configure", "Plan", "Apply", "Backup")]
  [string] $Mode,
  [switch] $NonInteractive,
  # Do not ask the Azure CLI for subscriptions and regions (the questions become free text).
  [switch] $SkipAzureLookups,
  # With -Mode Apply: apply the plan without asking for the typed confirmation.
  [switch] $AutoApprove,
  # After a successful apply the kit and the state are stored on the branch "bootstrap" of the project's main
  # repository (the state encrypted with a passphrase), so they can be pulled on another laptop.
  # -SkipRepositoryBackup leaves that out; -Mode Backup does only that, from an existing output folder.
  [switch] $SkipRepositoryBackup,
  # Store the state as it is, not encrypted. Only where everyone who can read the repository may see every
  # secret in the state (it holds the agent token).
  [switch] $UnencryptedState,
  # The organization's tag standard (required tags and their defaults). Default: tag-defaults.psd1 beside this script.
  [string] $TagDefaultsFile,
  [string] $Terraform = "terraform"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$kitRoot = $PSScriptRoot
. (Join-Path $kitRoot "lib\BootstrapBackup.ps1")
. (Join-Path $kitRoot "lib\AzureDevOpsToken.ps1")
$modulePath = Join-Path $kitRoot "terraform"
$minimumTerraform = [version]"1.10.0"
$interactive = -not $NonInteractive

# ---------------------------------------------------------------- output helpers

function Write-Section([string] $Title) { Write-Host ""; Write-Host "== $Title" -ForegroundColor Cyan }
function Write-Note([string] $Text) { Write-Host $Text -ForegroundColor DarkGray }
function Write-Problem([string] $Text) { Write-Host $Text -ForegroundColor Yellow }

# ---------------------------------------------------------------- answers file, variable names

function Get-VariableNames {
  $text = Get-Content -LiteralPath (Join-Path $modulePath "variables.tf") -Raw
  [regex]::Matches($text, '(?m)^variable\s+"([a-z0-9_]+)"') | ForEach-Object { $_.Groups[1].Value }
}

$variableNames = @(Get-VariableNames)
$secretVariables = @("azure_devops_personal_access_token", "azure_devops_agent_pat")

function Read-AnswersFile([string] $Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Answers file not found: $Path" }
  $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
  $loaded = switch ($extension) {
    ".psd1" { Import-PowerShellDataFile -LiteralPath $Path }
    ".json" { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable }
    default { throw "Answers file must be .psd1 or .json: $Path" }
  }
  $result = [ordered]@{}
  foreach ($key in $loaded.Keys) {
    if ($key -in $secretVariables) { throw "'$key' is a secret and does not belong in an answers file. Set TF_VAR_$key in the environment instead." }
    if ($key -notin $variableNames) { throw "Unknown answer '$key' in $Path. Valid names are the variables in terraform\variables.tf." }
    $result[$key] = $loaded[$key]
  }
  $result
}

# ---------------------------------------------------------------- Azure lookups (all optional)

$azureAvailable = $false
$script:azureAccount = $null
$script:azureSubscriptions = @()
$script:azureLocations = @{}

function Invoke-Az([string[]] $Arguments) {
  # az is az.cmd on Windows, which breaks on JMESPath's brackets and parentheses: ask for JSON, filter here.
  $output = & az @Arguments --only-show-errors -o json 2>$null
  if ($LASTEXITCODE -ne 0) { return $null }
  ($output -join "`n") | ConvertFrom-Json
}

function Initialize-AzureLookups {
  if ($SkipAzureLookups -or -not (Get-Command az -ErrorAction SilentlyContinue)) { return }
  $account = Invoke-Az @("account", "show")
  if (-not $account) { Write-Problem "Not signed in to the Azure CLI (az login): subscriptions and regions will be typed in, not chosen."; return }
  $script:azureAvailable = $true
  $script:azureAccount = $account
  $script:azureSubscriptions = @(Invoke-Az @("account", "list") | Where-Object { $_.state -eq "Enabled" })
  foreach ($location in @(Invoke-Az @("account", "list-locations"))) {
    if ($location.metadata.regionType -eq "Physical") {
      $zones = @(); if ($location.PSObject.Properties.Name -contains "availabilityZoneMappings" -and $location.availabilityZoneMappings) { $zones = @($location.availabilityZoneMappings | ForEach-Object { [string]$_.logicalZone }) }
      $script:azureLocations[$location.name] = $zones
    }
  }
}

# Short region codes for the names; any region not listed gets its first letters.
$regionCodes = @{
  canadacentral = "cac"; canadaeast = "cae"; eastus = "eus"; eastus2 = "eus2"; westus = "wus"; westus2 = "wus2"; westus3 = "wus3"
  centralus = "cus"; northcentralus = "ncus"; southcentralus = "scus"; westcentralus = "wcus"; northeurope = "neu"; westeurope = "weu"
  uksouth = "uks"; ukwest = "ukw"; francecentral = "frc"; germanywestcentral = "gwc"; swedencentral = "sec"; norwayeast = "noe"
  switzerlandnorth = "szn"; italynorth = "itn"; polandcentral = "plc"; spaincentral = "spc"; australiaeast = "aue"
  australiasoutheast = "ause"; southeastasia = "sea"; eastasia = "ea"; japaneast = "jpe"; japanwest = "jpw"; koreacentral = "krc"
  centralindia = "cin"; southindia = "sin"; brazilsouth = "brs"; southafricanorth = "san"; uaenorth = "uan"; qatarcentral = "qac"
}

function Get-RegionCode([string] $Location) {
  if ($regionCodes.ContainsKey($Location)) { return $regionCodes[$Location] }
  $letters = ($Location -replace "[^a-z0-9]", "")
  $letters.Substring(0, [Math]::Min(4, $letters.Length))
}

# ---------------------------------------------------------------- converting answers

function ConvertTo-List([object] $Value) {
  if ($null -eq $Value) { return @() }
  if ($Value -is [string]) { return @($Value -split "[,;\s]+" | Where-Object { $_ }) }
  @($Value | ForEach-Object { [string]$_ } | Where-Object { $_ })
}

function ConvertTo-Bool([object] $Value) {
  if ($Value -is [bool]) { return $Value }
  switch -Regex (([string]$Value).Trim()) {
    "^(y|yes|true|1)$" { return $true }
    "^(n|no|false|0)$" { return $false }
    default { throw "'$Value' is not yes or no." }
  }
}

function ConvertTo-Tags([object] $Value) {
  if ($null -eq $Value -or "$Value" -eq "") { return [ordered]@{} }
  if ($Value -is [System.Collections.IDictionary]) { $pairs = $Value.GetEnumerator() | ForEach-Object { [pscustomobject]@{ k = [string]$_.Key; v = [string]$_.Value } } }
  else {
    $pairs = foreach ($item in (([string]$Value) -split ",")) {
      if (-not $item.Trim()) { continue }
      $split = $item.Split("=", 2)
      if ($split.Count -ne 2 -or -not $split[0].Trim()) { throw "Tag '$item' is not key=value." }
      [pscustomobject]@{ k = $split[0].Trim(); v = $split[1].Trim() }
    }
  }
  $tags = [ordered]@{}
  foreach ($pair in $pairs) { $tags[$pair.k] = $pair.v }
  $tags
}

# ---------------------------------------------------------------- tags

$maxTags = 15   # Azure Private DNS zones, which the bootstrap creates, take no more (Learn: Use tags to organize your Azure resources)

function Get-TagDefaults {
  $path = if ($TagDefaultsFile) { $TagDefaultsFile } else { Join-Path $kitRoot "tag-defaults.psd1" }
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    if ($TagDefaultsFile) { throw "Tag defaults file not found: $TagDefaultsFile" }
    return @{ RequiredTags = @(); AdditionalTags = @{} }
  }
  $data = Import-PowerShellDataFile -LiteralPath $path
  $required = if ($data.ContainsKey("RequiredTags")) { @($data.RequiredTags) } else { @() }
  foreach ($definition in $required) { if (-not $definition.Name) { throw "A RequiredTags entry in $path has no Name." } }
  @{ RequiredTags = $required; AdditionalTags = $(if ($data.ContainsKey("AdditionalTags")) { $data.AdditionalTags } else { @{} }) }
}

function Get-TagValue($Tags, [string] $Name) {
  foreach ($key in $Tags.Keys) { if ($key -ieq $Name) { return [string]$Tags[$key] } }
  $null
}

function Get-OrganizationName([string] $OrganizationUrl) {
  $uri = [uri]$OrganizationUrl
  if ($uri.Host -like "*.visualstudio.com") { return $uri.Host.Split(".")[0] }
  $uri.AbsolutePath.Trim("/")
}

# dev.azure.com/<organization>/<project>/<repository>: where the project is bootstrapped. A space is %20.
# The same text Terraform builds (locals.tf repository_tag_value); a test keeps the two equal.
function Get-RepositoryTagValue([System.Collections.IDictionary] $Answers) {
  $base = ([string]$Answers.azure_devops_organization_url).TrimEnd("/") -replace "^https?://", ""
  "$base/$(([string]$Answers.azure_devops_project_name).Replace(' ', '%20'))/$($Answers.repository_name)"
}

# The sign-in address of whoever is running this: asked of Azure DevOps with the personal access token
# when one is already in the environment (connectionData returns the token owner), else the Azure CLI's
# signed-in user. $null when neither is available. Asked once.
$script:userEmail = $null
$script:userEmailAsked = $false
function Get-RunnerEmail([string] $OrganizationUrl) {
  if ($script:userEmailAsked) { return $script:userEmail }
  $script:userEmailAsked = $true
  $token = $env:TF_VAR_azure_devops_personal_access_token
  if (-not $token) { $token = $env:AZDO_PERSONAL_ACCESS_TOKEN }
  if ($token -and $OrganizationUrl) {
    try {
      $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$token"))
      $data = Invoke-RestMethod -Uri "$($OrganizationUrl.TrimEnd('/'))/_apis/connectionData?api-version=7.1-preview" -Headers @{ Authorization = "Basic $basic" } -TimeoutSec 20
      $account = $data.authenticatedUser.properties.Account.'$value'
      if ($account -match "^[^@\s]+@[^@\s]+$") { $script:userEmail = $account; Write-Note "appContact: the owner of the Azure DevOps token is $account."; return $account }
    }
    catch { Write-Problem "  Could not ask Azure DevOps who owns the token ($($_.Exception.Message)); trying the Azure CLI." }
  }
  if ($script:azureAccount -and $script:azureAccount.user.type -eq "user" -and $script:azureAccount.user.name -match "^[^@\s]+@[^@\s]+$") {
    $script:userEmail = $script:azureAccount.user.name
    Write-Note "appContact: the account signed in to the Azure CLI is $($script:userEmail)."
  }
  $script:userEmail
}

function Expand-TagDefault([string] $Text, [System.Collections.IDictionary] $Answers) {
  $values = @{
    environment_name          = { [string]$Answers.environment_name }
    azure_devops_organization = { Get-OrganizationName ([string]$Answers.azure_devops_organization_url) }
    project_name              = { [string]$Answers.project_name }
    azure_devops_user_email   = { Get-RunnerEmail ([string]$Answers.azure_devops_organization_url) }
  }
  [regex]::Replace($Text, '\{(\w+)(?:\|([^}]*))?\}', {
      param($m)
      $name = $m.Groups[1].Value
      if (-not $values.ContainsKey($name)) { return $m.Value }
      $value = [string](& $values[$name])
      if ([string]::IsNullOrWhiteSpace($value)) { $m.Groups[2].Value } else { $value }
    })
}

# Everything Azure and the bootstrap require of a tag set, as a list of problems (empty when fine).
function Test-TagSet($Tags, [string[]] $RequiredNames) {
  $problems = [System.Collections.Generic.List[string]]::new()
  $seen = @{}
  foreach ($name in $Tags.Keys) {
    if ($name -notmatch "^[A-Za-z][A-Za-z0-9_-]{0,127}$") { $problems.Add("Tag name '$name' must start with a letter and hold only letters, digits, '_' and '-' (at most 128 characters; Azure DNS zones accept nothing else).") }
    if ($seen.ContainsKey($name.ToLowerInvariant())) { $problems.Add("Tag '$name' is given twice (names are case-insensitive).") }
    $seen[$name.ToLowerInvariant()] = $true
    if (([string]$Tags[$name]).Length -gt 256) { $problems.Add("The value of tag '$name' is longer than 256 characters.") }
  }
  foreach ($name in $RequiredNames) {
    $value = Get-TagValue $Tags $name
    if ([string]::IsNullOrWhiteSpace($value)) { $problems.Add("Required tag '$name' has no value.") }
  }
  $total = $Tags.Count + $(if ($null -eq (Get-TagValue $Tags "repository")) { 1 } else { 0 })
  if ($total -gt $maxTags) { $problems.Add("$total tags, at most $maxTags (Azure Private DNS zones take no more; the automatic 'repository' tag counts). Remove $($total - $maxTags).") }
  $problems
}

# The tags question: each required tag of the organization's standard, then any extra tags.
function Read-Tags([System.Collections.IDictionary] $Answers, $Previous, $Supplied, $Defaults, [string[]] $RequiredNames) {
  $suppliedTags = if ($Supplied.Contains("tags")) { ConvertTo-Tags $Supplied["tags"] } else { $null }
  $previousTags = if ($Previous.Contains("tags")) { ConvertTo-Tags $Previous["tags"] } else { [ordered]@{} }
  $definitions = @{}; foreach ($d in @($Defaults.RequiredTags)) { $definitions[$d.Name] = $d }

  Write-Note "Every Azure resource gets these tags. Limit: $maxTags tags in all (Azure Private DNS zones take no more), the automatic repository tag included."
  Write-Note "The 'repository' tag is filled in for you: $(Get-RepositoryTagValue $Answers)"
  $tags = [ordered]@{}
  foreach ($name in $RequiredNames) {
    $definition = if ($definitions.ContainsKey($name)) { $definitions[$name] } else { @{ Name = $name; Default = ""; Help = "Required by this organization." } }
    $default = Get-TagValue $previousTags $name
    if ($null -eq $default) { $default = Expand-TagDefault ([string]$definition.Default) $Answers }
    $given = if ($suppliedTags) { Get-TagValue $suppliedTags $name } else { $null }
    if ($null -ne $given) { $tags[$name] = $given; continue }
    if (-not $interactive) { $tags[$name] = $default; continue }
    while ($true) {
      if ($definition.Help) { Write-Note $definition.Help }
      $entered = Read-Host "Tag $name$(if ($default) { " [$default]" })"
      if ($null -eq $entered) { throw "The input ended before the tag '$name' was answered." }
      $value = if ([string]::IsNullOrWhiteSpace($entered)) { $default } else { $entered.Trim() }
      if ($value) { $tags[$name] = $value; break }
      Write-Problem "  '$name' is required."
    }
  }

  $isRequired = { param($n) @($RequiredNames | Where-Object { $_ -ieq $n }).Count -gt 0 }
  $extraText = $null
  $attempts = 0
  while ($true) {
    if (++$attempts -gt 6) { throw "The tags are still not valid after several tries; edit the required tags in tag-defaults.psd1 or the answers file." }
    $extras = [ordered]@{}
    if ($suppliedTags) { foreach ($n in $suppliedTags.Keys) { if (-not (& $isRequired $n)) { $extras[$n] = $suppliedTags[$n] } } }
    elseif ($null -ne $extraText) { $extras = ConvertTo-Tags $extraText }
    else {
      foreach ($n in $previousTags.Keys) { if (-not (& $isRequired $n)) { $extras[$n] = $previousTags[$n] } }
      if ($extras.Count -eq 0) { foreach ($n in $Defaults.AdditionalTags.Keys) { $extras[$n] = [string]$Defaults.AdditionalTags[$n] } }
      if ($interactive) {
        $defaultText = ($extras.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ","
        Write-Note "Further tags, key=value separated by commas (a value cannot hold a comma). Blank for none; - to clear the suggestion."
        $entered = Read-Host "Additional tags$(if ($defaultText) { " [$defaultText]" })"
        if ($null -eq $entered) { throw "The input ended before the additional tags were answered." }
        $extraText = if ([string]::IsNullOrWhiteSpace($entered)) { $defaultText } elseif ($entered.Trim() -eq "-") { "" } else { $entered.Trim() }
        try { $extras = ConvertTo-Tags $extraText } catch { Write-Problem "  $($_.Exception.Message)"; $extraText = $null; continue }
      }
    }
    $all = [ordered]@{}
    foreach ($n in $tags.Keys) { $all[$n] = $tags[$n] }
    foreach ($n in $extras.Keys) { if ($null -eq (Get-TagValue $all $n)) { $all[$n] = $extras[$n] } }
    $problems = @(Test-TagSet $all $RequiredNames)
    if ($problems.Count -eq 0) { return $all }
    foreach ($p in $problems) { Write-Problem "  $p" }
    if (-not $interactive -or $suppliedTags) { throw "The tags are not valid: $($problems -join ' ')" }
    $extraText = $null
    $previousTags = [ordered]@{}
  }
}

function ConvertTo-OrganizationUrl([string] $Value) {
  $text = $Value.Trim().TrimEnd("/")
  if ($text -match "^https://") { return $text }
  if ($text -match "^[A-Za-z0-9][A-Za-z0-9-]*$") { return "https://dev.azure.com/$text" }
  throw "'$Value' is neither an organization name nor an https:// organization URL."
}

function Resolve-Subscription([string] $Value) {
  $text = $Value.Trim()
  if ($text -match "^\d+$" -and $script:azureSubscriptions.Count -ge [int]$text -and [int]$text -ge 1) { return $script:azureSubscriptions[[int]$text - 1].id }
  if ($text -match "^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$") { return $text.ToLowerInvariant() }
  $byName = @($script:azureSubscriptions | Where-Object { $_.name -eq $text })
  if ($byName.Count -eq 1) { return $byName[0].id }
  throw "'$Value' is not a subscription ID, a listed number or a subscription name."
}

# ---------------------------------------------------------------- the questions

# Each question: Key (a variable name), Prompt, Help, Default (scriptblock over the answers so far),
# Convert (text -> value), Check (value -> error text or $null), When (scriptblock; false skips it).
function New-Question([hashtable] $Definition) {
  $question = @{ Help = ""; Default = { $null }; Convert = { param($v) $v }; Check = { param($v) $null }; When = { $true }; Optional = $false; Section = ""; List = $false; Always = $false; Custom = $false; Comment = @() }
  foreach ($key in $Definition.Keys) { $question[$key] = $Definition[$key] }
  $question
}

function Get-Questions {
  @(
    New-Question @{ Section = "The project"; Key = "project_name"; Prompt = "Project name"
      Help = "Short name used in every Azure name: 2-12 characters, lowercase letters, digits and hyphens, starting with a letter."
      Check = { param($v) if ($v -notmatch "^[a-z][a-z0-9-]{1,11}$" -or $v -match "--|-$") { "2-12 characters: lowercase letters, digits, single hyphens; start with a letter; no trailing hyphen." } } }
    New-Question @{ Key = "environment_name"; Prompt = "Environment code"; Help = "1-4 lowercase letters or digits, for example prd, tst, lab."
      Default = { "prd" }; Check = { param($v) if ($v -notmatch "^[a-z0-9]{1,4}$") { "1-4 lowercase letters or digits." } } }
    New-Question @{ Key = "azure_location"; Prompt = "Azure region"; Help = "Where everything is created, as Azure spells it: canadacentral, eastus2, westeurope ..."
      Default = { "canadacentral" }
      Check = { param($v) if ($v -notmatch "^[a-z0-9]+$") { "Lowercase letters and digits, for example canadacentral." } elseif ($script:azureLocations.Count -gt 0 -and -not $script:azureLocations.ContainsKey($v)) { "Not a region the Azure CLI lists for this account." } } }
    New-Question @{ Key = "location_short"; Prompt = "Short region code"; Help = "2-5 characters, used in names (canadacentral -> cac)."
      Default = { param($a) Get-RegionCode $a.azure_location }; Check = { param($v) if ($v -notmatch "^[a-z0-9]{2,5}$") { "2-5 lowercase letters or digits." } } }
    New-Question @{ Key = "instance_number"; Prompt = "Instance number"; Help = "Three digits at the end of names, so a second copy of the project can sit beside the first."
      Default = { "001" }; Check = { param($v) if ($v -notmatch "^\d{3}$") { "Three digits." } } }

    New-Question @{ Section = "Azure"; Key = "bootstrap_subscription_id"; Prompt = "Subscription for the bootstrap resources"
      Help = "Holds the state, identities and agents, and the service connections are created for it."
      Default = { if ($script:azureAccount) { $script:azureAccount.id } else { $null } }
      Convert = { param($v) Resolve-Subscription $v } }
    New-Question @{ Key = "target_subscription_ids"; Prompt = "Subscriptions the project's Terraform manages"
      Help = "Comma-separated IDs or list numbers. The plan and apply identities get their roles on each. Blank = the bootstrap subscription only."
      Optional = $true; List = $true; Convert = { param($v) @(ConvertTo-List $v | ForEach-Object { Resolve-Subscription $_ }) } }
    New-Question @{ Key = "target_management_group_ids"; Prompt = "Management group IDs the project's Terraform manages"
      Help = "Comma-separated management group IDs (not display names); blank for none."; Optional = $true; List = $true; Convert = { param($v) @(ConvertTo-List $v) } }
    New-Question @{ Key = "plan_role_definition_name"; Prompt = "Role of the plan identity"; Help = "Read-only: a plan only reads."; Default = { "Reader" } }
    New-Question @{ Key = "apply_role_definition_name"; Prompt = "Role of the apply identity"
      Help = "Contributor cannot create role assignments. If the project's Terraform assigns roles use Owner (or Contributor plus Role Based Access Control Administrator, set by hand)."
      Default = { "Contributor" } }
    New-Question @{ Key = "plan_can_write_state"; Prompt = "Let the plan identity write the state?"
      Help = "No (advised): plans read the state and run with -lock=false, so a pull request's code cannot overwrite it. Yes: plans take the state lock like applies, and a stale plan lock is released automatically."
      Default = { $false }; Convert = { param($v) ConvertTo-Bool $v } }
    New-Question @{ Key = "storage_account_replication_type"; Prompt = "State storage replication"
      Help = "ZRS needs a region with availability zones; LRS does not."
      Default = { param($a) if ($script:azureLocations.Count -gt 0 -and @($script:azureLocations[$a.azure_location]).Count -eq 0) { "LRS" } else { "ZRS" } }
      Check = { param($v) if ($v -notin @("LRS", "ZRS", "GRS", "RAGRS", "GZRS", "RAGZRS")) { "LRS, ZRS, GRS, RAGRS, GZRS or RAGZRS." } } }

    New-Question @{ Section = "Azure DevOps"; Key = "azure_devops_organization_url"; Prompt = "Organization (name or URL)"
      Help = "contoso, or https://dev.azure.com/contoso."; Convert = { param($v) ConvertTo-OrganizationUrl $v } }
    New-Question @{ Key = "azure_devops_project_name"; Prompt = "Azure DevOps project"; Default = { param($a) $a.project_name } }
    New-Question @{ Key = "azure_devops_create_project"; Prompt = "Create that project?"; Help = "No = it already exists and is used as it is."
      Default = { $true }; Convert = { param($v) ConvertTo-Bool $v } }
    New-Question @{ Key = "repository_name"; Prompt = "Main repository name"; Help = "Holds the Terraform code, its .tfvars and the pipeline files."
      Default = { param($a) "$($a.project_name)-infra" } }
    New-Question @{ Key = "templates_repository_name"; Prompt = "Pipeline templates repository name"
      Help = "Holds the shared pipeline templates the service connections require."; Default = { param($a) "$($a.repository_name)-templates" } }
    New-Question @{ Key = "pipeline_display_name"; Prompt = "Name in the pipeline titles"
      Help = "Gives '01 <name> Continuous Integration' and '02 <name> Continuous Delivery'."
      Default = { param($a) (Get-Culture).TextInfo.ToTitleCase(($a.project_name -replace "-", " ")) }
      Check = { param($v) if ($v.Length -gt 60 -or $v -match '["<>|:*?\\/]') { "1-60 characters, none of  `" < > | : * ? \ /" } } }
    New-Question @{ Key = "approvers"; Prompt = "Approvers of an apply (sign-in addresses)"
      Help = "Comma-separated user principal names. They get the approval check on the apply connection. Lab: one address is enough. Production: two or more (or an Entra group, next question) so that someone other than the author reviews every pull request. Blank = applies are not held for approval."
      Optional = $true; List = $true; Always = $true; Default = { if ($script:azureAccount -and $script:azureAccount.user.name -match "@") { $script:azureAccount.user.name } else { $null } }
      Comment = @(
        "Who approves an apply (the approval check on the apply service connection). Sign-in addresses.",
        "LAB: one address - that person approves their own change, and the reviewer rule on pull requests is off.",
        "PRODUCTION: two or more addresses, or approver_entra_group_ids below. With one approver nobody else",
        "reviews a pull request - including one that edits .pipelines/ci.yaml - so that person is the whole control.",
        "Example for production:  approvers = [""first.approver@contoso.com"", ""second.approver@contoso.com""]")
      Convert = { param($v) @(ConvertTo-List $v) }
      Check = { param($v) $bad = @($v | Where-Object { $_ -notmatch "^[^@\s]+@[^@\s]+$" }); if ($bad) { "Not a sign-in address: $($bad -join ', ')" } } }
    New-Question @{ Key = "approver_entra_group_ids"; Prompt = "Entra security group(s) of approvers (object IDs)"
      Help = "Optional, comma-separated GUIDs. Everyone in the group approves; membership is then managed in Entra, with no re-run. Must be a SECURITY group (a mail-only distribution list is not accepted by Azure DevOps). Find the ID: az ad group show --group <name> --query id -o tsv"
      Optional = $true; List = $true; Always = $true; Convert = { param($v) @(ConvertTo-List $v) }
      Comment = @(
        "Optional: object IDs of Microsoft Entra SECURITY groups whose members approve an apply, in addition to the",
        "addresses above. Membership is kept in Entra - no re-run when someone joins or leaves. A mail-only",
        "distribution list cannot be used. Lab: leave empty.")
      Check = { param($v) $bad = @($v | Where-Object { $_ -notmatch "^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$" }); if ($bad) { "Not an object ID (GUID): $($bad -join ', ')" } } }
    New-Question @{ Key = "create_branch_policies"; Prompt = "Protect main with branch policies?"
      Help = "Pull request, squash merge, a passing CI run, and (with more than one approver) a reviewer."
      Default = { $true }; Convert = { param($v) ConvertTo-Bool $v } }
    New-Question @{ Key = "terraform_cli_version"; Prompt = "Terraform CLI version the pipelines install"; Help = "latest, or a version such as 1.14.9."
      Default = { "latest" }; Check = { param($v) if ($v -ne "latest" -and $v -notmatch "^\d+\.\d+\.\d+$") { "latest or x.y.z." } } }

    New-Question @{ Section = "Tags"; Key = "tags"; Custom = $true; Prompt = "Tags" }

    New-Question @{ Section = "Agents and network"; Key = "use_self_hosted_agents"; Prompt = "Run pipelines on self-hosted agents?"
      Help = "Yes: a container registry builds an agent image and container instances run it. No: Microsoft-hosted agents."
      Default = { $true }; Convert = { param($v) ConvertTo-Bool $v } }
    New-Question @{ Key = "use_private_networking"; Prompt = "Put the agents in a private network?"
      Help = "Yes: virtual network, NAT gateway (one outbound address), private endpoints and no public access for the state storage - and for the registry too when it is Premium."
      Comment = @(
        "true: agents run in a virtual network behind a NAT gateway; the state storage account has a private endpoint and no",
        "public access. Costs more (NAT gateway and private endpoints are billed per hour and per GB; see the pricing calculator).",
        "false: agents have no network of their own; the state account keeps a public endpoint (Entra sign-in only).")
      When = { param($a) $a.use_self_hosted_agents }; Default = { $true }; Convert = { param($v) ConvertTo-Bool $v } }
    New-Question @{ Key = "use_nat_gateway"; Prompt = "Give the agents a NAT gateway with a public IP?"
      Help = "Yes: one fixed outbound address. No: needed where policy denies public IP addresses (creating one fails with RequestDisallowedByPolicy) - then give a route table below, for example one that sends 0.0.0.0/0 to a hub firewall."
      Comment = @(
        "true: a NAT gateway and a Standard public IP (~`$4/month) give the agents one fixed outbound address.",
        "false: REQUIRED where policy denies public IP addresses (the apply fails with RequestDisallowedByPolicy on the public IP).",
        "Then set agent_route_table_id below, or the agents have no way to the internet and the bootstrap refuses to run.")
      When = { param($a) $a.use_self_hosted_agents -and $a.use_private_networking }; Default = { $true }; Convert = { param($v) ConvertTo-Bool $v } }
    New-Question @{ Key = "public_ip_deny_policy_assignment_id"; Prompt = "Policy assignment that denies public IPs (resource ID, blank for none)"
      Help = "Only if the NAT gateway's public IP is refused by policy (RequestDisallowedByPolicy) and you may create an exemption. The bootstrap then waives that ONE assignment on its own network resource group, until the date asked next. Find it: az policy assignment list --scope /providers/Microsoft.Management/managementGroups/<group> --query ""[?contains(name,'Public-IP')].id"" -o tsv"
      Optional = $true; Always = $true
      Comment = @(
        "Optional: the policy assignment that denies public IP addresses where this runs, as a resource ID, e.g.",
        "  /providers/Microsoft.Management/managementGroups/<group>/providers/Microsoft.Authorization/policyAssignments/Deny-Public-IP",
        "When set, the bootstrap creates a policy exemption (Waiver) for that ONE assignment on its own network resource group only,",
        "so the NAT gateway's one public IP can be created. Needs Owner (or Resource Policy Contributor) there. Empty = no exemption.",
        "Leave it empty if an exemption already exists (created by hand, or by the policy repository): one cannot be created twice.")
      When = { param($a) $a.use_self_hosted_agents -and $a.use_private_networking -and $a.use_nat_gateway }
      Convert = { param($v) "$v".Trim() }
      Check = { param($v) if ($v -ne "" -and $v -notmatch "(?i)/providers/Microsoft\.Authorization/policyAssignments/[^/]+$") { "A policy assignment resource ID ending in /providers/Microsoft.Authorization/policyAssignments/<name>." } } }
    New-Question @{ Key = "policy_exemption_expires_on"; Prompt = "Exemption expires on (RFC 3339, e.g. 2027-05-24T00:00:00Z)"
      Help = "An exemption must end. Renew or remove it before then."
      Optional = $true; Always = $true
      Comment = @("When the exemption above ends (RFC 3339). Required with public_ip_deny_policy_assignment_id; renew or remove it before then.")
      When = { param($a) $a.use_self_hosted_agents -and $a.use_private_networking -and $a.use_nat_gateway -and $a.public_ip_deny_policy_assignment_id }
      Default = { (Get-Date).ToUniversalTime().AddMonths(6).ToString("yyyy-MM-dd'T'00:00:00'Z'") }
      Convert = { param($v) "$v".Trim() }
      Check = { param($v) if ($v -notmatch "^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$") { "An RFC 3339 UTC timestamp such as 2027-05-24T00:00:00Z." } } }
    New-Question @{ Key = "agent_route_table_id"; Prompt = "Route table for the agent subnet (resource ID, blank for none)"
      Help = "An existing route table in the bootstrap subscription and region, for example with 0.0.0.0/0 to the hub firewall. The network must then be peered to that hub by whoever runs it: this does not create the peering."
      Optional = $true; Always = $true
      Comment = @(
        "Optional: resource ID of an existing route table (same subscription and region) to attach to the agent subnet - for example",
        "one that sends 0.0.0.0/0 to a hub firewall. Needed when use_nat_gateway = false. The virtual network must be peered to that hub",
        "by whoever operates the hub; the bootstrap does not create the peering. Empty = none.")
      When = { param($a) $a.use_self_hosted_agents -and $a.use_private_networking }
      Convert = { param($v) "$v".Trim() }
      Check = { param($v) if ($v -ne "" -and $v -notmatch "(?i)^/subscriptions/[0-9a-f-]{36}/resourceGroups/[^/]+/providers/Microsoft\.Network/routeTables/[^/]+$") { "A route table resource ID: /subscriptions/<id>/resourceGroups/<group>/providers/Microsoft.Network/routeTables/<name>." } } }
    New-Question @{ Key = "container_registry_sku"; Prompt = "Container registry SKU (auto, Basic, Standard, Premium)"
      Help = "auto = Premium with a private network, Basic without. Basic: ~`$5/month, 10 GiB, no private endpoint - plenty for one agent image. Standard: ~`$20/month, 100 GiB, no private endpoint. Premium: ~`$50/month, 500 GiB, private endpoint, zone redundancy, geo-replication. Only Premium can be private; Basic/Standard keep a public (sign-in required) endpoint reached through the NAT gateway."
      Always = $true; Optional = $true
      Comment = @(
        "SKU of the container registry that builds and serves the agent image (Learn: ACR SKU features and limits).",
        "  """"        automatic: Premium with use_private_networking = true, Basic without.",
        "  ""Basic""    ~`$5/month list. 10 GiB included, 2 webhooks, NO private endpoint. Enough for one agent image. Cheapest.",
        "  ""Standard"" ~`$20/month list. 100 GiB, 10 webhooks, NO private endpoint. More storage and throughput than Basic.",
        "  ""Premium""  ~`$50/month list. 500 GiB, 500 webhooks, PRIVATE ENDPOINT, zone redundancy, geo-replication, content trust.",
        "Only Premium can sit behind a private endpoint. Basic or Standard in a private network keeps a public registry",
        "endpoint (Entra sign-in still required, no admin user) that the agents reach through the NAT gateway - the",
        "state storage account stays private either way. Saves about `$45/month. Prices: Azure Retail Prices API, Canada Central, 2026-11-19.")
      When = { param($a) $a.use_self_hosted_agents }; Default = { "auto" }
      Convert = { param($v) $t = "$v".Trim(); if ($t -in @("", "auto")) { "" } else { (Get-Culture).TextInfo.ToTitleCase($t.ToLowerInvariant()) } }
      Check = { param($v) if ($v -notin @("", "Basic", "Standard", "Premium")) { "auto, Basic, Standard or Premium." } } }
    New-Question @{ Key = "virtual_network_address_space"; Prompt = "Virtual network address space"; Help = "Must not overlap a network this one will be peered to."
      When = { param($a) $a.use_self_hosted_agents -and $a.use_private_networking }; Default = { "10.0.0.0/24" }
      Check = { param($v) if ($v -notmatch "^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$") { "A CIDR range such as 10.0.0.0/24." } } }
    New-Question @{ Key = "subnet_address_prefix_container_instances"; Prompt = "Agent subnet"; Help = "Inside the address space."
      When = { param($a) $a.use_self_hosted_agents -and $a.use_private_networking }; Default = { "10.0.0.0/26" }
      Check = { param($v) if ($v -notmatch "^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$") { "A CIDR range such as 10.0.0.0/26." } } }
    New-Question @{ Key = "subnet_address_prefix_private_endpoints"; Prompt = "Private endpoint subnet"; Help = "Inside the address space, apart from the agent subnet."
      When = { param($a) $a.use_self_hosted_agents -and $a.use_private_networking }; Default = { "10.0.0.64/28" }
      Check = { param($v) if ($v -notmatch "^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$") { "A CIDR range such as 10.0.0.64/28." } } }
    New-Question @{ Key = "agent_container_instance_count"; Prompt = "Number of agent container instances"
      Help = "Each runs one job at a time and costs about `$80/month at 2 vCPU / 4 GB, running all month. 1 is enough for a lab; 2 lets a plan and an apply run side by side."
      Comment = @(
        "Agent container instances (Azure Container Instances). Each runs one pipeline job at a time and is billed for every",
        "second it runs: vCPU `$0.0446/h + memory `$0.00487/GB-h (Canada Central list, 2026-11-19).",
        "At 2 vCPU / 4 GB that is ~`$80/month per instance. LAB: 1. PRODUCTION: 2 or more (a plan and an apply, or two pull requests, in parallel).")
      When = { param($a) $a.use_self_hosted_agents }; Default = { 2 }; Convert = { param($v) [int]$v }
      Check = { param($v) if ($v -lt 1 -or $v -gt 9) { "1-9." } } }
    New-Question @{ Key = "agent_container_cpu"; Prompt = "vCPU cores per agent"; Help = "1 is enough for a small project, 2 for a large plan. About `$32/month per core, running all month."
      Comment = @("vCPU cores of each agent. ~`$32/month per core if the agent runs all month. 1 for a small project or lab, 2 for large plans.")
      When = { param($a) $a.use_self_hosted_agents }; Default = { 2 }; Convert = { param($v) [double]$v }
      Check = { param($v) if ($v -lt 1 -or $v -gt 4) { "1-4." } } }
    New-Question @{ Key = "agent_container_memory"; Prompt = "Memory (GB) per agent"; Help = "2 is enough for a small project; large provider plans want 4 or more. About `$3.50/month per GB, running all month."
      Comment = @("Memory in GB of each agent. ~`$3.50/month per GB. 2 for a small project or lab, 4+ for large provider plans.")
      When = { param($a) $a.use_self_hosted_agents }; Default = { 4 }; Convert = { param($v) [double]$v }
      Check = { param($v) if ($v -lt 1 -or $v -gt 16) { "1-16." } } }
  )
}

# ---------------------------------------------------------------- asking

function Read-Answer($Question, [System.Collections.IDictionary] $Answers, $Previous, $Supplied) {
  $key = $Question.Key
  $default = $null
  if ($Previous.Contains($key)) { $default = $Previous[$key] }
  else { $default = & $Question.Default $Answers }
  $defaultText = if ($default -is [System.Collections.IDictionary]) { ($default.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "," }
                 elseif ($default -is [System.Collections.IEnumerable] -and $default -isnot [string]) { ($default -join ",") }
                 elseif ($null -eq $default) { "" } else { [string]$default }
  if ($default -is [bool]) { $defaultText = if ($default) { "yes" } else { "no" } }

  while ($true) {
    $raw = $null
    if ($Supplied.Contains($key)) { $raw = $Supplied[$key] }
    elseif ($interactive) {
      if ($Question.Help) { Write-Note $Question.Help }
      $entered = Read-Host "$($Question.Prompt)$(if ($defaultText) { " [$defaultText]" })"
      if ($null -eq $entered) { throw "The input ended before '$key' was answered." }
      if ([string]::IsNullOrWhiteSpace($entered)) { $raw = $default; if ($null -eq $default) { $raw = "" } }
      elseif ($entered.Trim() -in @("-", "none")) { $raw = "" }
      else { $raw = $entered.Trim() }
    }
    else {
      if ($null -eq $default -and -not $Question.Optional) { throw "No answer for '$key' and it has no default: put it in the answers file." }
      $raw = if ($null -eq $default) { "" } else { $default }
    }

    try {
      $value = if ($raw -is [string] -and $raw -eq "" -and $Question.Optional) { & $Question.Convert "" }
               elseif ($raw -is [string] -and $raw -eq "" -and -not $Question.Optional) { throw "An answer is required." }
               else { & $Question.Convert $raw }
      $problem = & $Question.Check $value
      if ($Question.List) { $value = @($value) }
      if ($problem) { throw $problem }
      return @{ Value = $value }
    }
    catch {
      Write-Problem "  $($_.Exception.Message)"
      if ($Supplied.Contains($key) -or -not $interactive) { throw "Answer '$key' is not valid: $($_.Exception.Message)" }
    }
  }
}

# ---------------------------------------------------------------- writing the tfvars

function ConvertTo-HclString([string] $Text) {
  '"' + ($Text.Replace("\", "\\").Replace('"', '\"').Replace("`r", "").Replace("`n", "\n").Replace("`t", "\t").Replace('${', '$${').Replace('%{', '%%{')) + '"'
}

function ConvertTo-Hcl($Value) {
  if ($null -eq $Value) { return "null" }
  if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
  if ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) { return [string]::Format([cultureinfo]::InvariantCulture, "{0}", $Value) }
  if ($Value -is [string]) { return ConvertTo-HclString $Value }
  if ($Value -is [System.Collections.IDictionary]) {
    if ($Value.Count -eq 0) { return "{}" }
    $lines = foreach ($key in $Value.Keys) { "  $(ConvertTo-HclString ([string]$key)) = $(ConvertTo-Hcl $Value[$key])" }
    return "{`n" + ($lines -join "`n") + "`n}"
  }
  $items = @($Value | ForEach-Object { ConvertTo-Hcl $_ })
  if ($items.Count -eq 0) { return "[]" }
  "[" + ($items -join ", ") + "]"
}

function Write-TfVars([System.Collections.IDictionary] $Answers, [string] $Path) {
  $builder = [System.Text.StringBuilder]::new()
  [void]$builder.AppendLine("# Written by New-ProjectBootstrap.ps1 from the answers it was given. Safe to edit; re-run the script")
  [void]$builder.AppendLine("# with the same -OutputPath to plan or apply it.")
  [void]$builder.AppendLine("# No secrets: the two personal access tokens are TF_VAR_ environment variables.")
  $section = ""
  $width = ($Answers.Keys | Measure-Object -Property Length -Maximum).Maximum
  $questionIndex = @{}; foreach ($q in (Get-Questions)) { $questionIndex[$q.Key] = $q }
  foreach ($key in $Answers.Keys) {
    $keySection = if ($questionIndex.ContainsKey($key) -and $questionIndex[$key].Section) { $questionIndex[$key].Section } else { $section }
    if ($keySection -ne $section) { [void]$builder.AppendLine(); [void]$builder.AppendLine("# $keySection"); $section = $keySection }
    if ($questionIndex.ContainsKey($key) -and @($questionIndex[$key].Comment).Count -gt 0) {
      foreach ($line in $questionIndex[$key].Comment) { [void]$builder.AppendLine("# $line") }
    }
    if ($key -eq "tags") {
      foreach ($line in @(
          "Tags on EVERY Azure resource the bootstrap creates, and in the project's own terraform.tfvars (pass them on as tags = local.tags).",
          "Limits (Learn: Use tags to organize your Azure resources): at most $maxTags tags in all - Azure Private DNS zones take no more - and the",
          "automatic 'repository' tag counts as one; a name starts with a letter and holds letters, digits, '_' and '-'; a value is at most",
          "256 characters; tags are plain text - never a secret. The required ones are listed in required_tag_names below.",
          "NOT written here: the 'repository' tag, added automatically = $(Get-RepositoryTagValue $Answers)",
          "(dev.azure.com/<organization>/<project>/<main repository>). To use another value, add a repository = ""..."" line here.")) {
        [void]$builder.AppendLine("# $line")
      }
    }
    if ($key -eq "required_tag_names") {
      [void]$builder.AppendLine("# Tags every project must give a value before anything is created (the organization's standard, from tag-defaults.psd1).")
    }
    [void]$builder.AppendLine("$($key.PadRight($width)) = $(ConvertTo-Hcl $Answers[$key])")
  }
  [System.IO.File]::WriteAllText($Path, ($builder.ToString() -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
}

# ---------------------------------------------------------------- running terraform

function Invoke-Native([string] $What, [scriptblock] $Command) {
  & $Command
  if ($LASTEXITCODE -ne 0) { throw "$What failed (exit code $LASTEXITCODE)." }
}

function Test-TerraformInstalled {
  $command = Get-Command $Terraform -ErrorAction SilentlyContinue
  if (-not $command) { throw "Terraform was not found ('$Terraform'). Install Terraform $minimumTerraform or later: https://developer.hashicorp.com/terraform/install" }
  $info = (& $Terraform version -json 2>$null) -join "`n" | ConvertFrom-Json
  if ([version]($info.terraform_version -replace "-.*$", "") -lt $minimumTerraform) { throw "Terraform $($info.terraform_version) is older than the $minimumTerraform this kit needs." }
}

function ConvertFrom-SecureText([securestring] $Secure) {
  [System.Net.NetworkCredential]::new("", $Secure).Password
}

function Get-Token([string] $Name, [string[]] $EnvironmentNames, [string] $Prompt, [string] $Help) {
  foreach ($variable in $EnvironmentNames) { $value = [Environment]::GetEnvironmentVariable($variable); if ($value) { Write-Note "Using the token in `$env:$variable for $Name."; return $value } }
  if (-not $interactive) { throw "No ${Name}: set `$env:$($EnvironmentNames[0])." }
  Write-Note $Help
  $secure = Read-Host $Prompt -AsSecureString
  ConvertFrom-SecureText $secure
}

function Test-AzureDevOpsTokenFor([string] $OrganizationUrl, [string] $Token) {
  $owner = Test-AzureDevOpsToken -OrganizationUrl $OrganizationUrl -Token $Token
  if ($owner) { Write-Note "The Azure DevOps token is accepted; it belongs to $owner." } else { Write-Note "The Azure DevOps token is accepted." }
}

function Invoke-Bootstrap([System.Collections.IDictionary] $Answers, [string] $Directory, [string] $RunMode) {
  Test-TerraformInstalled
  if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw "The Azure CLI (az) is not installed." }
  $account = Invoke-Az @("account", "show")
  if (-not $account) { throw "Sign in first: az login" }
  Write-Note "Signed in to Azure as $($account.user.name)."
  Invoke-Native "Selecting the subscription" { & az account set --subscription $Answers.bootstrap_subscription_id --only-show-errors }

  $pat = Get-Token "Azure DevOps" @("TF_VAR_azure_devops_personal_access_token", "AZDO_PERSONAL_ACCESS_TOKEN") "Azure DevOps personal access token" "A token of the person running this, with the scopes in the README. It is used for this run only and never written to a file."
  Test-AzureDevOpsTokenFor $Answers.azure_devops_organization_url $pat
  $agentPat = $null
  if ($Answers.use_self_hosted_agents) {
    $agentPat = Get-Token "agent registration" @("TF_VAR_azure_devops_agent_pat") "Agent token (Enter to reuse the first - not advised)" "A SEPARATE token with the single scope Agent Pools (Read & manage). The agent containers register with it; it is kept, sensitive, in the bootstrap state."
    if (-not $agentPat) { $agentPat = $pat; Write-Problem "Reusing the main token for the agents: it can do far more than register an agent." }
  }

  $stateFile = Join-Path $Directory "bootstrap.tfstate"
  $planFile = Join-Path $Directory "bootstrap.tfplan"
  $tfvars = Join-Path $Directory "bootstrap.tfvars"
  # Put back whatever the caller had: the run sets these for its own length only.
  $touched = @("TF_DATA_DIR", "TF_VAR_azure_devops_personal_access_token", "TF_VAR_azure_devops_agent_pat", "TF_IN_AUTOMATION")
  $saved = @{}; foreach ($name in $touched) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
  $env:TF_DATA_DIR = Join-Path $Directory ".terraform"
  $env:TF_VAR_azure_devops_personal_access_token = $pat
  if ($agentPat) { $env:TF_VAR_azure_devops_agent_pat = $agentPat }
  $env:TF_IN_AUTOMATION = "1"
  try {
    Write-Section "terraform init"
    Invoke-Native "terraform init" { & $Terraform "-chdir=$modulePath" init -input=false -reconfigure -no-color "-backend-config=path=$stateFile" }
    Write-Section "terraform plan"
    Invoke-Native "terraform plan" { & $Terraform "-chdir=$modulePath" plan -input=false -no-color "-var-file=$tfvars" "-out=$planFile" }
    if ($RunMode -eq "Plan") { Write-Host "`nNothing was created. Run again with -Mode Apply (same -OutputPath) to create it."; return }

    if (-not $AutoApprove) {
      if (-not $interactive) { throw "-Mode Apply without -AutoApprove needs a person to confirm; add -AutoApprove for unattended use." }
      Write-Host ""
      Write-Host "Read the plan above. It creates resources in subscription $($Answers.bootstrap_subscription_id) and in the Azure DevOps organization $($Answers.azure_devops_organization_url)." -ForegroundColor Yellow
      if ((Read-Host "Type 'apply' to create them") -ne "apply") { Write-Host "Not applied."; return }
    }
    # Asked now, before a long apply, so nobody has to be at the keyboard when it ends.
    $statePassphrase = $null
    if (-not $SkipRepositoryBackup -and -not $UnencryptedState) { $statePassphrase = Get-StatePassphrase -Confirm -NonInteractive:(-not $interactive) }
    Write-Section "terraform apply"
    Invoke-Native "terraform apply" { & $Terraform "-chdir=$modulePath" apply -input=false -no-color $planFile }

    $outputs = Join-Path $Directory "outputs.json"
    $json = & $Terraform "-chdir=$modulePath" output -json
    if ($LASTEXITCODE -ne 0) { throw "terraform output failed." }
    [System.IO.File]::WriteAllText($outputs, (($json -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
    Write-Host "`nBuilt. Outputs: $outputs"
    Show-NextSteps $outputs
    # Last, so a problem here never hides that the bootstrap itself succeeded.
    if (-not $SkipRepositoryBackup) { Backup-Bootstrap $Directory $pat $statePassphrase }
  }
  finally {
    # A saved plan holds the values of the sensitive variables - both tokens - in clear text, so it
    # never outlives the run, whichever way the run ends.
    Remove-Item -LiteralPath $planFile -Force -ErrorAction SilentlyContinue
    foreach ($name in $touched) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
  }
}

function Backup-Bootstrap([string] $Directory, [string] $Token, [string] $Passphrase) {
  Write-Section "Storing the bootstrap in the repository"
  try {
    $outputsFile = Join-Path $Directory "outputs.json"
    if (-not (Test-Path -LiteralPath $outputsFile)) { throw "No outputs.json in $Directory - the bootstrap has not completed there." }
    $url = (Get-Content -LiteralPath $outputsFile -Raw | ConvertFrom-Json).azure_devops.value.repository_url
    if (-not $url) { throw "outputs.json names no repository." }
    $email = if ($script:userEmail) { $script:userEmail } else { "project-bootstrap@localhost" }
    $result = Publish-BootstrapToRepository -KitRoot $kitRoot -OutputDirectory $Directory -RepositoryUrl $url -Token $Token -StatePassphrase $Passphrase -UnencryptedState:$UnencryptedState -AuthorEmail $email
    if ($result.Pushed) {
      Write-Host "Stored on branch '$($result.Branch)' of $($result.Url)"
      Write-Host "On another laptop:  git clone --branch $($result.Branch) $($result.Url) project-bootstrap   - then RESTORE.md in it says the rest."
      if (-not $UnencryptedState) { Write-Problem "The state is encrypted: keep the passphrase in your password manager. Without it the stored state cannot be read." }
    }
  }
  catch {
    Write-Problem "The bootstrap itself succeeded, but it could not be stored in the repository: $($_.Exception.Message)"
    Write-Problem "Try again with:  .\New-ProjectBootstrap.ps1 -Mode Backup -OutputPath '$Directory'   (needs git, and a token with Code read & write)"
  }
}

function Show-NextSteps([string] $OutputsPath) {
  $out = Get-Content -LiteralPath $OutputsPath -Raw | ConvertFrom-Json
  $devops = $out.azure_devops.value
  Write-Section "Next steps"
  Write-Host "1. Check the build (read only):  .\Test-ProjectBootstrap.ps1 -OutputPath '$(Split-Path -Parent $OutputsPath)'"
  Write-Host "2. Open $($devops.organization_url)/$([uri]::EscapeDataString($devops.project_name))/_build and run '$($devops.pipelines.ci)' once on main, then '$($devops.pipelines.cd)': the plan is empty, so the apply stage is skipped."
  Write-Host "3. Clone $($devops.repository_url), add resources, open a pull request: the CI run shows the plan as a card on its Extensions tab."
  if ($out.agents.value) { Write-Host "4. The agents take a few minutes to build their image and register: Organization settings > Agent pools > $($devops.agent_pool)." }
  Write-Host "Keep $(Split-Path -Parent $OutputsPath): the bootstrap's own state is there."
}

# ================================================================ main

Write-Host "project-bootstrap: Azure and Azure DevOps foundation for a Terraform project" -ForegroundColor Cyan

$supplied = [ordered]@{}
if ($AnswersFile) { $supplied = Read-AnswersFile $AnswersFile }

# A re-run on the same output folder starts from its earlier answers.
$previous = [ordered]@{}
$explicitOutput = [bool]$OutputPath
if ($OutputPath -and (Test-Path -LiteralPath (Join-Path $OutputPath "answers.json"))) {
  $previous = Read-AnswersFile (Join-Path $OutputPath "answers.json")
  Write-Note "Earlier answers found in $OutputPath; they are the defaults."
}

if ($interactive -and -not $Mode) {
  Write-Host ""
  Write-Host "What should it do after the questions?"
  Write-Host "  1) Configure - write the variables file only (default)"
  Write-Host "  2) Plan      - also sign in, run terraform init and plan; nothing is created"
  Write-Host "  3) Apply     - also create everything, after you read the plan and confirm"
  $choice = Read-Host "Choose 1-3 [1]"
  $Mode = switch ($choice) { "2" { "Plan" } "3" { "Apply" } default { "Configure" } }
}
if (-not $Mode) { $Mode = "Configure" }

# -Mode Backup: no questions - store the kit and an existing output folder's state in the repository.
if ($Mode -eq "Backup") {
  if (-not $OutputPath -or -not (Test-Path -LiteralPath (Join-Path $OutputPath "bootstrap.tfstate"))) { throw "-Mode Backup needs -OutputPath of an output folder that holds bootstrap.tfstate and outputs.json." }
  $OutputPath = (Resolve-Path -LiteralPath $OutputPath).Path
  $backupToken = Get-Token "Azure DevOps (Code, read and write)" @("TF_VAR_azure_devops_personal_access_token", "AZDO_PERSONAL_ACCESS_TOKEN") "Azure DevOps personal access token" "Needs Code (read & write) on the project's repository. Used for this push only."
  $backupPassphrase = $null
  if (-not $UnencryptedState) { $backupPassphrase = Get-StatePassphrase -Confirm -NonInteractive:(-not $interactive) }
  Backup-Bootstrap $OutputPath $backupToken $backupPassphrase
  exit 0
}

Initialize-AzureLookups

$tagDefaults = Get-TagDefaults
$requiredTagNames = if ($supplied.Contains("required_tag_names")) { @($supplied["required_tag_names"]) } else { @($tagDefaults.RequiredTags | ForEach-Object { $_.Name }) }

$answers = [ordered]@{}
$section = ""
foreach ($question in (Get-Questions)) {
  if (-not (& $question.When $answers)) { continue }
  if ($question.Section -and $question.Section -ne $section) { $section = $question.Section; Write-Section $section }
  if ($question.Custom) {
    $answers["tags"] = Read-Tags $answers $previous $supplied $tagDefaults $requiredTagNames
    $answers["required_tag_names"] = $requiredTagNames
    continue
  }
  if ($question.Key -eq "bootstrap_subscription_id" -and $interactive -and $script:azureSubscriptions.Count -gt 0 -and -not $supplied.Contains($question.Key)) {
    Write-Host "Your subscriptions:"
    for ($i = 0; $i -lt $script:azureSubscriptions.Count; $i++) { Write-Host ("  {0,2}) {1}  ({2})" -f ($i + 1), $script:azureSubscriptions[$i].name, $script:azureSubscriptions[$i].id) }
    Write-Note "Answer with a number, an ID or a name."
  }
  $result = Read-Answer $question $answers $previous $supplied
  $answers[$question.Key] = $result.Value
}

# Zones for the agents follow from the region; an answers file can set them either way.
if ($answers.use_self_hosted_agents -and -not $supplied.Contains("agent_container_zones")) {
  $zones = @(); if ($script:azureLocations.ContainsKey($answers.azure_location)) { $zones = @($script:azureLocations[$answers.azure_location]) }
  if ($zones.Count -gt 0) { $answers["agent_container_zones"] = @($zones | Select-Object -First ([Math]::Min($zones.Count, $answers.agent_container_instance_count))) }
}

# Variables the questions do not cover are passed through from the answers file as they are.
foreach ($key in $supplied.Keys) { if (-not $answers.Contains($key)) { $answers[$key] = $supplied[$key] } }

# Optional answers left blank are not written: the module's default applies. The ones that carry a
# comment (approvers, the cost choices) are always written, even empty, so the file explains them.
$alwaysWritten = @(Get-Questions | Where-Object { $_.Always } | ForEach-Object { $_.Key }) + @("required_tag_names")
foreach ($key in @($answers.Keys)) {
  $value = $answers[$key]
  $isEmptyList = $value -is [System.Collections.IEnumerable] -and $value -isnot [string] -and $value -isnot [System.Collections.IDictionary] -and @($value).Count -eq 0
  if ($key -in $alwaysWritten) { continue }
  if ($null -eq $value -or ($value -is [string] -and $value -eq "") -or $isEmptyList) { $answers.Remove($key) }
}

# A rough monthly figure for what the answers cost, so a surprise is not left for the invoice.
function Get-CostEstimate([System.Collections.IDictionary] $Answers) {
  if (-not $Answers.Contains("use_self_hosted_agents") -or -not $Answers.use_self_hosted_agents) { return $null }
  $hours = 730
  $count = [double]$Answers.agent_container_instance_count; $cpu = [double]$Answers.agent_container_cpu; $memory = [double]$Answers.agent_container_memory
  $instances = $count * ($cpu * 0.0446 + $memory * 0.00487) * $hours
  $private = [bool]$Answers.use_private_networking
  $sku = if ($Answers.Contains("container_registry_sku") -and $Answers.container_registry_sku) { $Answers.container_registry_sku } elseif ($private) { "Premium" } else { "Basic" }
  $perDay = @{ Basic = 0.17; Standard = 0.6666; Premium = 1.67 }
  $registry = $perDay[$sku] * 30.4
  $items = [ordered]@{ "$count agent instance(s), $cpu vCPU / $memory GB, running all month" = $instances; "Container registry $sku" = $registry }
  if ($private -and ($Answers.Contains("use_nat_gateway") -and $Answers.use_nat_gateway)) { $items["NAT gateway public IP"] = 0.005 * $hours }
  $items
}
$estimate = Get-CostEstimate $answers

Write-Section "Summary"
foreach ($key in $answers.Keys) { Write-Host ("  {0,-45} {1}" -f $key, (ConvertTo-Hcl $answers[$key]).Replace("`n", " ")) }
if ($estimate) {
  Write-Section "Rough monthly cost of the agent side (list prices, Canada Central, 2026-11-19)"
  foreach ($name in $estimate.Keys) { Write-Host ("  {0,-62} `${1,7:N0}" -f $name, $estimate[$name]) }
  Write-Host ("  {0,-62} `${1,7:N0}" -f "Total of the above", (($estimate.Values | Measure-Object -Sum).Sum))
  Write-Note "Not included: NAT gateway and private endpoints (billed per hour and per GB - see the Azure pricing calculator), storage, bandwidth."
  Write-Note "Lower it: fewer instances, 1 vCPU / 2 GB, a Basic registry (no private endpoint for the registry). Edit bootstrap.tfvars - the comments there say what each choice changes."
}

if ($interactive -and -not $AnswersFile) {
  $confirm = Read-Host "`nWrite these answers? [Y/n]"
  if ($confirm -match "^(n|no)$") { Write-Host "Nothing written."; exit 1 }
}

if (-not $OutputPath) { $OutputPath = Join-Path (Get-Location) "output\$($answers.project_name)-$($answers.environment_name)" }
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$OutputPath = (Resolve-Path -LiteralPath $OutputPath).Path
$tfvarsPath = Join-Path $OutputPath "bootstrap.tfvars"
Write-TfVars $answers $tfvarsPath
[System.IO.File]::WriteAllText((Join-Path $OutputPath "answers.json"), ((ConvertTo-Json $answers -Depth 6) + "`n"), [System.Text.UTF8Encoding]::new($false))
Write-Host "`nWrote $tfvarsPath"
Write-Host "Wrote $(Join-Path $OutputPath 'answers.json') (defaults for the next run; no secrets)"

if ($Mode -ne "Configure") { Invoke-Bootstrap $answers $OutputPath $Mode }
else {
  Write-Host "`nNext: .\New-ProjectBootstrap.ps1 -AnswersFile '$(Join-Path $OutputPath 'answers.json')' -OutputPath '$OutputPath' -Mode Plan"
}
