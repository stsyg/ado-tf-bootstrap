# Values the azurerm provider validates as Azure resource IDs or GUIDs, or that other resources read.
# Nothing is created anywhere.

mock_data "azurerm_client_config" {
  defaults = {
    tenant_id       = "0b0b0b0b-0000-4000-8000-000000000001"
    object_id       = "0b0b0b0b-0000-4000-8000-000000000002"
    subscription_id = "e1d19c4d-0000-4000-8000-000000000001"
  }
}

mock_data "azurerm_subscription" {
  defaults = {
    display_name = "Mock Subscription"
  }
}

mock_resource "azurerm_resource_group" {
  defaults = {
    id = "/subscriptions/e1d19c4d-0000-4000-8000-000000000001/resourceGroups/rg-mock"
  }
}

mock_resource "azurerm_user_assigned_identity" {
  defaults = {
    id           = "/subscriptions/e1d19c4d-0000-4000-8000-000000000001/resourceGroups/rg-mock/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-mock"
    principal_id = "0c0c0c0c-0000-4000-8000-000000000001"
    client_id    = "0c0c0c0c-0000-4000-8000-000000000002"
  }
}

mock_resource "azurerm_storage_account" {
  defaults = {
    id = "/subscriptions/e1d19c4d-0000-4000-8000-000000000001/resourceGroups/rg-mock/providers/Microsoft.Storage/storageAccounts/stmock"
  }
}

mock_resource "azurerm_virtual_network" {
  defaults = {
    id = "/subscriptions/e1d19c4d-0000-4000-8000-000000000001/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock"
  }
}

mock_resource "azurerm_subnet" {
  defaults = {
    id = "/subscriptions/e1d19c4d-0000-4000-8000-000000000001/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock/subnets/snet-mock"
  }
}

mock_resource "azurerm_public_ip" {
  defaults = {
    id         = "/subscriptions/e1d19c4d-0000-4000-8000-000000000001/resourceGroups/rg-mock/providers/Microsoft.Network/publicIPAddresses/pip-mock"
    ip_address = "20.0.0.1"
  }
}

mock_resource "azurerm_nat_gateway" {
  defaults = {
    id = "/subscriptions/e1d19c4d-0000-4000-8000-000000000001/resourceGroups/rg-mock/providers/Microsoft.Network/natGateways/ng-mock"
  }
}

mock_resource "azurerm_private_dns_zone" {
  defaults = {
    id = "/subscriptions/e1d19c4d-0000-4000-8000-000000000001/resourceGroups/rg-mock/providers/Microsoft.Network/privateDnsZones/privatelink.mock.net"
  }
}

mock_resource "azurerm_container_registry" {
  defaults = {
    id           = "/subscriptions/e1d19c4d-0000-4000-8000-000000000001/resourceGroups/rg-mock/providers/Microsoft.ContainerRegistry/registries/acrmock"
    login_server = "acrmock.azurecr.io"
  }
}

mock_resource "azurerm_container_registry_task" {
  defaults = {
    id = "/subscriptions/e1d19c4d-0000-4000-8000-000000000001/resourceGroups/rg-mock/providers/Microsoft.ContainerRegistry/registries/acrmock/tasks/image-build-task"
    identity = {
      type         = "SystemAssigned"
      principal_id = "0c0c0c0c-0000-4000-8000-000000000003"
      tenant_id    = "0b0b0b0b-0000-4000-8000-000000000001"
      identity_ids = []
    }
  }
}
