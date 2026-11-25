# The bootstrap against mock providers: every name, role, scope, check and rendered file. Nothing is
# created anywhere. The live proof is a run in a lab subscription and organization (README, "Proving
# a change").

mock_provider "azuredevops" {
  source = "./tests/mocks/azuredevops"
}

mock_provider "azurerm" {
  source = "./tests/mocks/azurerm"
}

mock_provider "azapi" {
  source = "./tests/mocks/azapi"
}

# The subnets are azapi resources; an azurerm private endpoint and container group parse their IDs.
override_resource {
  target = azapi_resource.subnet_container_instances
  values = {
    id = "/subscriptions/e1d19c4d-0000-4000-8000-000000000001/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock/subnets/snet-aci"
  }
}

override_resource {
  target = azapi_resource.subnet_private_endpoints
  values = {
    id = "/subscriptions/e1d19c4d-0000-4000-8000-000000000001/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock/subnets/snet-pe"
  }
}

variables {
  project_name                  = "payments"
  environment_name              = "lab"
  azure_location                = "canadacentral"
  location_short                = "cac"
  bootstrap_subscription_id     = "e1d19c4d-0000-4000-8000-000000000001"
  azure_devops_organization_url = "https://dev.azure.com/contoso"
  azure_devops_project_name     = "Payments Platform"
  repository_name               = "payments-infra"
  pipeline_display_name         = "Payments Infra"
  approvers                     = ["user@example.com"]
  tags = {
    organizationName = "Contoso"
    environment      = "lab"
    managedBy        = "Terraform"
    appContact       = "platform-team@contoso.com"
    owner            = "platform-team"
  }
  azure_devops_personal_access_token = "mock-token"
  azure_devops_agent_pat             = "mock-agent-token"
}

