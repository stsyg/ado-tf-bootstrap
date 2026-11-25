locals {
  tags = var.tags
}

# Nothing is declared yet, so the first pipeline runs plan "No changes" and the apply stage is
# skipped. Add resources here (or in modules/ and call them from here) and put tags = local.tags on
# every one that takes tags: the bootstrap's tags (organization, environment, managedBy, appContact,
# repository ...) are in terraform.tfvars. Azure resources do not inherit tags from the resource group.
# The next pull request shows the plan on the run's summary, and the merge asks the approvers.
#
# resource "azurerm_resource_group" "example" {
#   name     = "rg-${var.project}-example-${var.environment}"
#   location = var.location
#   tags     = local.tags
# }
