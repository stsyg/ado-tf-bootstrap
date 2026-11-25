locals {
  project_compact = replace(var.project_name, "-", "")
  suffix          = "${var.project_name}-${var.environment_name}-${var.location_short}-${var.instance_number}"

  # Storage account and registry names are global. Six hex characters of a hash of the subscription
  # and the project keep two projects of different subscriptions apart, and are the same on every
  # plan, so a re-run finds what the first run made.
  unique_suffix = substr(sha1("${var.bootstrap_subscription_id}/${local.suffix}"), 0, 6)

  default_names = {
    resource_group_state       = "rg-${local.suffix}-state"
    resource_group_identity    = "rg-${local.suffix}-identity"
    resource_group_agents      = "rg-${local.suffix}-agents"
    resource_group_network     = "rg-${local.suffix}-network"
    storage_account            = "st${local.project_compact}${var.environment_name}${local.unique_suffix}"
    storage_container          = "tfstate"
    identity_plan              = "id-${local.suffix}-plan"
    identity_apply             = "id-${local.suffix}-apply"
    identity_agent             = "id-${local.suffix}-agent"
    federated_credential_plan  = "fic-${local.suffix}-plan"
    federated_credential_apply = "fic-${local.suffix}-apply"
    container_registry         = "acr${local.project_compact}${var.environment_name}${local.unique_suffix}"
    container_instance_prefix  = "aci-${local.suffix}"
    virtual_network            = "vnet-${local.suffix}"
    subnet_container_instances = "snet-${local.suffix}-aci"
    subnet_private_endpoints   = "snet-${local.suffix}-pe"
    nsg_container_instances    = "nsg-${local.suffix}-aci"
    nsg_private_endpoints      = "nsg-${local.suffix}-pe"
    nat_gateway                = "ng-${local.suffix}"
    public_ip                  = "pip-${local.suffix}-nat"
    policy_exemption_public_ip = "exempt-${local.suffix}-nat-ip"
    private_endpoint_storage   = "pe-${local.suffix}-st"
    private_endpoint_registry  = "pe-${local.suffix}-acr"
    environment_plan           = "${var.project_name}-${var.environment_name}-plan"
    environment_apply          = "${var.project_name}-${var.environment_name}-apply"
    service_connection_plan    = "sc-${var.project_name}-${var.environment_name}-plan"
    service_connection_apply   = "sc-${var.project_name}-${var.environment_name}-apply"
    variable_group             = "${var.project_name}-${var.environment_name}"
    agent_pool                 = "${var.project_name}-${var.environment_name}"
    approvers_group            = "${var.project_name}-${var.environment_name}-approvers"
  }

  names = merge(local.default_names, { for key, value in var.names : key => value if value != null })

  templates_repository_name = var.templates_repository_name == "" ? "${var.repository_name}-templates" : var.templates_repository_name

  # Private networking means something only when there are agents inside the network.
  use_private_networking = var.use_self_hosted_agents && var.use_private_networking
  use_nat                = local.use_private_networking && var.use_nat_gateway

  # Empty SKU: Premium with private networking, Basic without. Only Premium takes a private endpoint.
  registry_sku     = var.container_registry_sku != "" ? var.container_registry_sku : (local.use_private_networking ? "Premium" : "Basic")
  registry_private = local.use_private_networking && local.registry_sku == "Premium"

  plan_key  = "plan"
  apply_key = "apply"

  default_branch = "refs/heads/main"
  audience       = "api://AzureADTokenExchange"

  target_subscription_ids = length(var.target_subscription_ids) == 0 ? [var.bootstrap_subscription_id] : distinct(var.target_subscription_ids)

  # One entry per identity and scope: the plan identity with its role, the apply identity with its.
  identity_roles = {
    (local.plan_key)  = var.plan_role_definition_name
    (local.apply_key) = var.apply_role_definition_name
  }

  target_scopes = merge(
    { for id in local.target_subscription_ids : "subscription-${id}" => "/subscriptions/${id}" },
    { for id in distinct(var.target_management_group_ids) : "managementgroup-${id}" => "/providers/Microsoft.Management/managementGroups/${id}" },
  )

  role_assignments = {
    for pair in flatten([
      for scope_key, scope in local.target_scopes : [
        for identity_key, role in local.identity_roles : {
          key          = "${identity_key}-${scope_key}"
          identity_key = identity_key
          role         = role
          scope        = scope
        }
      ]
    ]) : pair.key => pair
  }

  agent_instances = var.use_self_hosted_agents ? {
    for index in range(var.agent_container_instance_count) : format("%02d", index + 1) => {
      container_name = "${local.names.container_instance_prefix}-${format("%02d", index + 1)}"
      agent_name     = "${local.names.container_instance_prefix}-${format("%02d", index + 1)}"
      zone           = index < length(var.agent_container_zones) ? var.agent_container_zones[index] : null
    }
  } : {}

  agent_image_dockerfile_url = "${var.agent_container_image_repository}#${var.agent_container_image_tag}:${var.agent_container_image_folder}"
  agent_image_name           = "azure-devops-agent"

  # What the pipelines in the repositories are called, and the files they run.
  ci_pipeline_name = "01 ${var.pipeline_display_name} Continuous Integration"
  cd_pipeline_name = "02 ${var.pipeline_display_name} Continuous Delivery"
  pipelines_folder = ".pipelines"
  ci_template_path = "${local.pipelines_folder}/ci-template.yaml"
  cd_template_path = "${local.pipelines_folder}/cd-template.yaml"
  ci_pipeline_file = "${local.pipelines_folder}/ci.yaml"
  cd_pipeline_file = "${local.pipelines_folder}/cd.yaml"
  organization_url = trimsuffix(var.azure_devops_organization_url, "/")

  # Where the project is bootstrapped - the main repository's address without the scheme, the way a
  # person writes it down: dev.azure.com/<organization>/<project>/<repository>. A space is %20.
  repository_tag_value = "${trimprefix(trimprefix(local.organization_url, "https://"), "http://")}/${replace(var.azure_devops_project_name, " ", "%20")}/${var.repository_name}"

  # Given tags win, so a project can point 'repository' somewhere else. Names are case-insensitive to Azure.
  tags = merge(
    contains([for name in keys(var.tags) : lower(name)], "repository") ? {} : { repository = local.repository_tag_value },
    var.tags,
  )
}