run "defaults_with_private_networking" {
  command = apply
  # Its own state, so the plan-only runs below start from nothing: a file already in the state keeps
  # its content (ignore_changes), which would hide the effect of the variables they change.
  state_key = "defaults"

  # ---- Azure: state
  assert {
    condition     = azurerm_resource_group.state.name == "rg-payments-lab-cac-001-state"
    error_message = "The state resource group name does not follow the pattern."
  }
  assert {
    condition     = length(azurerm_storage_account.state.name) <= 24 && startswith(azurerm_storage_account.state.name, "stpaymentslab")
    error_message = "The storage account name is outside 24 characters or lacks the project and environment."
  }
  assert {
    condition     = azurerm_storage_account.state.shared_access_key_enabled == false && azurerm_storage_account.state.public_network_access_enabled == false
    error_message = "State storage must have shared keys off and no public network access with private networking."
  }
  assert {
    condition     = output.state_backend.container_name == "tfstate"
    error_message = "The state container must be tfstate."
  }

  # ---- Azure: identities and roles
  assert {
    condition     = azurerm_user_assigned_identity.pipeline["plan"].name == "id-payments-lab-cac-001-plan" && azurerm_user_assigned_identity.pipeline["apply"].name == "id-payments-lab-cac-001-apply"
    error_message = "The plan and apply identities are not named as the pattern says."
  }
  assert {
    condition     = azurerm_federated_identity_credential.pipeline["plan"].audience[0] == "api://AzureADTokenExchange" && length(azurerm_federated_identity_credential.pipeline) == 2
    error_message = "Each identity needs one federated credential with the token-exchange audience."
  }
  assert {
    condition     = length(azurerm_role_assignment.state_container) == 2 && azurerm_role_assignment.state_container["plan"].role_definition_name == "Storage Blob Data Reader" && azurerm_role_assignment.state_container["apply"].role_definition_name == "Storage Blob Data Contributor"
    error_message = "By default the plan identity only reads the state container and the apply identity writes it."
  }
  assert {
    condition     = azurerm_role_assignment.target["plan-subscription-e1d19c4d-0000-4000-8000-000000000001"].role_definition_name == "Reader" && azurerm_role_assignment.target["apply-subscription-e1d19c4d-0000-4000-8000-000000000001"].role_definition_name == "Contributor"
    error_message = "Plan must be Reader and apply Contributor on the bootstrap subscription by default."
  }

  # ---- Azure: agents and network
  assert {
    condition     = azurerm_container_registry.agents[0].sku == "Premium" && azurerm_container_registry.agents[0].public_network_access_enabled == false
    error_message = "Private networking needs a Premium registry with no public access."
  }
  assert {
    condition     = length(azurerm_private_endpoint.endpoints) == 2 && length(azurerm_private_dns_zone.endpoints) == 2
    error_message = "Storage and registry each need a private endpoint and a private DNS zone."
  }
  assert {
    condition     = length(azurerm_container_group.agents) == 2 && azurerm_container_group.agents["01"].name == "aci-payments-lab-cac-001-01"
    error_message = "Two agent container instances were expected."
  }
  assert {
    condition     = length(azurerm_nat_gateway.agents) == 1 && length(azurerm_public_ip.nat) == 1
    error_message = "A NAT gateway and its public IP were expected."
  }

  # ---- Azure DevOps
  assert {
    condition     = azuredevops_build_definition.pipeline["ci"].name == "01 Payments Infra Continuous Integration" && azuredevops_build_definition.pipeline["cd"].name == "02 Payments Infra Continuous Delivery"
    error_message = "The pipelines must be named 01 <name> Continuous Integration and 02 <name> Continuous Delivery."
  }
  assert {
    condition     = azuredevops_environment.pipeline["plan"].name == "payments-lab-plan" && azuredevops_environment.pipeline["apply"].name == "payments-lab-apply"
    error_message = "The plan and apply environments are missing or misnamed."
  }
  assert {
    condition     = azuredevops_serviceendpoint_azurerm.pipeline["plan"].service_endpoint_authentication_scheme == "WorkloadIdentityFederation" && azuredevops_serviceendpoint_azurerm.pipeline["apply"].service_endpoint_authentication_scheme == "WorkloadIdentityFederation"
    error_message = "Both service connections must use workload identity federation."
  }
  assert {
    condition     = length(azuredevops_check_required_template.pipeline["plan"].required_template) == 2 && length(azuredevops_check_required_template.pipeline["apply"].required_template) == 1
    error_message = "The plan connection requires the CI or CD template; the apply connection only the CD template."
  }
  assert {
    condition     = length(azuredevops_check_exclusive_lock.pipeline) == 2 && length(azuredevops_check_approval.apply) == 1
    error_message = "Both connections need an exclusive lock and the apply connection an approval."
  }
  assert {
    condition     = azuredevops_check_branch_control.apply.allowed_branches == "refs/heads/main" && azuredevops_check_branch_control.apply.verify_branch_protection == true && azuredevops_check_branch_control.apply.target_resource_type == "endpoint"
    error_message = "The apply connection must be usable from main only, and only while main is protected."
  }
  assert {
    condition     = length(azuredevops_pipeline_authorization.templates_repository) == 2
    error_message = "Both pipelines must be authorised for the templates repository."
  }
  assert {
    condition     = strcontains(azuredevops_git_repository_file.main[".pipelines/ci.yaml"].content, "plan_takes_state_lock: false") && strcontains(azuredevops_git_repository_file.main[".pipelines/cd.yaml"].content, "plan_takes_state_lock: false")
    error_message = "Pipelines must tell the templates the plan identity does not take the state lock."
  }
  assert {
    condition     = length(azuredevops_pipeline_authorization.environment) == 3 && length(azuredevops_pipeline_authorization.service_connection) == 3 && length(azuredevops_pipeline_authorization.agent_pool) == 2
    error_message = "CI uses plan only, CD uses plan and apply, and both use the pool."
  }
  assert {
    condition     = azuredevops_agent_pool.agents[0].name == "payments-lab"
    error_message = "The agent pool is missing."
  }
  assert {
    condition     = azuredevops_branch_policy_min_reviewers.main["main"].enabled == false && azuredevops_branch_policy_merge_types.main["main"].enabled == true && azuredevops_branch_policy_build_validation.ci.enabled == true
    error_message = "One approver cannot review their own change, so the reviewer rule is off; the squash-merge and CI rules are on."
  }

  # ---- the repositories' content
  assert {
    condition     = azuredevops_git_repository.templates.name == "payments-infra-templates"
    error_message = "The templates repository defaults to <repository>-templates."
  }
  assert {
    condition     = alltrue([for path in [".gitignore", ".editorconfig", "README.md", "main.tf", "variables.tf", "providers.tf", "terraform.tf", "terraform.tfvars", "outputs.tf", "docs/getting-started.md", "docs/operations.md", "modules/README.md", ".pipelines/ci.yaml", ".pipelines/cd.yaml"] : azuredevops_git_repository_file.main[path].file == path])
    error_message = "A starter file is missing from the main repository."
  }
  assert {
    condition     = alltrue([for path in ["README.md", ".gitignore", ".pipelines/ci-template.yaml", ".pipelines/cd-template.yaml", ".pipelines/helpers/terraform-installer.yaml", ".pipelines/helpers/terraform-init.yaml", ".pipelines/helpers/terraform-plan.yaml", ".pipelines/helpers/terraform-plan-summary.yaml", ".pipelines/helpers/terraform-apply.yaml"] : azuredevops_git_repository_file.templates[path].file == path])
    error_message = "A template file is missing from the templates repository."
  }
  assert {
    condition     = strcontains(azuredevops_git_repository_file.main[".pipelines/ci.yaml"].content, "$${{ coalesce(parameters.terraform_cli_version, 'latest') }}") && !strcontains(azuredevops_git_repository_file.main[".pipelines/ci.yaml"].content, "$$")
    error_message = "ci.yaml must contain a literal Azure DevOps template expression, with no stray escape."
  }
  assert {
    condition     = strcontains(azuredevops_git_repository_file.main[".pipelines/cd.yaml"].content, "apply_service_connection_name: 'sc-payments-lab-apply'") && strcontains(azuredevops_git_repository_file.main[".pipelines/cd.yaml"].content, "agent_pool_name: 'payments-lab'") && strcontains(azuredevops_git_repository_file.main[".pipelines/cd.yaml"].content, "name: 'Payments Platform/payments-infra-templates'")
    error_message = "cd.yaml must name the connection, the pool and the templates repository."
  }
  assert {
    condition     = strcontains(azuredevops_git_repository_file.main["terraform.tfvars"].content, "subscription_id = \"e1d19c4d-0000-4000-8000-000000000001\"") && strcontains(azuredevops_git_repository_file.main["terraform.tfvars"].content, "\"owner\" = \"platform-team\"") && strcontains(azuredevops_git_repository_file.main["terraform.tfvars"].content, "\"repository\" = \"dev.azure.com/contoso/Payments%20Platform/payments-infra\"")
    error_message = "terraform.tfvars must carry the subscription and the tags."
  }
  assert {
    condition     = strcontains(azuredevops_git_repository_file.main[".pipelines/ci.yaml"].content, "01 Payments Infra Continuous Integration") && strcontains(azuredevops_git_repository_file.main["docs/getting-started.md"].content, "user@example.com")
    error_message = "The starter files must name the pipelines and the approvers."
  }
  assert {
    condition     = alltrue([for path, file in azuredevops_git_repository_file.main : !strcontains(file.content, "\r")]) && alltrue([for path, file in azuredevops_git_repository_file.templates : !strcontains(file.content, "\r")])
    error_message = "Files must be committed with LF line endings, whatever the kit's were checked out with."
  }
  assert {
    condition     = alltrue([for path in keys(azuredevops_git_repository_file.main) : !endswith(path, ".tftpl")])
    error_message = "A .tftpl suffix leaked into the repository."
  }
}

