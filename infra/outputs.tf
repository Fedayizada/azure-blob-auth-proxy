output "function_app_name" {
  description = "Name of the Function App (deploy code to this)."
  value       = azurerm_function_app_flex_consumption.gateway.name
}

output "function_app_hostname" {
  description = "Default hostname of the gateway."
  value       = azurerm_function_app_flex_consumption.gateway.default_hostname
}

output "doc_endpoint" {
  description = "Base URL for document links used in Power BI (append ?path=<blob path>)."
  value       = "https://${azurerm_function_app_flex_consumption.gateway.default_hostname}/api/doc"
}

output "auth_redirect_uri" {
  description = "Redirect URI registered for Easy Auth."
  value       = local.redirect_uri
}

output "app_registration_client_id" {
  description = "Client ID of the Entra app registration used by Easy Auth."
  value       = azuread_application.gateway.client_id
}

output "docs_storage_account" {
  description = "Private storage account holding the legacy documents."
  value       = azurerm_storage_account.docs.name
}

output "docs_container" {
  description = "Container holding the documents."
  value       = azurerm_storage_container.docs.name
}
