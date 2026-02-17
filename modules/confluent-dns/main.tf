# =============================================================================
# Local Variables
# =============================================================================

locals {
  # Confluent Cloud DNS zone for Azure
  confluent_dns_zone = "azure.confluent.cloud"

  # Build the cluster-specific subdomain
  cluster_subdomain = "${var.confluent_cluster_id}.${var.confluent_region}"

  # Generate broker hostnames (b0, b1, b2, ... bN)
  broker_prefixes = [for i in range(var.broker_count) : "b${i}"]

  # Zonal endpoint subdomain (if enabled)
  zonal_subdomain = var.enable_zonal_endpoints && var.zonal_endpoint_id != "" ? "${var.zonal_endpoint_id}.${var.confluent_region}" : ""

  # Default tags
  default_tags = {
    ManagedBy = "terraform"
    Module    = "confluent-dns"
    Purpose   = "confluent-private-dns"
  }

  tags = merge(local.default_tags, var.tags)
}

# =============================================================================
# Private DNS Zone for confluent.cloud
# =============================================================================

resource "azurerm_private_dns_zone" "confluent" {
  name                = local.confluent_dns_zone
  resource_group_name = var.resource_group_name
  tags                = local.tags
}

# =============================================================================
# VNet Links - Connect DNS Zone to VNets
# =============================================================================

resource "azurerm_private_dns_zone_virtual_network_link" "confluent" {
  count = length(var.vnet_ids_to_link)

  name                  = "link-${var.vnet_names[count.index]}"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.confluent.name
  virtual_network_id    = var.vnet_ids_to_link[count.index]
  registration_enabled  = false
  tags                  = local.tags
}

# =============================================================================
# Bootstrap Server DNS Record
# pkc-xxxxx.eastus.azure.confluent.cloud -> target IP
# =============================================================================

resource "azurerm_private_dns_a_record" "bootstrap" {
  name                = local.cluster_subdomain
  zone_name           = azurerm_private_dns_zone.confluent.name
  resource_group_name = var.resource_group_name
  ttl                 = var.ttl
  records             = [var.target_ip]
  tags                = local.tags
}

# =============================================================================
# Broker DNS Records
# b0-pkc-xxxxx.eastus.azure.confluent.cloud -> target IP
# b1-pkc-xxxxx.eastus.azure.confluent.cloud -> target IP
# ... etc
# =============================================================================

resource "azurerm_private_dns_a_record" "brokers" {
  for_each = toset(local.broker_prefixes)

  name                = "${each.value}-${local.cluster_subdomain}"
  zone_name           = azurerm_private_dns_zone.confluent.name
  resource_group_name = var.resource_group_name
  ttl                 = var.ttl
  records             = [var.target_ip]
  tags                = local.tags
}

# =============================================================================
# Wildcard DNS Record (catch-all for any broker prefix)
# *.pkc-xxxxx.eastus.azure.confluent.cloud -> target IP
# =============================================================================

resource "azurerm_private_dns_a_record" "wildcard" {
  name                = "*.${local.cluster_subdomain}"
  zone_name           = azurerm_private_dns_zone.confluent.name
  resource_group_name = var.resource_group_name
  ttl                 = var.ttl
  records             = [var.target_ip]
  tags                = local.tags
}

# =============================================================================
# Zonal Endpoint DNS Records (optional - for dedicated endpoints)
# lkc-xxxxx.eastus.azure.confluent.cloud -> target IP
# =============================================================================

resource "azurerm_private_dns_a_record" "zonal_bootstrap" {
  count = var.enable_zonal_endpoints && var.zonal_endpoint_id != "" ? 1 : 0

  name                = local.zonal_subdomain
  zone_name           = azurerm_private_dns_zone.confluent.name
  resource_group_name = var.resource_group_name
  ttl                 = var.ttl
  records             = [var.target_ip]
  tags                = local.tags
}

resource "azurerm_private_dns_a_record" "zonal_wildcard" {
  count = var.enable_zonal_endpoints && var.zonal_endpoint_id != "" ? 1 : 0

  name                = "*.${local.zonal_subdomain}"
  zone_name           = azurerm_private_dns_zone.confluent.name
  resource_group_name = var.resource_group_name
  ttl                 = var.ttl
  records             = [var.target_ip]
  tags                = local.tags
}