run "without_agents_uses_microsoft_hosted" {
  command = plan

  variables {
    use_self_hosted_agents = false
  }

  assert {
    condition     = length(azurerm_container_registry.agents) == 0 && length(azurerm_container_group.agents) == 0 && length(azurerm_virtual_network.agents) == 0 && length(azurerm_private_endpoint.endpoints) == 0 && length(azuredevops_agent_pool.agents) == 0
    error_message = "Without self-hosted agents there is no registry, container instance, network, endpoint or pool."
  }
  assert {
    condition     = azurerm_storage_account.state.public_network_access_enabled == true
    error_message = "With no agents in a network, the state storage must be reachable by the Microsoft-hosted agents (Azure AD sign-in still required)."
  }
  assert {
    condition     = strcontains(azuredevops_git_repository_file.main[".pipelines/ci.yaml"].content, "agent_pool_name: ''")
    error_message = "ci.yaml must pass an empty pool name, which the templates read as a Microsoft-hosted agent."
  }
  assert {
    condition     = length(azuredevops_pipeline_authorization.agent_pool) == 0
    error_message = "No pool, so no pool authorisation."
  }
}

run "agents_without_private_networking" {
  command = plan

  variables {
    use_private_networking = false
  }

  assert {
    condition     = azurerm_container_registry.agents[0].sku == "Basic" && length(azurerm_private_endpoint.endpoints) == 0 && length(azurerm_virtual_network.agents) == 0
    error_message = "Without private networking the registry is Basic and there is no network or endpoint."
  }
  assert {
    condition     = azurerm_container_group.agents["01"].ip_address_type == "None"
    error_message = "A container instance outside a network has no IP address."
  }
}

