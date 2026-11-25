# Self-hosted agents: a registry that builds the agent image, container instances that run it, and -
# with private networking - the network they sit in and the private endpoints that let them reach
# the state storage account and the registry. Nothing here exists with use_self_hosted_agents = false.

locals {
  # Private DNS zones of the two endpoints (public cloud; a sovereign cloud has other zone names).
  private_endpoints = local.use_private_networking ? merge(
    {
      storage = {
        name         = local.names.private_endpoint_storage
        resource_id  = azurerm_storage_account.state.id
        zone         = "privatelink.blob.core.windows.net"
        sub_resource = "blob"
      }
    },
    # Only a Premium registry has a private endpoint (see container_registry_sku).
    local.registry_private ? {
      registry = {
        name         = local.names.private_endpoint_registry
        resource_id  = azurerm_container_registry.agents[0].id
        zone         = "privatelink.azurecr.io"
        sub_resource = "registry"
      }
    } : {},
  ) : {}
}

# ---------------------------------------------------------------- network

resource "azurerm_virtual_network" "agents" {
  count               = local.use_private_networking ? 1 : 0
  name                = local.names.virtual_network
  location            = var.azure_location
  resource_group_name = azurerm_resource_group.network[0].name
  address_space       = [var.virtual_network_address_space]
  tags                = local.tags
}

# The agents' outbound traffic - the Azure DevOps service, the Terraform registry, GitHub for the
# image build - leaves through one fixed address that can be allow-listed. Skipped with
# use_nat_gateway = false (an organization whose policy denies public IP addresses cannot have one); the agent subnet then routes through
# agent_route_table_id, for example to the hub firewall.
resource "azurerm_public_ip" "nat" {
  count               = local.use_nat ? 1 : 0
  name                = local.names.public_ip
  location            = var.azure_location
  resource_group_name = azurerm_resource_group.network[0].name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags

  depends_on = [azurerm_resource_group_policy_exemption.public_ip]
}

# Where a policy denies public IP addresses (RequestDisallowedByPolicy on the NAT gateway's IP), a waiver
# of that one assignment on the bootstrap's own network resource group - nowhere else - lets the one
# public IP be created. Off unless public_ip_deny_policy_assignment_id is given. It needs rights to
# write policy exemptions on the group (Owner, or Resource Policy Contributor).
resource "azurerm_resource_group_policy_exemption" "public_ip" {
  count                = local.use_nat && var.public_ip_deny_policy_assignment_id != "" ? 1 : 0
  name                 = local.names.policy_exemption_public_ip
  resource_group_id    = azurerm_resource_group.network[0].id
  policy_assignment_id = var.public_ip_deny_policy_assignment_id
  exemption_category   = "Waiver"
  display_name         = "Bootstrap NAT gateway public IP"
  description          = "The bootstrap's agents need one Standard public IP for their NAT gateway. Narrowed to the bootstrap's network resource group; expires ${var.policy_exemption_expires_on}."
  expires_on           = var.policy_exemption_expires_on
  metadata             = jsonencode({ reason = "project-bootstrap NAT gateway", managedBy = "project-bootstrap" })
}

resource "azurerm_nat_gateway" "agents" {
  count               = local.use_nat ? 1 : 0
  name                = local.names.nat_gateway
  location            = var.azure_location
  resource_group_name = azurerm_resource_group.network[0].name
  sku_name            = "Standard"
  tags                = local.tags
}

resource "azurerm_nat_gateway_public_ip_association" "agents" {
  count                = local.use_nat ? 1 : 0
  nat_gateway_id       = azurerm_nat_gateway.agents[0].id
  public_ip_address_id = azurerm_public_ip.nat[0].id
}

# A subnet must be created WITH its network security group where policy denies a subnet without one:
# azurerm_subnet creates it bare and attaches the group afterwards, which such a policy refuses. The subnets are therefore written through the Resource
# Manager with the group, the NAT gateway and the route table in the same request. The groups carry
# Azure's default rules: no inbound from the internet, outbound allowed.
resource "azurerm_network_security_group" "agents" {
  for_each = local.use_private_networking ? {
    container_instances = local.names.nsg_container_instances
    private_endpoints   = local.names.nsg_private_endpoints
  } : {}
  name                = each.value
  location            = var.azure_location
  resource_group_name = azurerm_resource_group.network[0].name
  tags                = local.tags
}

