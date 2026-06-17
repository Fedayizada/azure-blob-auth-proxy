# The gateway identity reads the private documents container.
resource "azurerm_role_assignment" "func_docs_reader" {
  scope                = azurerm_storage_account.docs.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_user_assigned_identity.gateway.principal_id
}

# The gateway identity owns the runtime storage (deployment package + host storage).
resource "azurerm_role_assignment" "func_runtime_owner" {
  scope                = azurerm_storage_account.runtime.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = azurerm_user_assigned_identity.gateway.principal_id
}
