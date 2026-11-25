data "azurerm_client_config" "current" {}

data "azurerm_subscription" "bootstrap" {
  subscription_id = var.bootstrap_subscription_id
}

# ---------------------------------------------------------------- resource providers

resource "azapi_resource_action" "resource_provider_registration" {
  for_each    = toset(var.resource_providers)
  type        = "Microsoft.Resources/subscriptions@2021-04-01"
  resource_id = "/subscriptions/${var.bootstrap_subscription_id}"
  action      = "providers/${each.key}/register"
  method      = "POST"
}

# ---------------------------------------------------------------- resource groups

resource "azurerm_resource_group" "state" {
  name     = local.names.resource_group_state
  location = var.azure_location
  tags     = local.tags

  depends_on = [terraform_data.naming, azapi_resource_action.resource_provider_registration]
}

resource "azurerm_resource_group" "identity" {
  name     = local.names.resource_group_identity
  location = var.azure_location
  tags     = local.tags

  depends_on = [terraform_data.naming, azapi_resource_action.resource_provider_registration]
}

resource "azurerm_resource_group" "agents" {
  count    = var.use_self_hosted_agents ? 1 : 0
  name     = local.names.resource_group_agents
  location = var.azure_location
  tags     = local.tags

  depends_on = [terraform_data.naming, azapi_resource_action.resource_provider_registration]
}

resource "azurerm_resource_group" "network" {
  count    = local.use_private_networking ? 1 : 0
  name     = local.names.resource_group_network
  location = var.azure_location
  tags     = local.tags

  depends_on = [terraform_data.naming, azapi_resource_action.resource_provider_registration]
}

# ---------------------------------------------------------------- Terraform state

# Shared-key access is off: the pipelines reach the state with the identities' tokens
# (use_azuread_auth in the backend), so there is no account key to leak.
resource "azurerm_storage_account" "state" {
  name                            = local.names.storage_account
  resource_group_name             = azurerm_resource_group.state.name
  location                        = var.azure_location
  account_tier                    = "Standard"
  account_replication_type        = var.storage_account_replication_type
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false
  public_network_access_enabled   = !local.use_private_networking
  tags                            = local.tags

  blob_properties {
    versioning_enabled = var.storage_account_blob_versioning_enabled

    dynamic "delete_retention_policy" {
      for_each = var.storage_account_blob_soft_delete_retention_days > 0 ? [1] : []
      content {
        days = var.storage_account_blob_soft_delete_retention_days
      }
    }

    dynamic "container_delete_retention_policy" {
      for_each = var.storage_account_container_soft_delete_retention_days > 0 ? [1] : []
      content {
        days = var.storage_account_container_soft_delete_retention_days
      }
    }
  }

  lifecycle {
    ignore_changes = [queue_properties, static_website]
  }
}

# The container is made through the Azure Resource Manager, not the storage data plane, so it can
# be created from a workstation even when the account accepts no public traffic.
resource "azapi_resource" "state_container" {
  type      = "Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01"
  parent_id = "${azurerm_storage_account.state.id}/blobServices/default"
  name      = local.names.storage_container
  body = {
    properties = {
      publicAccess = "None"
    }
  }
  schema_validation_enabled = false
}

# The apply identity writes the state. The plan identity only reads it unless plan_can_write_state
# says a plan takes the state's lock: a pull request's Terraform runs as the plan identity, so
# write access there would let that code overwrite or delete the state.
resource "azurerm_role_assignment" "state_container" {
  for_each             = azurerm_user_assigned_identity.pipeline
  scope                = azapi_resource.state_container.id
  role_definition_name = each.key == local.plan_key && !var.plan_can_write_state ? "Storage Blob Data Reader" : "Storage Blob Data Contributor"
  principal_id         = each.value.principal_id
  principal_type       = "ServicePrincipal"
}

# ---------------------------------------------------------------- identities

resource "azurerm_user_assigned_identity" "pipeline" {
  for_each            = { (local.plan_key) = local.names.identity_plan, (local.apply_key) = local.names.identity_apply }
  name                = each.value
  location            = var.azure_location
  resource_group_name = azurerm_resource_group.identity.name
  tags                = local.tags
}

# Trust between each Azure DevOps service connection and its identity: no client secret exists.
resource "azurerm_federated_identity_credential" "pipeline" {
  for_each                  = { (local.plan_key) = local.names.federated_credential_plan, (local.apply_key) = local.names.federated_credential_apply }
  name                      = each.value
  audience                  = [local.audience]
  issuer                    = azuredevops_serviceendpoint_azurerm.pipeline[each.key].workload_identity_federation_issuer
  user_assigned_identity_id = azurerm_user_assigned_identity.pipeline[each.key].id
  subject                   = azuredevops_serviceendpoint_azurerm.pipeline[each.key].workload_identity_federation_subject
}

# What the identities may do in the project's own Azure scopes.
resource "azurerm_role_assignment" "target" {
  for_each             = local.role_assignments
  scope                = each.value.scope
  role_definition_name = each.value.role
  principal_id         = azurerm_user_assigned_identity.pipeline[each.value.identity_key].principal_id
  principal_type       = "ServicePrincipal"
}
