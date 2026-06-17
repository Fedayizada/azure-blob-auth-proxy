# --- Function runtime storage (deployment package + host storage, MI-accessed) ---
resource "azurerm_storage_account" "runtime" {
  name                            = local.runtime_sa_name
  resource_group_name             = azurerm_resource_group.rg.name
  location                        = azurerm_resource_group.rg.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false # keyless: host + deployment use managed identity
  public_network_access_enabled   = true
  tags                            = var.tags

  dynamic "network_rules" {
    for_each = var.enable_private_networking ? [1] : []
    content {
      default_action = "Deny"
      bypass         = ["AzureServices"]
      ip_rules       = var.deployer_ip != "" ? [var.deployer_ip] : []
    }
  }
}

# Deployer needs data-plane access to create the deployment container (Entra auth).
resource "azurerm_role_assignment" "deployer_runtime_blob" {
  scope                = azurerm_storage_account.runtime.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "time_sleep" "runtime_rbac" {
  depends_on      = [azurerm_role_assignment.deployer_runtime_blob]
  create_duration = "60s"
}

# Holds the deployed function package for the Flex Consumption app.
resource "azurerm_storage_container" "deployments" {
  name                  = "deployments"
  storage_account_id    = azurerm_storage_account.runtime.id
  container_access_type = "private"

  depends_on = [time_sleep.runtime_rbac]
}

# --- Documents storage (private, no keys, RBAC + managed identity only) ---
resource "azurerm_storage_account" "docs" {
  name                            = local.docs_sa_name
  resource_group_name             = azurerm_resource_group.rg.name
  location                        = azurerm_resource_group.rg.location
  account_tier                    = "Standard"
  account_replication_type        = "ZRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false # no account keys: Entra/RBAC only
  public_network_access_enabled   = true
  tags                            = var.tags

  dynamic "network_rules" {
    for_each = var.enable_private_networking ? [1] : []
    content {
      default_action = "Deny"
      bypass         = ["AzureServices"]
      ip_rules       = var.deployer_ip != "" ? [var.deployer_ip] : []
    }
  }

  blob_properties {
    delete_retention_policy {
      days = 7
    }
    versioning_enabled = true
  }
}

# Let the deployer (the identity running Terraform) create the container over the
# data plane using Entra auth (the account has shared keys disabled).
resource "azurerm_role_assignment" "deployer_docs_blob" {
  scope                = azurerm_storage_account.docs.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Allow RBAC to propagate before data-plane operations.
resource "time_sleep" "docs_rbac" {
  depends_on      = [azurerm_role_assignment.deployer_docs_blob]
  create_duration = "60s"
}

resource "azurerm_storage_container" "docs" {
  name                  = var.docs_container_name
  storage_account_id    = azurerm_storage_account.docs.id
  container_access_type = "private"

  depends_on = [time_sleep.docs_rbac]
}
