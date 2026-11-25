<#
.SYNOPSIS
Read-only check that what New-ProjectBootstrap.ps1 built is there and is wired the way it should be.

.DESCRIPTION
Reads <OutputPath>\outputs.json and answers.json, then asks Azure (the Azure CLI, signed in) and Azure
DevOps (REST, with a personal access token that needs only read scopes) whether each object exists and
is configured as built. It changes nothing. Every check ends as one of:

  PASS             as expected
  FAIL             present but wrong, or missing
  OFF BY DECISION  the answers turned it off (no agents, no approvers, no branch policies ...)
  BLOCKED          could not be checked: no token, no permission, a call that failed - say why

Exit code 0 when nothing FAILed and nothing is BLOCKED; 1 when something FAILed; 2 when nothing FAILed
but something is BLOCKED (not verified is not verified). The agents need minutes after an apply to build
their image and register: run it again if only the agent checks fail.

.EXAMPLE
.\Test-ProjectBootstrap.ps1 -OutputPath .\output\payments-prd
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $OutputPath,
  [switch] $SkipAzure,
  [switch] $SkipAzureDevOps
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$outputs = Get-Content -LiteralPath (Join-Path $OutputPath "outputs.json") -Raw | ConvertFrom-Json
$answers = Get-Content -LiteralPath (Join-Path $OutputPath "answers.json") -Raw | ConvertFrom-Json -AsHashtable
function Get-Answer([string] $Name, $Default) { if ($answers.ContainsKey($Name)) { $answers[$Name] } else { $Default } }

$results = [System.Collections.Generic.List[object]]::new()
$script:principals = @{}
$script:pipelineIds = @{}
function Add-Result([string] $State, [string] $Area, [string] $Check, [string] $Detail = "") {
  $results.Add([pscustomobject]@{ State = $State; Area = $Area; Check = $Check; Detail = $Detail })
  $color = switch ($State) { "PASS" { "Green" } "FAIL" { "Red" } "BLOCKED" { "Yellow" } default { "DarkGray" } }
  Write-Host ("  {0,-16} {1}{2}" -f $State, $Check, $(if ($Detail) { "  - $Detail" })) -ForegroundColor $color
}
# A check returns $true, or a string saying what is wrong; an exception means it could not be made.
function Test-Item([string] $Area, [string] $Check, [scriptblock] $Body) {
  try {
    $outcome = & $Body
    if ($outcome -is [string]) { Add-Result "FAIL" $Area $Check $outcome } elseif ($outcome) { Add-Result "PASS" $Area $Check } else { Add-Result "FAIL" $Area $Check }
  }
  catch { Add-Result "BLOCKED" $Area $Check $_.Exception.Message }
}
function Skip-Item([string] $Area, [string] $Check, [string] $Why) { Add-Result "OFF BY DECISION" $Area $Check $Why }

function Invoke-Az([string[]] $Arguments) {
  $output = & az @Arguments --only-show-errors -o json 2>&1
  if ($LASTEXITCODE -ne 0) { throw "az $($Arguments[0..2] -join ' ') failed: $(($output | Out-String).Trim())" }
  if (-not $output) { return $null }
  ($output -join "`n") | ConvertFrom-Json
}

$selfHosted = [bool](Get-Answer "use_self_hosted_agents" $true)
$private = $selfHosted -and [bool](Get-Answer "use_private_networking" $true)
$approvers = @(Get-Answer "approvers" @())
$approverGroups = @(Get-Answer "approver_entra_group_ids" @())
$hasApprovers = ($approvers.Count + $approverGroups.Count) -gt 0
$severalApprovers = $approvers.Count -gt 1 -or $approverGroups.Count -gt 0
$branchPolicies = [bool](Get-Answer "create_branch_policies" $true)

# ================================================================ Azure

