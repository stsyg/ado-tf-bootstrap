# The container is the only azapi_resource; its ID is what the role assignments are scoped to.

mock_resource "azapi_resource" {
  defaults = {
    id = "/subscriptions/e1d19c4d-0000-4000-8000-000000000001/resourceGroups/rg-mock/providers/Microsoft.Storage/storageAccounts/stmock/blobServices/default/containers/tfstate"
  }
}