run "no_approvers" {
  command = plan

  variables {
    approvers = []
  }

  assert {
    condition     = length(azuredevops_check_approval.apply) == 0
    error_message = "With no approvers there is no approval check."
  }
}

run "several_approvers_turn_on_the_reviewer_rule" {
  command = plan

  variables {
    approvers = ["user@example.com", "other@example.com"]
  }

  assert {
    condition     = azuredevops_branch_policy_min_reviewers.main["main"].enabled == true && azuredevops_branch_policy_min_reviewers.main["templates"].enabled == true
    error_message = "With more than one approver, a pull request needs one reviewer other than the last pusher in both repositories."
  }
  assert {
    condition     = azuredevops_check_approval.apply[0].requester_can_approve == false
    error_message = "With several approvers the requester cannot approve their own run."
  }
}

run "entra_group_approvers" {
  command = plan

  variables {
    approvers                = []
    approver_entra_group_ids = ["11111111-2222-4333-8444-555555555555"]
  }

  assert {
    condition     = length(azuredevops_group.approver_entra) == 1 && length(azuredevops_check_approval.apply) == 1
    error_message = "An Entra group alone must create its Azure DevOps group and the approval check."
  }
  assert {
    condition     = azuredevops_check_approval.apply[0].requester_can_approve == false && azuredevops_branch_policy_min_reviewers.main["main"].enabled == true
    error_message = "A group is taken to hold several people: the requester cannot approve and the reviewer rule is on."
  }
}

run "entra_group_id_must_be_a_guid" {
  command = plan

  variables {
    approver_entra_group_ids = ["Finance Approvers DL"]
  }

  expect_failures = [var.approver_entra_group_ids]
}

run "registry_sku_basic_with_private_network_has_no_registry_endpoint" {
  command = plan

  variables {
    container_registry_sku = "Basic"
  }

  assert {
    condition     = azurerm_container_registry.agents[0].sku == "Basic" && azurerm_container_registry.agents[0].public_network_access_enabled == true
    error_message = "A Basic registry keeps a public endpoint."
  }
  assert {
    condition     = length(azurerm_private_endpoint.endpoints) == 1 && contains(keys(azurerm_private_endpoint.endpoints), "storage") && length(azapi_update_resource.registry_tasks_bypass) == 0
    error_message = "Only the state storage keeps its private endpoint, and the closed-registry task bypass is not used."
  }
  assert {
    condition     = length(azurerm_virtual_network.agents) == 1 && length(azurerm_nat_gateway.agents) == 1
    error_message = "The agents are still in the private network behind the NAT gateway."
  }
}

run "registry_sku_standard_is_accepted" {
  command = plan

  variables {
    container_registry_sku = "Standard"
    use_private_networking = false
  }

  assert {
    condition     = azurerm_container_registry.agents[0].sku == "Standard"
    error_message = "An explicit SKU must be used."
  }
}

run "registry_sku_unknown_is_refused" {
  command = plan

  variables {
    container_registry_sku = "Ultra"
  }

  expect_failures = [var.container_registry_sku]
}

run "agent_size_and_count_are_configurable" {
  command = plan

  variables {
    agent_container_instance_count = 1
    agent_container_cpu            = 1
    agent_container_memory         = 2
  }

  assert {
    condition     = length(azurerm_container_group.agents) == 1 && azurerm_container_group.agents["01"].container[0].cpu == 1 && azurerm_container_group.agents["01"].container[0].memory == 2
    error_message = "Instance count, CPU and memory come from the variables."
  }
}

