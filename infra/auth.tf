# --- App Registration that Easy Auth uses to sign users in ---
resource "azuread_application" "gateway" {
  display_name     = "${local.base_name}-auth"
  owners           = [data.azuread_client_config.current.object_id]
  sign_in_audience = "AzureADMyOrg"

  # Emit only the groups assigned to this application (overage-safe).
  group_membership_claims = ["ApplicationGroup"]

  web {
    redirect_uris = [local.redirect_uri]

    implicit_grant {
      id_token_issuance_enabled = true
    }
  }

  app_role {
    allowed_member_types = ["User"]
    description          = "Users allowed to read documents."
    display_name         = "Document.Read"
    enabled              = true
    id                   = random_uuid.app_role.result
    value                = "Document.Read"
  }

  required_resource_access {
    resource_app_id = local.graph_app_id

    resource_access {
      id   = local.graph_user_read_id
      type = "Scope"
    }
  }
}

resource "azuread_service_principal" "gateway" {
  client_id                    = azuread_application.gateway.client_id
  owners                       = [data.azuread_client_config.current.object_id]
  app_role_assignment_required = true # only assigned users/groups can sign in
}

# Assigning the group to the app role both gates sign-in and makes the group
# appear in the ApplicationGroup groups claim the Function validates.
resource "azuread_app_role_assignment" "allowed_group" {
  app_role_id         = random_uuid.app_role.result
  principal_object_id = var.allowed_group_object_id
  resource_object_id  = azuread_service_principal.gateway.object_id
}

# Keyless Easy Auth: the app registration trusts the gateway's user-assigned
# managed identity via a federated identity credential, used as a client
# assertion instead of a client secret. No secret is ever created.
resource "azuread_application_federated_identity_credential" "gateway" {
  application_id = azuread_application.gateway.id
  display_name   = "easy-auth-mi"
  description    = "Managed identity assertion for App Service Authentication."
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://login.microsoftonline.com/${local.tenant_id}/v2.0"
  subject        = azurerm_user_assigned_identity.gateway.principal_id
}
