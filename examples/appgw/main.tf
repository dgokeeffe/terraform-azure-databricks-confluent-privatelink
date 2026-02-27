# =============================================================================
# Example: Application Gateway v2 TCP proxy transit architecture
# =============================================================================
#
# This example creates the transit architecture using:
#   - Azure Application Gateway v2 with TCP proxy (preview)
#   - App GW native Private Link for Databricks NCC connectivity
#   - Private Endpoint to Confluent Cloud
#   - Databricks NCC with Private Endpoint Rule (via REST API)
#   - Private DNS Zone (optional, for classic compute)
#
# Architecture:
#   Databricks Serverless -> NCC PE -> App GW v2 (TCP proxy) -> Confluent PE -> Kafka
#
# NOTE: App GW TCP proxy requires API version 2024-05-01+ and is in preview.
# The azapi provider is required because azurerm does not support TCP listeners.
#
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.80"
    }
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.0"
    }
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.50"
    }
  }
}

# =============================================================================
# Providers
# =============================================================================

provider "azurerm" {
  features {}
}

provider "azapi" {}

provider "databricks" {
  alias      = "account"
  host       = "https://accounts.azuredatabricks.net"
  account_id = var.databricks_account_id
}

# =============================================================================
# Resource group
# =============================================================================

resource "azurerm_resource_group" "confluent" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# =============================================================================
# Transit infrastructure (App Gateway v2 with TCP proxy)
# =============================================================================

module "confluent_transit" {
  source = "../../modules/appgw-transit"

  resource_group_name                  = azurerm_resource_group.confluent.name
  location                             = var.location
  confluent_private_link_service_alias = var.confluent_private_link_service_alias

  # Network
  create_vnet                             = true
  vnet_name                               = "vnet-confluent-transit"
  vnet_address_space                      = var.vnet_address_space
  appgw_subnet_address_prefix             = var.appgw_subnet_address_prefix
  pe_subnet_address_prefix                = var.pe_subnet_address_prefix
  appgw_privatelink_subnet_address_prefix = var.appgw_privatelink_subnet_address_prefix

  # App Gateway
  appgw_name         = "appgw-confluent"
  appgw_frontend_ip  = var.appgw_frontend_ip
  appgw_sku_capacity = var.appgw_sku_capacity
  kafka_port         = var.kafka_port

  tags = var.tags

  depends_on = [azurerm_resource_group.confluent]
}

# =============================================================================
# Databricks NCC configuration
# =============================================================================

module "databricks_ncc" {
  source = "../../modules/databricks-ncc-confluent"

  providers = {
    databricks = databricks.account
  }

  ncc_name             = "ncc-confluent-${var.location}"
  region               = var.location
  transit_mode         = "appgw"
  transit_resource_id  = module.confluent_transit.appgw_id
  confluent_cluster_id = var.confluent_cluster_id
  confluent_region     = var.confluent_region
  workspace_ids        = var.databricks_workspace_ids

  # For App GW mode
  databricks_account_id = var.databricks_account_id

  # For PE approval
  transit_resource_group_name = azurerm_resource_group.confluent.name
  transit_resource_name       = module.confluent_transit.appgw_name
  auto_approve_pe             = var.auto_approve_databricks_pe

  depends_on = [module.confluent_transit]
}

# =============================================================================
# Private DNS Zone (optional - for classic compute)
# =============================================================================

module "confluent_dns" {
  count  = var.enable_dns_zone ? 1 : 0
  source = "../../modules/confluent-dns"

  resource_group_name  = azurerm_resource_group.confluent.name
  location             = var.location
  confluent_cluster_id = var.confluent_cluster_id
  confluent_region     = var.confluent_region
  target_ip            = module.confluent_transit.frontend_ip
  broker_count         = var.broker_count

  vnet_ids_to_link = [module.confluent_transit.vnet_id]
  vnet_names       = ["transit-vnet"]

  tags = var.tags

  depends_on = [module.confluent_transit]
}