run "tags_on_every_resource_that_takes_them" {
  command = plan

  assert {
    condition     = jsonencode(output.tags) == jsonencode({ organizationName = "Contoso", environment = "lab", managedBy = "Terraform", appContact = "platform-team@contoso.com", owner = "platform-team", repository = "dev.azure.com/contoso/Payments%20Platform/payments-infra" })
    error_message = "The tags are the given ones plus the automatic repository tag (organization/project/repository, space as %20)."
  }
  assert {
    condition = alltrue([for t in [
      azurerm_resource_group.state.tags, azurerm_resource_group.identity.tags, azurerm_resource_group.agents[0].tags, azurerm_resource_group.network[0].tags,
      azurerm_storage_account.state.tags, azurerm_user_assigned_identity.pipeline["plan"].tags, azurerm_user_assigned_identity.pipeline["apply"].tags,
      azurerm_user_assigned_identity.agent[0].tags, azurerm_virtual_network.agents[0].tags, azurerm_public_ip.nat[0].tags, azurerm_nat_gateway.agents[0].tags,
      azurerm_container_registry.agents[0].tags, azurerm_container_registry_task.agent_image[0].tags, azurerm_container_group.agents["01"].tags,
      azurerm_private_dns_zone.endpoints["storage"].tags, azurerm_private_dns_zone.endpoints["registry"].tags, azurerm_private_endpoint.endpoints["storage"].tags,
      azurerm_private_endpoint.endpoints["registry"].tags,
    ] : t == output.tags])
    error_message = "Every Azure resource the bootstrap creates that takes tags must carry exactly the full tag set."
  }
  assert {
    condition     = length(output.tags) <= 15
    error_message = "Azure Private DNS zones take at most 15 tags."
  }
}

run "repository_tag_can_be_overridden_in_any_case" {
  command = plan

  variables {
    tags = {
      organizationName = "Contoso"
      environment      = "lab"
      managedBy        = "Terraform"
      appContact       = "team@contoso.com"
      Repository       = "dev.azure.com/contoso/other/elsewhere"
    }
  }

  assert {
    condition     = output.tags["Repository"] == "dev.azure.com/contoso/other/elsewhere" && !contains(keys(output.tags), "repository")
    error_message = "A repository tag given by the project, in any case, replaces the automatic one."
  }
}

run "fifteen_tags_with_the_automatic_one_is_refused" {
  command = plan

  variables {
    tags = {
      organizationName = "Contoso", environment = "lab", managedBy = "Terraform", appContact = "team@contoso.com",
      t05              = "x", t06 = "x", t07 = "x", t08 = "x", t09 = "x", t10 = "x", t11 = "x", t12 = "x", t13 = "x", t14 = "x", t15 = "x",
    }
  }

  expect_failures = [terraform_data.naming]
}

run "fifteen_tags_including_repository_is_accepted" {
  command = plan

  variables {
    tags = {
      organizationName = "Contoso", environment = "lab", managedBy = "Terraform", appContact = "team@contoso.com", repository = "dev.azure.com/c/p/r",
      t06              = "x", t07 = "x", t08 = "x", t09 = "x", t10 = "x", t11 = "x", t12 = "x", t13 = "x", t14 = "x", t15 = "x",
    }
  }

  assert {
    condition     = length(output.tags) == 15
    error_message = "15 tags is the limit and is allowed."
  }
}

run "sixteen_tags_are_refused_by_the_variable" {
  command = plan

  variables {
    tags = {
      organizationName = "Contoso", environment = "lab", managedBy = "Terraform", appContact = "team@contoso.com", repository = "x",
      t06              = "x", t07 = "x", t08 = "x", t09 = "x", t10 = "x", t11 = "x", t12 = "x", t13 = "x", t14 = "x", t15 = "x", t16 = "x",
    }
  }

  expect_failures = [var.tags]
}

run "missing_required_tag_is_refused" {
  command = plan

  variables {
    tags = { organizationName = "Contoso", environment = "lab", managedBy = "Terraform" }
  }

  expect_failures = [terraform_data.naming]
}

run "empty_required_tag_is_refused" {
  command = plan

  variables {
    tags = { organizationName = "", environment = "lab", managedBy = "Terraform", appContact = "team@contoso.com" }
  }

  expect_failures = [terraform_data.naming]
}

run "required_tags_are_the_projects_to_define" {
  command = plan

  variables {
    required_tag_names = ["environment", "costCentre"]
    tags               = { environment = "lab", costCentre = "1234" }
  }

  assert {
    condition     = output.tags["costCentre"] == "1234"
    error_message = "A project can require its own set of tags."
  }
}

run "bad_tag_name_is_refused" {
  command = plan

  variables {
    tags = { organizationName = "Contoso", environment = "lab", managedBy = "Terraform", appContact = "team@contoso.com", "cost centre" = "1" }
  }

  expect_failures = [var.tags]
}