if (-not $SkipAzure) {
  Write-Host "`nAzure"
  $state = $outputs.state_backend.value
  $agents = $outputs.agents.value
  $account = $null
  try { $account = Invoke-Az @("account", "show") } catch { }
  if (-not $account) { Add-Result "BLOCKED" "Azure" "Azure CLI sign-in" "not signed in: az login" }
  else {
    try { & az account set --subscription $state.subscription_id --only-show-errors } catch { }
    foreach ($group in @($outputs.resource_groups.value.PSObject.Properties.Value | Where-Object { $_ })) {
      Test-Item "Azure" "Resource group $group exists" { (Invoke-Az @("group", "show", "--name", $group)).properties.provisioningState -eq "Succeeded" }
    }
    Test-Item "Azure" "State storage account $($state.storage_account_name): no shared keys, TLS 1.2, $(if ($private) { 'no public access' } else { 'public endpoint (Microsoft-hosted agents)' })" {
      $sa = Invoke-Az @("storage", "account", "show", "--name", $state.storage_account_name, "--resource-group", $state.resource_group_name)
      if ($sa.allowSharedKeyAccess -ne $false) { return "shared-key access is not disabled" }
      if ($sa.minimumTlsVersion -ne "TLS1_2") { return "minimum TLS is $($sa.minimumTlsVersion)" }
      if ($sa.allowBlobPublicAccess -ne $false) { return "anonymous blob access is allowed" }
      if ($private -and $sa.publicNetworkAccess -ne "Disabled") { return "public network access is $($sa.publicNetworkAccess), expected Disabled" }
      $true
    }
    Test-Item "Azure" "State container $($state.container_name) exists" {
      $null -ne (Invoke-Az @("storage", "container-rm", "show", "--storage-account", $state.storage_account_name, "--resource-group", $state.resource_group_name, "--name", $state.container_name))
    }
    $containerScope = "/subscriptions/$($state.subscription_id)/resourceGroups/$($state.resource_group_name)/providers/Microsoft.Storage/storageAccounts/$($state.storage_account_name)/blobServices/default/containers/$($state.container_name)"
    foreach ($key in "plan", "apply") {
      $identity = $outputs.identities.value.$key
      Test-Item "Azure" "Identity $($identity.name) exists and signs in only through Azure DevOps (one federated credential)" {
        $found = Invoke-Az @("identity", "list", "--resource-group", $outputs.resource_groups.value.identity)
        $mine = @($found | Where-Object { $_.name -eq $identity.name })
        if ($mine.Count -ne 1) { return "identity not found" }
        $script:principals[$key] = $mine[0].principalId
        $credentials = @(Invoke-Az @("identity", "federated-credential", "list", "--identity-name", $identity.name, "--resource-group", $mine[0].resourceGroup))
        if ($credentials.Count -ne 1) { return "$($credentials.Count) federated credentials, expected 1" }
        if ($credentials[0].issuer -notmatch "vstoken\.dev\.azure\.com|login\.microsoftonline\.com") { return "unexpected issuer $($credentials[0].issuer)" }
        $true
      }
      Test-Item "Azure" "$($identity.name) holds $($identity.role) on $(@($outputs.role_assignment_scopes.value).Count) scope(s) and data access on the state container" {
        if (-not $script:principals.ContainsKey($key)) { throw "identity was not found above" }
        $principal = $script:principals[$key]
        foreach ($scope in $outputs.role_assignment_scopes.value) {
          $assigned = @(Invoke-Az @("role", "assignment", "list", "--assignee", $principal, "--scope", $scope))
          if (-not ($assigned | Where-Object { $_.roleDefinitionName -eq $identity.role -and $_.scope -eq $scope })) { return "no $($identity.role) at $scope" }
        }
        $data = @(Invoke-Az @("role", "assignment", "list", "--assignee", $principal, "--scope", $containerScope))
        $dataRole = if ($key -eq "plan" -and -not [bool](Get-Answer "plan_can_write_state" $false)) { "Storage Blob Data Reader" } else { "Storage Blob Data Contributor" }
        if (-not ($data | Where-Object { $_.roleDefinitionName -eq $dataRole })) { return "no $dataRole on the state container" }
        if ($key -eq "plan" -and $dataRole -eq "Storage Blob Data Reader" -and ($data | Where-Object { $_.roleDefinitionName -eq "Storage Blob Data Contributor" })) { return "the plan identity can write the state although plan_can_write_state is false" }
        $true
      }
    }

    if (-not $selfHosted) { Skip-Item "Azure" "Container registry, agents, network" "use_self_hosted_agents = false: Microsoft-hosted agents" }
    else {
      Test-Item "Azure" "Container registry $($agents.container_registry) ($($agents.container_registry_sku)$(if ($agents.registry_private) { ', no public access' } else { ', public endpoint with sign-in' }))" {
        $acr = Invoke-Az @("acr", "show", "--name", $agents.container_registry)
        $expectedSku = $agents.container_registry_sku
        if ($acr.sku.name -ne $expectedSku) { return "SKU is $($acr.sku.name), expected $expectedSku" }
        if ($agents.registry_private -and $acr.publicNetworkAccess -ne "Disabled") { return "public network access is $($acr.publicNetworkAccess)" }
        $true
      }
      Test-Item "Azure" "The agent image was built (the registry's last task run succeeded)" {
        # Through the Resource Manager: the registry's own endpoint is closed to a workstation when private.
        $runs = @(Invoke-Az @("acr", "task", "list-runs", "--registry", $agents.container_registry, "--top", "1"))
        if ($runs.Count -lt 1) { return "no task run yet" }
        if ($runs[0].status -eq "Succeeded") { $true } else { "the last run is $($runs[0].status) - it may still be running" }
      }
      Test-Item "Azure" "Agent container instances running ($(@($agents.container_instances).Count))" {
        foreach ($name in $agents.container_instances) {
          $group = Invoke-Az @("container", "show", "--name", $name, "--resource-group", $agents.agent_resource_group)
          $current = $group.containers[0].instanceView.currentState.state
          if ($current -ne "Running") { return "$name is $current" }
        }
        $true
      }
      if (-not $private) { Skip-Item "Azure" "Virtual network, NAT gateway, private endpoints, private DNS" "use_private_networking = false" }
      else {
        Test-Item "Azure" "Virtual network $($agents.virtual_network) with the agent and private-endpoint subnets" {
          $vnet = Invoke-Az @("network", "vnet", "show", "--name", $agents.virtual_network, "--resource-group", $outputs.resource_groups.value.network)
          if (@($vnet.subnets).Count -ne 2) { return "$(@($vnet.subnets).Count) subnets, expected 2" }
          if (-not ($vnet.subnets | Where-Object { "Microsoft.ContainerInstance/containerGroups" -in @($_.delegations | ForEach-Object { $_.serviceName }) })) { return "no subnet is delegated to container instances" }
          $bare = @($vnet.subnets | Where-Object { -not $_.networkSecurityGroup }).Count
          if ($bare -gt 0) { return "$bare subnet(s) without a network security group" }
          $true
        }
        if (-not $agents.nat_gateway) { Skip-Item "Azure" "NAT gateway and its public IP" "use_nat_gateway = false (no public IP addresses); the agent subnet routes through agent_route_table_id" }
        else {
          Test-Item "Azure" "NAT gateway $($agents.nat_gateway) gives the agents one outbound address ($($agents.nat_public_ip))" {
            $nat = Invoke-Az @("network", "nat", "gateway", "show", "--name", $agents.nat_gateway, "--resource-group", $outputs.resource_groups.value.network)
            if (@($nat.publicIpAddresses).Count -ne 1) { return "no public IP attached" }
            if (@($nat.subnets).Count -lt 1) { return "no subnet uses it" }
            $true
          }
        }
        Test-Item "Azure" "Private endpoints approved: $(@($agents.private_endpoints) -join ', ')" {
          foreach ($name in $agents.private_endpoints) {
            $endpoint = Invoke-Az @("network", "private-endpoint", "show", "--name", $name, "--resource-group", $outputs.resource_groups.value.network)
            $status = $endpoint.privateLinkServiceConnections[0].privateLinkServiceConnectionState.status
            if ($status -ne "Approved") { return "$name is $status" }
          }
          $true
        }
        Test-Item "Azure" "Private DNS zones linked to the network: $(@($agents.private_dns_zones) -join ', ')" {
          $network = $outputs.resource_groups.value.network
          foreach ($zone in $agents.private_dns_zones) {
            $links = @(Invoke-Az @("network", "private-dns", "link", "vnet", "list", "--zone-name", $zone, "--resource-group", $network))
            if ($links.Count -lt 1) { return "$zone has no virtual network link" }
          }
          $true
        }
      }
    }
  }
}

