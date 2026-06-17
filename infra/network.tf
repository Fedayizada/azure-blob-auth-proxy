# Private networking: VNet, private endpoints, and private DNS so the storage
# accounts and the Function App are reachable only from the virtual network
# (and corporate clients that resolve the private DNS zones).

resource "azurerm_virtual_network" "vnet" {
  count               = var.enable_private_networking ? 1 : 0
  name                = "vnet-${local.base_name}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  address_space       = ["10.40.0.0/24"]
  tags                = var.tags
}

# Delegated subnet for Function App VNet integration (outbound to private storage).
resource "azurerm_subnet" "func" {
  count                = var.enable_private_networking ? 1 : 0
  name                 = "snet-func"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet[0].name
  address_prefixes     = ["10.40.0.0/26"]

  delegation {
    name = "flex-delegation"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# Subnet hosting the private endpoints.
resource "azurerm_subnet" "pe" {
  count                = var.enable_private_networking ? 1 : 0
  name                 = "snet-pe"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet[0].name
  address_prefixes     = ["10.40.0.64/26"]
}

locals {
  dns_zones = var.enable_private_networking ? {
    blob  = "privatelink.blob.core.windows.net"
    queue = "privatelink.queue.core.windows.net"
    table = "privatelink.table.core.windows.net"
    sites = "privatelink.azurewebsites.net"
  } : {}
}

resource "azurerm_private_dns_zone" "zone" {
  for_each            = local.dns_zones
  name                = each.value
  resource_group_name = azurerm_resource_group.rg.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "link" {
  for_each              = local.dns_zones
  name                  = "link-${each.key}"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.zone[each.key].name
  virtual_network_id    = azurerm_virtual_network.vnet[0].id
  registration_enabled  = false
  tags                  = var.tags
}

# --- Private endpoint: docs storage (blob) ---
resource "azurerm_private_endpoint" "docs_blob" {
  count               = var.enable_private_networking ? 1 : 0
  name                = "pe-${local.docs_sa_name}-blob"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  subnet_id           = azurerm_subnet.pe[0].id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-docs-blob"
    private_connection_resource_id = azurerm_storage_account.docs.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "blob"
    private_dns_zone_ids = [azurerm_private_dns_zone.zone["blob"].id]
  }
}

# --- Private endpoints: runtime storage (blob, queue, table for the host) ---
resource "azurerm_private_endpoint" "runtime" {
  for_each            = var.enable_private_networking ? toset(["blob", "queue", "table"]) : toset([])
  name                = "pe-${local.runtime_sa_name}-${each.key}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  subnet_id           = azurerm_subnet.pe[0].id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-runtime-${each.key}"
    private_connection_resource_id = azurerm_storage_account.runtime.id
    subresource_names              = [each.key]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = each.key
    private_dns_zone_ids = [azurerm_private_dns_zone.zone[each.key].id]
  }
}

# --- Private endpoint: Function App (inbound) ---
resource "azurerm_private_endpoint" "func" {
  count               = var.enable_private_networking ? 1 : 0
  name                = "pe-${local.function_app_name}-sites"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  subnet_id           = azurerm_subnet.pe[0].id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-func-sites"
    private_connection_resource_id = azurerm_function_app_flex_consumption.gateway.id
    subresource_names              = ["sites"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "sites"
    private_dns_zone_ids = [azurerm_private_dns_zone.zone["sites"].id]
  }
}