run "no_public_ip_without_a_way_out_is_refused" {
  command = plan

  variables {
    use_nat_gateway = false
  }

  expect_failures = [terraform_data.naming]
}

run "policy_exemption_for_the_nat_public_ip" {
  command = plan

  variables {
    public_ip_deny_policy_assignment_id = "/providers/Microsoft.Management/managementGroups/identity/providers/Microsoft.Authorization/policyAssignments/Deny-Public-IP"
    policy_exemption_expires_on         = "2027-05-24T00:00:00Z"
  }

  assert {
    condition     = length(azurerm_resource_group_policy_exemption.public_ip) == 1 && azurerm_resource_group_policy_exemption.public_ip[0].exemption_category == "Waiver" && azurerm_resource_group_policy_exemption.public_ip[0].expires_on == "2027-05-24T00:00:00Z"
    error_message = "A waiver with an end date is created on the network resource group."
  }
  assert {
    condition     = azurerm_resource_group_policy_exemption.public_ip[0].name == "exempt-payments-lab-cac-001-nat-ip" && endswith(azurerm_resource_group_policy_exemption.public_ip[0].policy_assignment_id, "/policyAssignments/Deny-Public-IP")
    error_message = "The exemption waives exactly the named assignment."
  }
}

run "no_exemption_by_default" {
  command = plan

  assert {
    condition     = length(azurerm_resource_group_policy_exemption.public_ip) == 0
    error_message = "No exemption unless the assignment is named."
  }
}

run "exemption_without_an_end_date_is_refused" {
  command = plan

  variables {
    public_ip_deny_policy_assignment_id = "/providers/Microsoft.Management/managementGroups/identity/providers/Microsoft.Authorization/policyAssignments/Deny-Public-IP"
  }

  expect_failures = [terraform_data.naming]
}

run "exemption_assignment_must_be_an_assignment_id" {
  command = plan

  variables {
    public_ip_deny_policy_assignment_id = "Deny-Public-IP"
    policy_exemption_expires_on         = "2027-05-24T00:00:00Z"
  }

  expect_failures = [var.public_ip_deny_policy_assignment_id]
}

run "no_nat_gateway_with_a_route_table_has_no_public_ip" {
  command = plan

  variables {
    use_nat_gateway      = false
    agent_route_table_id = "/subscriptions/e1d19c4d-0000-4000-8000-000000000001/resourceGroups/rg-hub/providers/Microsoft.Network/routeTables/rt-egress"
  }

  assert {
    condition     = length(azurerm_public_ip.nat) == 0 && length(azurerm_nat_gateway.agents) == 0 && length(azurerm_nat_gateway_public_ip_association.agents) == 0
    error_message = "Where policy denies public IP addresses there must be no public IP and no NAT gateway."
  }
  assert {
    condition     = azapi_resource.subnet_container_instances[0].body.properties.routeTable.id == "/subscriptions/e1d19c4d-0000-4000-8000-000000000001/resourceGroups/rg-hub/providers/Microsoft.Network/routeTables/rt-egress" && !can(azapi_resource.subnet_container_instances[0].body.properties.natGateway)
    error_message = "The agent subnet takes the route table, and no NAT gateway."
  }
  assert {
    condition     = output.agents.nat_public_ip == null && output.agents.nat_gateway == null
    error_message = "The outputs must say there is no NAT address."
  }
}

run "subnets_are_created_with_their_network_security_group" {
  command = plan

  assert {
    condition     = length(azurerm_network_security_group.agents) == 2
    error_message = "Each subnet has its own network security group."
  }
  assert {
    condition     = contains(keys(azapi_resource.subnet_container_instances[0].body.properties), "networkSecurityGroup") && contains(keys(azapi_resource.subnet_private_endpoints[0].body.properties), "networkSecurityGroup")
    error_message = "A subnet must be written with its network security group in the same request: a policy that denies a subnet without one refuses it otherwise."
  }
  assert {
    condition     = azapi_resource.subnet_container_instances[0].body.properties.defaultOutboundAccess == false && azapi_resource.subnet_private_endpoints[0].body.properties.defaultOutboundAccess == false
    error_message = "Subnets are private: no default outbound access."
  }
  assert {
    condition     = azapi_resource.subnet_container_instances[0].body.properties.delegations[0].properties.serviceName == "Microsoft.ContainerInstance/containerGroups"
    error_message = "The agent subnet is delegated to container instances."
  }
}

