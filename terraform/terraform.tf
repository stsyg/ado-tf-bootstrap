terraform {
  required_version = ">= 1.10"

  # Local state: the state storage account this creates may accept no public traffic, so a
  # workstation could not use it as a backend. New-ProjectBootstrap.ps1 gives the file's location
  # at init (-backend-config="path=<output folder>\bootstrap.tfstate"); keep it with the tfvars.
  backend "local" {}

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.81"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.13"
    }
    azuredevops = {
      source  = "microsoft/azuredevops"
      version = "~> 1.16"
    }
  }
}

# Sign-in comes from the environment, never from a file:
#   azurerm, azapi   az login (or ARM_* variables); the subscription is bootstrap_subscription_id.
#   azuredevops      the personal access token in TF_VAR_azure_devops_personal_access_token, which
#                    New-ProjectBootstrap.ps1 sets for the run. The Azure CLI token is not used: it
#                    can expire part-way through an apply and leave half-created objects behind.
provider "azurerm" {
  subscription_id                 = var.bootstrap_subscription_id
  resource_provider_registrations = "none"
  storage_use_azuread             = true
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    # The state account allows no shared-key access and may allow no public traffic, so the provider
    # must not read its queue and static-website settings through the data plane.
    storage {
      data_plane_available = false
    }
  }
}

provider "azapi" {
  subscription_id = var.bootstrap_subscription_id
}

provider "azuredevops" {
  org_service_url       = var.azure_devops_organization_url
  personal_access_token = var.azure_devops_personal_access_token
  use_cli               = false
}
