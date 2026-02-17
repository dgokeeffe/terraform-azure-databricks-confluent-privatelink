# =============================================================================
# Complete Example: Databricks Serverless to Confluent Cloud via Private Link
# =============================================================================
#
# This example creates the complete transit architecture for private
# connectivity from Databricks Serverless Compute to Confluent Cloud Kafka.
#
# Components:
#   - Azure Transit VNet with subnets
#   - Private Endpoint to Confluent Cloud
#   - Azure Standard Load Balancer
#   - Private Link Service
#   - Databricks NCC with Private Endpoint Rule
#   - Private DNS Zone (for classic compute)
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

  # Uncomment to use remote state
  # backend "azurerm" {
  #   resource_group_name  = "rg-terraform-state"
  #   storage_account_name = "tfstate"
  #   container_name       = "tfstate"
  #   key                  = "confluent-privatelink.tfstate"
  # }
}

# =============================================================================
# Providers
# =============================================================================

provider "azurerm" {
  features {}

  # Uncomment if using service principal
  # subscription_id = var.azure_subscription_id
  # tenant_id       = var.azure_tenant_id
  # client_id       = var.azure_client_id
  # client_secret   = var.azure_client_secret
}

# Account-level Databricks provider for NCC resources
provider "databricks" {
  alias      = "account"
  host       = "https://accounts.azuredatabricks.net"
  account_id = var.databricks_account_id

  # Auth via environment variables:
  # ARM_CLIENT_ID, ARM_CLIENT_SECRET, ARM_TENANT_ID
  # or explicit attributes below
}

# =============================================================================
# Resource Group
# =============================================================================

resource "azurerm_resource_group" "confluent" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# =============================================================================
# Transit Infrastructure (Load Balancer, Private Link Service)
# =============================================================================

module "confluent_transit" {
  source = "../../modules/confluent-transit-slb"

  resource_group_name                  = azurerm_resource_group.confluent.name
  location                             = var.location
  confluent_private_link_service_alias = var.confluent_private_link_service_alias

  # Network configuration
  create_vnet              = true
  vnet_name                = "vnet-confluent-transit"
  vnet_address_space       = var.vnet_address_space
  lb_subnet_address_prefix = var.lb_subnet_address_prefix
  pe_subnet_address_prefix = var.pe_subnet_address_prefix

  # Load Balancer
  lb_name        = "lb-confluent"
  lb_frontend_ip = var.lb_frontend_ip
  kafka_ports    = var.kafka_ports

  # Private Link Service
  pls_name         = "pls-confluent"
  pls_nat_ip_count = 1

  # Auto-approve from Databricks subscription (optional)
  pls_auto_approval_subscription_ids = var.auto_approve_subscription_ids

  tags = var.tags

  depends_on = [azurerm_resource_group.confluent]
}

# =============================================================================
# Databricks NCC Configuration
# =============================================================================

module "databricks_ncc" {
  source = "../../modules/databricks-ncc-confluent"

  providers = {
    databricks = databricks.account
  }

  ncc_name                = "ncc-confluent-${var.location}"
  region                  = var.location
  private_link_service_id = module.confluent_transit.pls_id
  confluent_cluster_id    = var.confluent_cluster_id
  confluent_region        = var.confluent_region
  workspace_ids           = var.databricks_workspace_ids

  # For PE approval automation
  pls_resource_group_name = azurerm_resource_group.confluent.name
  pls_name                = module.confluent_transit.pls_name
  auto_approve_pe         = var.auto_approve_databricks_pe

  depends_on = [module.confluent_transit]
}

# =============================================================================
# Private DNS Zone (Optional - for classic compute)
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
