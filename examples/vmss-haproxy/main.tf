# =============================================================================
# Example: VMSS HAProxy transit architecture
# =============================================================================
#
# This example creates the transit architecture using:
#   - Azure Standard Load Balancer + VMSS with HAProxy
#   - Private Link Service (PLS) for Databricks NCC connectivity
#   - Private Endpoint to Confluent Cloud
#   - Databricks NCC with Private Endpoint Rule
#   - Private DNS Zone (optional, for classic compute)
#
# Architecture:
#   Databricks Serverless -> NCC PE -> PLS -> LB -> VMSS HAProxy -> Confluent PE -> Kafka
#
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.80"
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
# Transit infrastructure (LB + VMSS HAProxy + PLS)
# =============================================================================

module "confluent_transit" {
  source = "../../modules/vmss-haproxy-transit"

  resource_group_name                  = azurerm_resource_group.confluent.name
  location                             = var.location
  confluent_private_link_service_alias = var.confluent_private_link_service_alias

  # Network
  create_vnet                = true
  vnet_name                  = "vnet-confluent-transit"
  vnet_address_space         = var.vnet_address_space
  lb_subnet_address_prefix   = var.lb_subnet_address_prefix
  pe_subnet_address_prefix   = var.pe_subnet_address_prefix
  vmss_subnet_address_prefix = var.vmss_subnet_address_prefix

  # Load Balancer
  lb_name        = "lb-confluent"
  lb_frontend_ip = var.lb_frontend_ip
  kafka_port     = var.kafka_port

  # VMSS
  vmss_name                 = "vmss-haproxy"
  vmss_sku                  = var.vmss_sku
  vmss_instances            = var.vmss_instances
  vmss_admin_ssh_public_key = var.vmss_admin_ssh_public_key

  # PLS
  pls_name                           = "pls-confluent"
  pls_nat_ip_count                   = 1
  pls_auto_approval_subscription_ids = var.auto_approve_subscription_ids

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
  transit_mode         = "pls"
  transit_resource_id  = module.confluent_transit.pls_id
  confluent_cluster_id = var.confluent_cluster_id
  confluent_region     = var.confluent_region
  workspace_ids        = var.databricks_workspace_ids

  # For PE approval
  transit_resource_group_name = azurerm_resource_group.confluent.name
  transit_resource_name       = module.confluent_transit.pls_name
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
  target_ip            = module.confluent_transit.lb_frontend_ip
  broker_count         = var.broker_count

  vnet_ids_to_link = [module.confluent_transit.vnet_id]
  vnet_names       = ["transit-vnet"]

  tags = var.tags

  depends_on = [module.confluent_transit]
}
