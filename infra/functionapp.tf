resource "azurerm_service_plan" "plan" {
  name                = "plan-${local.base_name}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = "FC1" # Flex Consumption: serverless, scale-to-zero, VNet-capable
  tags                = var.tags
}

resource "azurerm_function_app_flex_consumption" "gateway" {
  name                = local.function_app_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  service_plan_id     = azurerm_service_plan.plan.id

  # Deployment package storage, accessed keylessly via the user-assigned identity.
  storage_container_type            = "blobContainer"
  storage_container_endpoint        = "${azurerm_storage_account.runtime.primary_blob_endpoint}deployments"
  storage_authentication_type       = "UserAssignedIdentity"
  storage_user_assigned_identity_id = azurerm_user_assigned_identity.gateway.id

  runtime_name    = "python"
  runtime_version = "3.12"

  https_only = true
  # Provisioned private (corporate network/VPN via the private endpoint).
  # Inbound access is toggled at deploy time by scripts/deploy-code.ps1, so
  # Terraform ignores runtime changes to it (see lifecycle below).
  public_network_access_enabled = false

  instance_memory_in_mb  = 2048
  maximum_instance_count = 40

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.gateway.id]
  }

  virtual_network_subnet_id = one(azurerm_subnet.func[*].id)

  site_config {
    minimum_tls_version                    = "1.2"
    application_insights_connection_string = azurerm_application_insights.ai.connection_string
    vnet_route_all_enabled                 = var.enable_private_networking
  }

  app_settings = {
    DOCS_STORAGE_ACCOUNT = azurerm_storage_account.docs.name
    DOCS_CONTAINER       = var.docs_container_name
    ALLOWED_GROUP_IDS    = var.allowed_group_object_id
    ALLOWED_PREFIXES     = join(",", var.allowed_prefixes)
    MAX_DOWNLOAD_BYTES   = tostring(var.max_download_bytes)

    # Tell DefaultAzureCredential which user-assigned identity to use for the
    # Blob data plane (required when the identity is user-assigned).
    AZURE_CLIENT_ID = azurerm_user_assigned_identity.gateway.client_id

    # Identity-based host storage (no connection string / keys).
    AzureWebJobsStorage__accountName = azurerm_storage_account.runtime.name
    AzureWebJobsStorage__credential  = "managedidentity"
    AzureWebJobsStorage__clientId    = azurerm_user_assigned_identity.gateway.client_id

    # Keyless Easy Auth: point the auth provider's "client secret" at the
    # managed-identity federated-credential assertion instead of a real secret.
    OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID = azurerm_user_assigned_identity.gateway.client_id
  }

  sticky_settings {
    app_setting_names = ["OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID"]
  }

  auth_settings_v2 {
    auth_enabled           = true
    require_authentication = true
    unauthenticated_action = "RedirectToLoginPage"
    default_provider       = "azureactivedirectory"
    require_https          = true

    active_directory_v2 {
      client_id                  = azuread_application.gateway.client_id
      tenant_auth_endpoint       = "https://login.microsoftonline.com/${local.tenant_id}/v2.0"
      client_secret_setting_name = "OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID"
    }

    login {
      token_store_enabled = true
    }
  }

  depends_on = [
    azurerm_storage_container.deployments,
    azurerm_role_assignment.func_runtime_owner,
    azuread_application_federated_identity_credential.gateway,
  ]

  lifecycle {
    # Inbound access is managed out-of-band by the code-deploy script.
    ignore_changes = [public_network_access_enabled]
  }
}