run "route_table_id_must_be_a_route_table" {
  command = plan

  variables {
    agent_route_table_id = "/subscriptions/e1d19c4d-0000-4000-8000-000000000001/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet"
  }

  expect_failures = [var.agent_route_table_id]
}

run "branch_policies_off" {
  command = plan

  variables {
    create_branch_policies = false
  }

  assert {
    condition     = azuredevops_branch_policy_build_validation.ci.enabled == false && azuredevops_branch_policy_merge_types.main["main"].enabled == false
    error_message = "create_branch_policies = false must turn the policies off."
  }
  assert {
    condition     = azuredevops_check_branch_control.apply.verify_branch_protection == false && azuredevops_check_branch_control.apply.allowed_branches == "refs/heads/main"
    error_message = "Without branch policies main is unprotected, so protection cannot be verified - but the apply is still main only."
  }
}

run "plan_identity_may_write_state" {
  command = plan

  variables {
    plan_can_write_state = true
  }

  assert {
    condition     = azurerm_role_assignment.state_container["plan"].role_definition_name == "Storage Blob Data Contributor"
    error_message = "plan_can_write_state = true gives the plan identity the write role."
  }
  assert {
    condition     = strcontains(azuredevops_git_repository_file.main[".pipelines/cd.yaml"].content, "plan_takes_state_lock: true")
    error_message = "The pipelines must then plan with the state lock."
  }
}

run "management_group_and_several_subscriptions" {
  command = plan

  variables {
    target_subscription_ids     = ["e1d19c4d-0000-4000-8000-000000000001", "d45813a0-0000-4000-8000-000000000002"]
    target_management_group_ids = ["mg-platform"]
    apply_role_definition_name  = "Owner"
  }

  assert {
    condition     = length(azurerm_role_assignment.target) == 6
    error_message = "Two identities on two subscriptions and one management group make six role assignments."
  }
  assert {
    condition     = azurerm_role_assignment.target["apply-managementgroup-mg-platform"].scope == "/providers/Microsoft.Management/managementGroups/mg-platform" && azurerm_role_assignment.target["apply-managementgroup-mg-platform"].role_definition_name == "Owner"
    error_message = "The management group scope or the configured apply role is wrong."
  }
}

run "existing_project" {
  command = plan

  variables {
    azure_devops_create_project = false
  }

  assert {
    condition     = length(azuredevops_project.main) == 0 && length(data.azuredevops_project.main) == 1
    error_message = "An existing project is read, not created."
  }
}

run "overridden_names" {
  command = plan

  variables {
    names = {
      resource_group_state = "rg-custom-state"
      storage_container    = "custom-state"
      agent_pool           = "custom-pool"
    }
  }

  assert {
    condition     = azurerm_resource_group.state.name == "rg-custom-state" && output.state_backend.container_name == "custom-state" && azuredevops_agent_pool.agents[0].name == "custom-pool"
    error_message = "An overridden name must replace the generated one, and the rest stay generated."
  }
  assert {
    condition     = azurerm_resource_group.identity.name == "rg-payments-lab-cac-001-identity"
    error_message = "A name that is not overridden must keep its pattern."
  }
}

# ---------------------------------------------------------------- refusals

run "storage_name_outside_azure_limit_is_refused" {
  command = plan

  variables {
    names = {
      storage_account = "ThisStorageAccountNameIsFarTooLongAndHasCapitals"
    }
  }

  expect_failures = [terraform_data.naming]
}

run "container_name_with_double_hyphen_is_refused" {
  command = plan

  variables {
    names = {
      storage_container = "tf--state"
    }
  }

  expect_failures = [terraform_data.naming]
}

run "agents_without_a_token_are_refused" {
  command = plan

  variables {
    azure_devops_agent_pat = null
  }

  expect_failures = [terraform_data.naming]
}

run "no_azure_devops_token_is_refused" {
  command = plan

  variables {
    azure_devops_personal_access_token = null
  }

  expect_failures = [terraform_data.naming]
}

run "project_name_with_underscore_is_refused" {
  command = plan

  variables {
    project_name = "payments_platform"
  }

  expect_failures = [var.project_name]
}

run "organization_url_without_organization_is_refused" {
  command = plan

  variables {
    azure_devops_organization_url = "https://dev.azure.com/"
  }

  expect_failures = [var.azure_devops_organization_url]
}
