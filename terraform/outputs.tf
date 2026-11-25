output "tags" {
  description = "The tags every Azure resource carries, including the automatic repository tag."
  value       = local.tags
}

output "state_backend" {
  description = "Where the project's Terraform state lives. The pipelines read the same names from the variable group."
  value = {
    resource_group_name  = azurerm_resource_group.state.name
    storage_account_name = azurerm_storage_account.state.name
    container_name       = azapi_resource.state_container.name
    subscription_id      = var.bootstrap_subscription_id
    public_network       = !local.use_private_networking
  }
}

output "identities" {
  description = "The plan and apply identities, their client IDs, and the roles they hold."
  value = {
    for key, identity in azurerm_user_assigned_identity.pipeline : key => {
      name      = identity.name
      client_id = identity.client_id
      role      = local.identity_roles[key]
    }
  }
}

output "role_assignment_scopes" {
  description = "Azure scopes the plan and apply identities have their roles on."
  value       = sort(values(local.target_scopes))
}

output "azure_devops" {
  description = "The Azure DevOps objects the bootstrap created, for the verification script and the runbook."
  value = {
    organization_url         = local.organization_url
    project_name             = var.azure_devops_project_name
    repository               = azuredevops_git_repository.main.name
    repository_url           = azuredevops_git_repository.main.remote_url
    templates_repository     = azuredevops_git_repository.templates.name
    templates_repository_url = azuredevops_git_repository.templates.remote_url
    pipelines                = { for key, pipeline in azuredevops_build_definition.pipeline : key => pipeline.name }
    environments             = local.environments
    service_connections      = local.service_connections
    variable_group           = azuredevops_variable_group.backend.name
    approvers_group          = azuredevops_group.approvers.display_name
    approvers                = sort(var.approvers)
    approver_entra_groups    = sort(var.approver_entra_group_ids)
    agent_pool               = var.use_self_hosted_agents ? azuredevops_agent_pool.agents[0].name : null
  }
}

output "agents" {
  description = "The self-hosted agent infrastructure; null without self-hosted agents."
  value = var.use_self_hosted_agents ? {
    container_registry     = azurerm_container_registry.agents[0].name
    container_registry_sku = azurerm_container_registry.agents[0].sku
    registry_private       = local.registry_private
    container_instances    = sort([for group in azurerm_container_group.agents : group.name])
    private_networking     = local.use_private_networking
    virtual_network        = local.use_private_networking ? azurerm_virtual_network.agents[0].name : null
    nat_public_ip          = local.use_nat ? azurerm_public_ip.nat[0].ip_address : null
    private_endpoints      = sort([for endpoint in azurerm_private_endpoint.endpoints : endpoint.name])
    private_dns_zones      = sort([for zone in azurerm_private_dns_zone.endpoints : zone.name])
    nat_gateway            = local.use_nat ? azurerm_nat_gateway.agents[0].name : null
    agent_resource_group   = azurerm_resource_group.agents[0].name
  } : null
}

output "resource_groups" {
  description = "The resource groups the bootstrap created; null for one it did not need."
  value = {
    state    = azurerm_resource_group.state.name
    identity = azurerm_resource_group.identity.name
    agents   = var.use_self_hosted_agents ? azurerm_resource_group.agents[0].name : null
    network  = local.use_private_networking ? azurerm_resource_group.network[0].name : null
  }
}
