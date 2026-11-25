terraform {
  required_version = ">= 1.10"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.81"
    }
  }

  # The state lives in the storage account the bootstrap created. Which account, container and
  # resource group is not written here: the pipelines pass them to `terraform init` from the
  # variable group, and the token of the pipeline's identity (not an account key) opens the blob.
  backend "azurerm" {
    use_azuread_auth = true
  }
}