resource "azapi_resource" "subnet_container_instances" {
  count     = local.use_private_networking ? 1 : 0
  type      = "Microsoft.Network/virtualNetworks/subnets@2024-05-01"
  parent_id = azurerm_virtual_network.agents[0].id
  name      = local.names.subnet_container_instances
  body = {
    properties = merge(
      {
        addressPrefix                  = var.subnet_address_prefix_container_instances
        networkSecurityGroup           = { id = azurerm_network_security_group.agents["container_instances"].id }
        privateEndpointNetworkPolicies = "Enabled"
        defaultOutboundAccess          = false
        delegations = [{
          name = "aci-delegation"
          properties = {
            serviceName = "Microsoft.ContainerInstance/containerGroups"
          }
        }]
      },
      local.use_nat ? { natGateway = { id = azurerm_nat_gateway.agents[0].id } } : {},
      var.agent_route_table_id != "" ? { routeTable = { id = var.agent_route_table_id } } : {},
    )
  }
  schema_validation_enabled = false

  depends_on = [azurerm_nat_gateway_public_ip_association.agents]
}

# One subnet write at a time in a virtual network: parallel writes conflict.
resource "azapi_resource" "subnet_private_endpoints" {
  count     = local.use_private_networking ? 1 : 0
  type      = "Microsoft.Network/virtualNetworks/subnets@2024-05-01"
  parent_id = azurerm_virtual_network.agents[0].id
  name      = local.names.subnet_private_endpoints
  body = {
    properties = {
      addressPrefix                  = var.subnet_address_prefix_private_endpoints
      networkSecurityGroup           = { id = azurerm_network_security_group.agents["private_endpoints"].id }
      privateEndpointNetworkPolicies = "Enabled"
      defaultOutboundAccess          = false
    }
  }
  schema_validation_enabled = false

  depends_on = [azapi_resource.subnet_container_instances]
}
# ---------------------------------------------------------------- private endpoints