# ================================================================ Azure DevOps

if (-not $SkipAzureDevOps) {
  Write-Host "`nAzure DevOps"
  $devops = $outputs.azure_devops.value
  $token = $env:TF_VAR_azure_devops_personal_access_token
  if (-not $token) { $token = $env:AZDO_PERSONAL_ACCESS_TOKEN }
  if (-not $token) { $secure = Read-Host "Azure DevOps personal access token (read scopes are enough)" -AsSecureString; $token = [System.Net.NetworkCredential]::new("", $secure).Password }
  $headers = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$token")) }
  $organization = $devops.organization_url.TrimEnd("/")
  $project = [uri]::EscapeDataString($devops.project_name)
  function Invoke-DevOps([string] $Path, [string] $Base = $organization) { Invoke-RestMethod -Headers $headers -Uri "$Base/$Path" }

  Test-Item "Azure DevOps" "Project $($devops.project_name) exists" { (Invoke-DevOps "_apis/projects/$project`?api-version=7.1").state -eq "wellFormed" }

  $repositories = @{}
  foreach ($pair in @(@{ Role = "main"; Name = $devops.repository }, @{ Role = "templates"; Name = $devops.templates_repository })) {
    Test-Item "Azure DevOps" "Repository $($pair.Name) exists with main as its default branch" {
      $repo = Invoke-DevOps "$project/_apis/git/repositories/$([uri]::EscapeDataString($pair.Name))?api-version=7.1"
      $repositories[$pair.Role] = $repo
      if ($repo.defaultBranch -ne "refs/heads/main") { return "default branch is $($repo.defaultBranch)" }
      $true
    }
  }
  $expectedFiles = @{
    main      = @("README.md", ".gitignore", "main.tf", "variables.tf", "terraform.tf", "providers.tf", "terraform.tfvars", ".pipelines/ci.yaml", ".pipelines/cd.yaml", "docs/getting-started.md", "docs/operations.md")
    templates = @("README.md", ".pipelines/ci-template.yaml", ".pipelines/cd-template.yaml", ".pipelines/helpers/terraform-plan.yaml", ".pipelines/helpers/terraform-plan-summary.yaml", ".pipelines/helpers/terraform-apply.yaml", ".pipelines/helpers/terraform-init.yaml", ".pipelines/helpers/terraform-installer.yaml")
  }
  foreach ($role in "main", "templates") {
    Test-Item "Azure DevOps" "The $role repository holds its starter files ($(@($expectedFiles[$role]).Count))" {
      if (-not $repositories.ContainsKey($role)) { throw "repository was not found above" }
      $missing = @(foreach ($path in $expectedFiles[$role]) {
        try { Invoke-DevOps "$project/_apis/git/repositories/$($repositories[$role].id)/items?path=/$path&api-version=7.1" | Out-Null } catch { $path }
      })
      if ($missing.Count -gt 0) { "missing: $($missing -join ', ')" } else { $true }
    }
  }

  if (-not $branchPolicies) { Skip-Item "Azure DevOps" "Branch policies on main" "create_branch_policies = false" }
  else {
    foreach ($role in "main", "templates") {
      Test-Item "Azure DevOps" "Branch policies on main of the $role repository" {
        if (-not $repositories.ContainsKey($role)) { throw "repository was not found above" }
        $policies = @((Invoke-DevOps "$project/_apis/policy/configurations?repositoryId=$($repositories[$role].id)&refName=refs/heads/main&api-version=7.1").value | Where-Object { $_.isEnabled })
        $names = @($policies | ForEach-Object { $_.type.displayName })
        if ("Require a merge strategy" -notin $names) { return "no merge-strategy (squash) policy" }
        if ($role -eq "main" -and "Build" -notin $names) { return "no build-validation policy (CI must pass)" }
        if ($severalApprovers -and "Minimum number of reviewers" -notin $names) { return "several approvers but no minimum-reviewers policy" }
        $true
      }
    }
  }

  foreach ($key in "ci", "cd") {
    Test-Item "Azure DevOps" "Pipeline '$($devops.pipelines.$key)' exists and runs .pipelines/$key.yaml from the main repository" {
      $definition = @((Invoke-DevOps "$project/_apis/build/definitions?name=$([uri]::EscapeDataString($devops.pipelines.$key))&api-version=7.1").value)
      if ($definition.Count -ne 1) { return "found $($definition.Count)" }
      $detail = Invoke-DevOps "$project/_apis/build/definitions/$($definition[0].id)?api-version=7.1"
      $script:pipelineIds[$key] = $definition[0].id
      if ($detail.process.yamlFilename -ne ".pipelines/$key.yaml") { return "runs $($detail.process.yamlFilename)" }
      $true
    }
  }
  Test-Item "Azure DevOps" "CI is a build-validation policy of main" {
    if (-not $branchPolicies) { return $true }
    $policies = @((Invoke-DevOps "$project/_apis/policy/configurations?repositoryId=$($repositories['main'].id)&refName=refs/heads/main&api-version=7.1").value | Where-Object { $_.isEnabled -and $_.type.displayName -eq "Build" })
    if ($policies.Count -lt 1) { return "no build policy" }
    if ($script:pipelineIds.ContainsKey("ci") -and [string]$policies[0].settings.buildDefinitionId -ne [string]$script:pipelineIds["ci"]) { return "the policy runs another pipeline" }
    $true
  }

  Test-Item "Azure DevOps" "Variable group $($devops.variable_group) carries the state backend names" {
    $group = @((Invoke-DevOps "$project/_apis/distributedtask/variablegroups?groupName=$([uri]::EscapeDataString($devops.variable_group))&api-version=7.1-preview.2").value)
    if ($group.Count -ne 1) { return "found $($group.Count)" }
    $state = $outputs.state_backend.value
    $v = $group[0].variables
    if ($v.BACKEND_AZURE_RESOURCE_GROUP_NAME.value -ne $state.resource_group_name) { return "BACKEND_AZURE_RESOURCE_GROUP_NAME differs" }
    if ($v.BACKEND_AZURE_STORAGE_ACCOUNT_NAME.value -ne $state.storage_account_name) { return "BACKEND_AZURE_STORAGE_ACCOUNT_NAME differs" }
    if ($v.BACKEND_AZURE_STORAGE_ACCOUNT_CONTAINER_NAME.value -ne $state.container_name) { return "BACKEND_AZURE_STORAGE_ACCOUNT_CONTAINER_NAME differs" }
    $true
  }

  $environmentIds = @{}
  foreach ($key in "plan", "apply") {
    Test-Item "Azure DevOps" "Environment $($devops.environments.$key) exists" {
      $found = @((Invoke-DevOps "$project/_apis/pipelines/environments?name=$([uri]::EscapeDataString($devops.environments.$key))&api-version=7.1").value)
      if ($found.Count -ne 1) { return "found $($found.Count)" }
      $environmentIds[$key] = $found[0].id
      $true
    }
  }

  $connectionIds = @{}
  foreach ($key in "plan", "apply") {
    $name = $devops.service_connections.$key
    Test-Item "Azure DevOps" "Service connection ${name}: Azure, workload identity federation (no secret), ready, signs in as the $key identity" {
      $found = @((Invoke-DevOps "$project/_apis/serviceendpoint/endpoints?endpointNames=$([uri]::EscapeDataString($name))&api-version=7.1").value)
      if ($found.Count -ne 1) { return "found $($found.Count)" }
      $endpoint = $found[0]; $connectionIds[$key] = $endpoint.id
      if ($endpoint.type -ne "azurerm") { return "type is $($endpoint.type)" }
      if ($endpoint.authorization.scheme -ne "WorkloadIdentityFederation") { return "scheme is $($endpoint.authorization.scheme)" }
      if (-not $endpoint.isReady) { return "not ready" }
      if ($endpoint.authorization.parameters.serviceprincipalid -ne $outputs.identities.value.$key.client_id) { return "signs in as another identity" }
      $true
    }
  }

  foreach ($key in "plan", "apply") {
    Test-Item "Azure DevOps" "Checks on the $key connection: exclusive lock, required template$(if ($key -eq 'apply') { ', apply only from main' })$(if ($key -eq 'apply' -and $hasApprovers) { ', approval' })" {
      if (-not $connectionIds.ContainsKey($key)) { throw "connection was not found above" }
      $checks = @((Invoke-DevOps "$project/_apis/pipelines/checks/configurations?resourceType=endpoint&resourceId=$($connectionIds[$key])&`$expand=settings&api-version=7.1-preview.1").value)
      $types = @($checks | ForEach-Object { $_.type.name })
      if ("ExclusiveLock" -notin $types) { return "no exclusive lock" }
      $template = @($checks | Where-Object { $_.type.name -eq "ExtendsCheck" })
      if ($template.Count -ne 1) { return "no required-template check" }
      $paths = @($template[0].settings.extendsChecks | ForEach-Object { $_.templatePath })
      $expected = if ($key -eq "apply") { @(".pipelines/cd-template.yaml") } else { @(".pipelines/ci-template.yaml", ".pipelines/cd-template.yaml") }
      foreach ($path in $expected) { if ($path -notin $paths) { return "required templates do not include $path" } }
      if ($key -eq "apply" -and $hasApprovers -and "Approval" -notin $types) { return "no approval check" }
      if ($key -eq "plan" -and "Approval" -in $types) { return "the plan connection must not wait for an approval" }
      if ($key -eq "apply") {
        $branch = @($checks | Where-Object { $_.PSObject.Properties.Name -contains "settings" -and $_.settings -and $_.settings.PSObject.Properties.Name -contains "definitionRef" -and $_.settings.definitionRef.name -eq "evaluatebranchProtection" })
        if ($branch.Count -ne 1) { return "no branch control check (apply only from main)" }
        if ([string]$branch[0].settings.inputs.allowedBranches -notmatch "refs/heads/main") { return "the branch control check does not allow refs/heads/main" }
      }
      $true
    }
  }
  if (-not $hasApprovers) { Skip-Item "Azure DevOps" "Approval check and approvers group membership" "no approvers were given" }
  else {
    Test-Item "Azure DevOps" "Approvers group $($devops.approvers_group) has $($approvers.Count + $approverGroups.Count) member(s) ($($approvers.Count) people, $($approverGroups.Count) Entra group(s))" {
      $organizationName = ([uri]$organization).AbsolutePath.Trim("/")
      $filter = [uri]::EscapeDataString("[$($devops.project_name)]\$($devops.approvers_group)")
      $identity = @((Invoke-DevOps "$organizationName/_apis/identities?searchFilter=General&filterValue=$filter&queryMembership=Direct&api-version=7.1" "https://vssps.dev.azure.com").value)
      if ($identity.Count -ne 1) { return "group not found" }
      $expectedMembers = $approvers.Count + $approverGroups.Count
      if (@($identity[0].members).Count -ne $expectedMembers) { return "$(@($identity[0].members).Count) members, expected $expectedMembers" }
      $true
    }
  }

  Test-Item "Azure DevOps" "Pipelines are authorised for their connections and environments" {
    if ($script:pipelineIds.Count -lt 2 -or $connectionIds.Count -lt 2 -or $environmentIds.Count -lt 2) { throw "pipelines, connections or environments were not found above" }
    $expectations = @(
      @{ Type = "endpoint"; Id = $connectionIds["plan"]; Pipelines = @("ci", "cd") }, @{ Type = "endpoint"; Id = $connectionIds["apply"]; Pipelines = @("cd") },
      @{ Type = "environment"; Id = $environmentIds["plan"]; Pipelines = @("ci", "cd") }, @{ Type = "environment"; Id = $environmentIds["apply"]; Pipelines = @("cd") }
    )
    foreach ($e in $expectations) {
      $permission = Invoke-DevOps "$project/_apis/pipelines/pipelinepermissions/$($e.Type)/$($e.Id)?api-version=7.1-preview.1"
      $authorized = @($permission.pipelines | Where-Object { $_.authorized } | ForEach-Object { [string]$_.id })
      foreach ($pipeline in $e.Pipelines) { if ([string]$script:pipelineIds[$pipeline] -notin $authorized) { return "the $pipeline pipeline is not authorised for $($e.Type) $($e.Id)" } }
    }
    $true
  }

  if (-not $selfHosted) { Skip-Item "Azure DevOps" "Agent pool and registered agents" "use_self_hosted_agents = false" }
  else {
    Test-Item "Azure DevOps" "Agent pool $($devops.agent_pool): $(@($outputs.agents.value.container_instances).Count) agent(s) online" {
      $pool = @((Invoke-DevOps "_apis/distributedtask/pools?poolName=$([uri]::EscapeDataString($devops.agent_pool))&api-version=7.1").value)
      if ($pool.Count -ne 1) { return "pool not found" }
      $agentsOnline = @((Invoke-DevOps "_apis/distributedtask/pools/$($pool[0].id)/agents?api-version=7.1").value | Where-Object { $_.status -eq "online" })
      $expectedAgents = @($outputs.agents.value.container_instances).Count
      if ($agentsOnline.Count -lt $expectedAgents) { return "$($agentsOnline.Count) online, expected $expectedAgents - they register a few minutes after the apply" }
      $true
    }
  }
}

# ================================================================ result

$counts = @{ PASS = 0; FAIL = 0; "OFF BY DECISION" = 0; BLOCKED = 0 }
foreach ($r in $results) { $counts[$r.State]++ }
Write-Host ("`nPASS {0}   FAIL {1}   OFF BY DECISION {2}   BLOCKED {3}" -f $counts.PASS, $counts.FAIL, $counts["OFF BY DECISION"], $counts.BLOCKED)
if ($counts.FAIL -gt 0) { exit 1 }
if ($counts.BLOCKED -gt 0) { exit 2 }
exit 0
