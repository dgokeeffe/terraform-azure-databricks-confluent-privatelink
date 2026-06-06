# =============================================================================
# Example — service-direct inbound Private Link (performance-intensive services)
# =============================================================================
#
# Stands up an Azure private endpoint to the Databricks per-region PLS for
# performance-intensive services (Zerobus Ingest, Lakebase Autoscaling), wires
# the privatelink.azuredatabricks.net DNS A record (<region>.service-direct),
# and registers the endpoint on the Databricks account side so it transitions
# from PENDING to APPROVED.
#
# See ../../docs/service-direct-privatelink.md for the rationale and gotchas.
#
# Prerequisites:
#   - Premium-tier Databricks account.
#   - The "Private connectivity for performance-intensive services" Public
#     Preview feature enabled on the account (self-enroll in the account
#     console) — otherwise the registration surface does not appear.
#   - An existing VNet + a dedicated subnet for the private endpoint (PE
#     network policies disabled — the Azure default). Reusing the workspace
#     VNet is fine, but use a different subnet from the workspace's.
#   - The per-region PLS resource ID from the Microsoft Learn region table.
#
# STATUS: Public Preview (both the feature and the databricks_endpoint
# resource). Run `terraform plan` and inspect carefully before applying.
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
      version = ">= 1.107.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.azure_subscription_id
}

provider "azapi" {}

# databricks_endpoint requires an ACCOUNT-level provider.
provider "databricks" {
  alias      = "account"
  host       = "https://accounts.azuredatabricks.net"
  account_id = var.databricks_account_id
}

# Hold the private endpoint (+ DNS zone, if created here) in its own RG.
resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.region
}

module "service_direct" {
  source = "../../modules/databricks-service-direct"

  providers = {
    databricks = databricks.account
  }

  region                     = var.region
  resource_group_name        = azurerm_resource_group.this.name
  private_endpoint_subnet_id = var.private_endpoint_subnet_id
  databricks_pls_resource_id = var.databricks_pls_resource_id
  databricks_account_id      = var.databricks_account_id

  # Create the privatelink.azuredatabricks.net zone here and link the PE VNet.
  # Set create_private_dns_zone = false to reuse an existing zone (common when
  # the workspace already uses inbound Private Link).
  create_private_dns_zone = var.create_private_dns_zone
  vnet_ids_to_link        = var.vnet_ids_to_link
  vnet_link_names         = var.vnet_link_names

  tags = var.tags
}