resource "azurerm_private_dns_zone" "endpoints" {
  for_each            = local.private_endpoints
  name                = each.value.zone
  resource_group_name = azurerm_resource_group.network[0].name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "endpoints" {
  for_each              = local.private_endpoints
  name                  = each.value.name
  resource_group_name   = azurerm_resource_group.network[0].name
  private_dns_zone_name = azurerm_private_dns_zone.endpoints[each.key].name
  virtual_network_id    = azurerm_virtual_network.agents[0].id
  tags                  = local.tags
}

resource "azurerm_private_endpoint" "endpoints" {
  for_each            = local.private_endpoints
  name                = each.value.name
  location            = var.azure_location
  resource_group_name = azurerm_resource_group.network[0].name
  subnet_id           = azapi_resource.subnet_private_endpoints[0].id
  tags                = local.tags

  private_service_connection {
    name                           = each.value.name
    private_connection_resource_id = each.value.resource_id
    subresource_names              = [each.value.sub_resource]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = each.value.name
    private_dns_zone_ids = [azurerm_private_dns_zone.endpoints[each.key].id]
  }
}

# ---------------------------------------------------------------- container registry and image build

# A private endpoint needs the Premium registry (Learn: Connect privately to an Azure container
# registry by using Azure Private Link; ACR SKU features and limits). Basic and Standard keep a public
# endpoint, with Microsoft Entra sign-in required.
resource "azurerm_container_registry" "agents" {
  count                         = var.use_self_hosted_agents ? 1 : 0
  name                          = local.names.container_registry
  resource_group_name           = azurerm_resource_group.agents[0].name
  location                      = var.azure_location
  sku                           = local.registry_sku
  admin_enabled                 = false
  public_network_access_enabled = !local.registry_private
  zone_redundancy_enabled       = local.registry_sku == "Premium" && var.container_registry_zone_redundancy_enabled
  network_rule_bypass_option    = local.registry_private ? "AzureServices" : "None"
  tags                          = local.tags
}

# Lets the registry's own build task reach a registry that accepts no public traffic.
resource "azapi_update_resource" "registry_tasks_bypass" {
  count       = local.registry_private ? 1 : 0
  type        = "Microsoft.ContainerRegistry/registries@2025-05-01-preview"
  resource_id = azurerm_container_registry.agents[0].id
  body = {
    properties = {
      networkRuleBypassAllowedForTasks = true
    }
  }
}

resource "azurerm_container_registry_task" "agent_image" {
  count                 = var.use_self_hosted_agents ? 1 : 0
  name                  = "image-build-task"
  container_registry_id = azurerm_container_registry.agents[0].id
  tags                  = local.tags

  platform {
    os = "Linux"
  }

  docker_step {
    dockerfile_path      = var.agent_container_image_dockerfile
    context_path         = local.agent_image_dockerfile_url
    context_access_token = "a" # The provider asks for one; a public repository needs none.
    image_names          = ["${local.agent_image_name}:${var.agent_container_image_tag}"]
  }

  # System-assigned on purpose: a registry that accepts no public traffic lets a task in through the
  # AzureServices bypass only as its own system identity.
  identity {
    type = "SystemAssigned"
  }

  registry_credential {
    custom {
      login_server = azurerm_container_registry.agents[0].login_server
      identity     = "[system]"
    }
  }
}

resource "azurerm_role_assignment" "registry_push_for_task" {
  count                = var.use_self_hosted_agents ? 1 : 0
  scope                = azurerm_container_registry.agents[0].id
  role_definition_name = "AcrPush"
  principal_id         = azurerm_container_registry_task.agent_image[0].identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_container_registry_task_schedule_run_now" "agent_image" {
  count                      = var.use_self_hosted_agents ? 1 : 0
  container_registry_task_id = azurerm_container_registry_task.agent_image[0].id

  lifecycle {
    replace_triggered_by = [azurerm_container_registry_task.agent_image]
  }

  depends_on = [
    azurerm_role_assignment.registry_push_for_task,
    azapi_update_resource.registry_tasks_bypass,
  ]
}

# ---------------------------------------------------------------- agent container instances

resource "azurerm_user_assigned_identity" "agent" {
  count               = var.use_self_hosted_agents ? 1 : 0
  name                = local.names.identity_agent
  location            = var.azure_location
  resource_group_name = azurerm_resource_group.agents[0].name
  tags                = local.tags
}

resource "azurerm_role_assignment" "registry_pull_for_agent" {
  count                = var.use_self_hosted_agents ? 1 : 0
  scope                = azurerm_container_registry.agents[0].id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.agent[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_container_group" "agents" {
  for_each            = local.agent_instances
  name                = each.value.container_name
  location            = var.azure_location
  resource_group_name = azurerm_resource_group.agents[0].name
  os_type             = "Linux"
  ip_address_type     = local.use_private_networking ? "Private" : "None"
  subnet_ids          = local.use_private_networking ? [azapi_resource.subnet_container_instances[0].id] : []
  zones               = each.value.zone == null ? null : [each.value.zone]
  tags                = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.agent[0].id]
  }

  image_registry_credential {
    server                    = azurerm_container_registry.agents[0].login_server
    user_assigned_identity_id = azurerm_user_assigned_identity.agent[0].id
  }

  container {
    name   = each.value.container_name
    image  = "${azurerm_container_registry.agents[0].login_server}/${local.agent_image_name}:${var.agent_container_image_tag}"
    cpu    = var.agent_container_cpu
    memory = var.agent_container_memory

    ports {
      port     = 80
      protocol = "TCP"
    }

    environment_variables = {
      AZP_URL        = local.organization_url
      AZP_POOL       = azuredevops_agent_pool.agents[0].name
      AZP_AGENT_NAME = each.value.agent_name
    }

    secure_environment_variables = {
      AZP_TOKEN = var.azure_devops_agent_pat
    }
  }

  depends_on = [
    azurerm_container_registry_task_schedule_run_now.agent_image,
    azurerm_role_assignment.registry_pull_for_agent,
    azurerm_private_endpoint.endpoints,
    azurerm_private_dns_zone_virtual_network_link.endpoints,
    azapi_resource.subnet_container_instances,
  ]
}
