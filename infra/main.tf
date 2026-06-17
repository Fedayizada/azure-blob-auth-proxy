data "azurerm_client_config" "current" {}

data "azuread_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
  numeric = true
}

resource "random_uuid" "app_role" {}

locals {
  base_name          = "${var.name_prefix}-${var.environment}"
  function_app_name  = "${local.base_name}-${random_string.suffix.result}"
  redirect_uri       = "https://${local.function_app_name}.azurewebsites.net/.auth/login/aad/callback"
  tenant_id          = data.azurerm_client_config.current.tenant_id
  graph_app_id       = "00000003-0000-0000-c000-000000000000"
  graph_user_read_id = "e1fe6dd8-ba31-4d61-89e7-88639da4683d"

  # Storage account names: lowercase alphanumeric, <= 24 chars.
  docs_sa_name    = substr(lower(replace("${var.name_prefix}docs${random_string.suffix.result}", "-", "")), 0, 24)
  runtime_sa_name = substr(lower(replace("${var.name_prefix}fn${random_string.suffix.result}", "-", "")), 0, 24)
}

resource "azurerm_resource_group" "rg" {
  name     = "rg-${local.base_name}"
  location = var.location
  tags     = var.tags
}

# Single user-assigned identity used for: keyless Easy Auth (via federated
# credential), reading the docs storage, and the Flex deployment/host storage.
resource "azurerm_user_assigned_identity" "gateway" {
  name                = "id-${local.base_name}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  tags                = var.tags
}
