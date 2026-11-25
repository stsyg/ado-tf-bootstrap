# Values the azuredevops provider validates (UUIDs, numeric IDs) or the tests read.

mock_data "azuredevops_project" {
  defaults = {
    id = "0a0a0a0a-0000-4000-8000-000000000001"
  }
}

mock_data "azuredevops_users" {
  defaults = {
    users = [{
      descriptor     = "aad.bW9jaw"
      display_name   = "Mock User"
      id             = "0a0a0a0a-0000-4000-8000-000000000004"
      mail_address   = "user@example.com"
      origin         = "aad"
      origin_id      = "0a0a0a0a-0000-4000-8000-000000000005"
      principal_name = "user@example.com"
    }]
  }
}

mock_resource "azuredevops_project" {
  defaults = {
    id = "0a0a0a0a-0000-4000-8000-000000000001"
  }
}

mock_resource "azuredevops_git_repository" {
  defaults = {
    id         = "0a0a0a0a-0000-4000-8000-000000000010"
    remote_url = "https://dev.azure.com/mock/mock/_git/mock"
  }
}

mock_resource "azuredevops_serviceendpoint_azurerm" {
  defaults = {
    id                                   = "0a0a0a0a-0000-4000-8000-000000000011"
    workload_identity_federation_issuer  = "https://login.microsoftonline.com/0b0b0b0b-0000-4000-8000-000000000001/v2.0"
    workload_identity_federation_subject = "/eid1/c/pub/t/mock/a/mock/sc/0a0a0a0a-0000-4000-8000-000000000011"
  }
}

mock_resource "azuredevops_group" {
  defaults = {
    descriptor = "vssgp.Y3JlYXRlZA"
    origin_id  = "0a0a0a0a-0000-4000-8000-000000000012"
  }
}

mock_resource "azuredevops_environment" {
  defaults = {
    id = "5"
  }
}

mock_resource "azuredevops_variable_group" {
  defaults = {
    id = "9"
  }
}

mock_resource "azuredevops_build_definition" {
  defaults = {
    id = "101"
  }
}

mock_resource "azuredevops_agent_pool" {
  defaults = {
    id = "3"
  }
}

mock_resource "azuredevops_agent_queue" {
  defaults = {
    id = "7"
  }
}
