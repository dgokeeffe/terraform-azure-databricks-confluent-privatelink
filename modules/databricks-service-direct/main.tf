# =============================================================================
# databricks-service-direct
#
# Inbound ("service-direct") Private Link to Databricks performance-intensive
# services (Zerobus Ingest, Lakebase Autoscaling) on Azure.
#
# Two halves:
#   1. Azure side  — private endpoint to the Databricks per-region PLS, plus
#                    the privatelink.azuredatabricks.net DNS zone + A record.
#   2. Account side — databricks_endpoint registers the PE so it transitions
#                     from PENDING to APPROVED.
#
# See ../../docs/service-direct-privatelink.md for the rationale and the
# idiosyncrasies this module encodes.
#
# STATUS: this feature and the databricks_endpoint resource are both Public
# Preview. Confirm against a real `terraform plan/apply` before production use.
# =============================================================================

locals {
  pe_name       = "${var.name_prefix}${var.private_endpoint_name}"
  dns_zone_rg   = coalesce(var.private_dns_zone_resource_group_name, var.resource_group_name)
  a_record_name = "${var.region}.service-direct"

  default_tags = {
    ManagedBy = "terraform"
    Module    = "databricks-service-direct"
    Purpose   = "service-direct-inbound-privatelink"
  }
  tags = merge(local.default_tags, var.tags)

  # azurerm does not export the PE's resourceGuid (properties.resourceGuid),
  # which databricks_endpoint requires; read it from raw ARM via azapi.
  pe_resource_guid = data.azapi_resource.pe.output.properties.resourceGuid

  # MS Learn records the PE private IP from properties.customDnsConfigs[0].
  # ipAddresses[0]; it is allocated at PE creation (before account-side
  # approval), so it is safe to use for the DNS A record.
  pe_private_ip = data.azapi_resource.pe.output.properties.customDnsConfigs[0].ipAddresses[0]
}

# =============================================================================
# 1. Azure private endpoint -> Databricks performance-intensive services PLS
#
# Per MS Learn: connect by the PLS *resource ID* with target sub-resource
# `service_direct`. The connection is manual — it stays PENDING until the
# account-side databricks_endpoint registration approves it.
#
# NOTE (Preview): if a future provider/platform change treats the target as a
# pure Private Link Service, azurerm may reject subresource_names — in that case
# switch to `private_connection_resource_alias` and drop subresource_names.
# =============================================================================

resource "azurerm_private_endpoint" "this" {
  name                = local.pe_name
  location            = var.region
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id
  tags                = local.tags

  private_service_connection {
    name                           = var.private_service_connection_name
    private_connection_resource_id = var.databricks_pls_resource_id
    subresource_names              = [var.subresource_name]
    is_manual_connection           = true
    request_message                = var.request_message
  }

  lifecycle {
    # Manual PLS connections churn this field on refresh; ignore to keep plans clean.
    ignore_changes = [private_service_connection[0].private_connection_resource_id]
  }
}

# Read resourceGuid + private IP from raw ARM (azurerm exports neither cleanly).
data "azapi_resource" "pe" {
  type                   = "Microsoft.Network/privateEndpoints@2024-05-01"
  resource_id            = azurerm_private_endpoint.this.id
  response_export_values = ["properties.resourceGuid", "properties.customDnsConfigs"]
}

# Let the PE settle before the account-side registration reads it.
resource "time_sleep" "wait_for_pe" {
  depends_on      = [azurerm_private_endpoint.this]
  create_duration = "30s"
}

# =============================================================================
# 2. Private DNS — privatelink.azuredatabricks.net + <region>.service-direct A record
#
# service-direct shares the workspace front-end Private Link zone. Reuse the
# existing zone (create_private_dns_zone = false) when the workspace already
# uses inbound Private Link.
# =============================================================================

resource "azurerm_private_dns_zone" "this" {
  count               = var.create_private_dns_zone ? 1 : 0
  name                = var.private_dns_zone_name
  resource_group_name = local.dns_zone_rg
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  count = var.create_private_dns_zone ? length(var.vnet_ids_to_link) : 0

  name                  = length(var.vnet_link_names) > count.index ? var.vnet_link_names[count.index] : "link-${count.index}"
  resource_group_name   = local.dns_zone_rg
  private_dns_zone_name = azurerm_private_dns_zone.this[0].name
  virtual_network_id    = var.vnet_ids_to_link[count.index]
  registration_enabled  = false
  tags                  = local.tags
}

resource "azurerm_private_dns_a_record" "service_direct" {
  name                = local.a_record_name
  zone_name           = var.private_dns_zone_name
  resource_group_name = local.dns_zone_rg
  ttl                 = var.dns_a_record_ttl
  records             = [local.pe_private_ip]
  tags                = local.tags

  # Ensure the zone exists first when this module creates it.
  depends_on = [azurerm_private_dns_zone.this]
}

# =============================================================================
# 3. Account-side registration — PENDING -> APPROVED
#
# Requires an ACCOUNT-level databricks provider. use_case resolves to
# SERVICE_DIRECT; state must reach APPROVED before the endpoint is usable.
# =============================================================================

resource "databricks_endpoint" "this" {
  count = var.register_with_databricks ? 1 : 0

  parent       = "accounts/${var.databricks_account_id}"
  display_name = var.endpoint_display_name
  region       = var.region

  # databricks_endpoint is a plugin-framework resource: nested objects are
  # attributes assigned with `=`, not HCL blocks.
  azure_private_endpoint_info = {
    private_endpoint_name          = azurerm_private_endpoint.this.name
    private_endpoint_resource_guid = local.pe_resource_guid
  }

  depends_on = [time_sleep.wait_for_pe]
}