# Values the content folders are rendered with. Anything not here is copied as it is.
locals {
  content_variables = {
    project_name          = var.project_name
    environment_name      = var.environment_name
    pipeline_display_name = var.pipeline_display_name
    project_reference     = var.azure_devops_project_name
    repository_name       = var.repository_name
    templates_repository  = local.templates_repository_name
    terraform_cli_version = var.terraform_cli_version
    agent_pool_name       = var.use_self_hosted_agents ? local.names.agent_pool : ""
    plan_state_lock       = var.plan_can_write_state
    variable_group_name   = local.names.variable_group
    plan_environment      = local.names.environment_plan
    apply_environment     = local.names.environment_apply
    plan_connection       = local.names.service_connection_plan
    apply_connection      = local.names.service_connection_apply
    tenant_id             = data.azurerm_client_config.current.tenant_id
    subscription_id       = var.bootstrap_subscription_id
    azure_location        = var.azure_location
    approvers_group       = local.names.approvers_group
    approver_groups       = var.approver_entra_group_ids
    tags                  = local.tags
    approvers             = var.approvers
    organization_url      = local.organization_url
  }

  main_repository_root      = "${path.module}/../content/main-repo"
  templates_repository_root = "${path.module}/../content/templates-repo"

  main_repository_files = {
    for path in fileset(local.main_repository_root, "**") :
    trimsuffix(path, ".tftpl") => replace(endswith(path, ".tftpl") ? templatefile("${local.main_repository_root}/${path}", local.content_variables) : file("${local.main_repository_root}/${path}"), "\r\n", "\n")
  }

  templates_repository_files = {
    for path in fileset(local.templates_repository_root, "**") :
    trimsuffix(path, ".tftpl") => replace(endswith(path, ".tftpl") ? templatefile("${local.templates_repository_root}/${path}", local.content_variables) : file("${local.templates_repository_root}/${path}"), "\r\n", "\n")
  }
}
