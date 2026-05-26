# =============================================================================
# Full-stack example — Databricks Serverless → Confluent Cloud (Azure)
# =============================================================================
#
# Target topology:
#   Databricks Serverless
#       │  NCC PE rule (targets Application Gateway v2's native Private Link)
#       ▼
#   Customer-owned Application Gateway v2 with TCP/TLS proxy listener
#       │
#       ▼
#   Customer-owned PE → Confluent Cloud (via Confluent's PLS alias)
#       │
#       ▼
#   Confluent Cloud cluster (LKC-XXXXX in a Confluent Network)
#
# Why this transit exists:
#   See docs/why-transit.md for the full rationale.
#   Short version: NCC accepts only Azure Resource IDs; Confluent
#   publishes aliases; Standard LB can't have PE IPs as backends. Any
#   one of those forces a customer-tenant L4 proxy. App Gateway v2
#   TCP/TLS proxy (GA 2025-11-26) is the recommended managed-service
#   implementation of that proxy role.
#
# Why App Gateway v2 over VMSS + HAProxy:
#   - Managed PaaS — Microsoft patches, scales, monitors
#   - Native Private Link inbound (no separate PLS resource needed)
#   - Auto-scales 1→125 instances
#   - First-party Azure compliance posture (MAS TRM 7.4 / 8.2 aligned)
#   To swap back to VMSS + HAProxy (cost-saver, ~$60/mo vs ~$200/mo),
#   change the `module "transit"` source to `vmss-haproxy-transit`,
#   re-add the VMSS variables, and flip the NCC module's
#   `transit_mode` from "appgw" to "pls".
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
  subscription_id = var.azure_subscription_id
}

# azapi provider needed because azurerm does not yet expose App Gateway v2
# TCP listener configuration as a first-class resource type.
provider "azapi" {}

provider "databricks" {
  alias      = "account"
  host       = "https://accounts.azuredatabricks.net"
  account_id = var.databricks_account_id
}

# =============================================================================
# Resource group (transit infrastructure)
# =============================================================================
#
# The transit lives in a dedicated RG to keep its lifecycle independent of
# any application RG. To co-locate with an existing RG, replace this with
# a `data "azurerm_resource_group"` lookup.

resource "azurerm_resource_group" "transit" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}

# =============================================================================
# Local values
# =============================================================================

locals {
  tags = merge({
    Workload    = "databricks-serverless-to-confluent"
    Environment = var.environment
    ManagedBy   = "terraform"
  }, var.extra_tags)

  # Confluent Cloud clusters in a Confluent Network sit at:
  #   {cluster-id}.{network-id}.{region}.azure.confluent.cloud
  # The databricks-ncc-confluent module's auto-built FQDN omits the
  # network-id component, so we register the real FQDN + wildcard
  # explicitly via additional_domain_names.
  confluent_real_fqdn          = "${var.confluent_cluster_id}.${var.confluent_network_id}.${var.location}.azure.confluent.cloud"
  confluent_real_wildcard_fqdn = "*.${var.confluent_network_id}.${var.location}.azure.confluent.cloud"

  # Schema Registry / KSQL / Connect REST live on separate FQDNs.
  # NOTE: Schema Registry uses a separate Confluent PLS — registering its
  # FQDN here makes DNS resolve, but the App Gateway only proxies one
  # backend. A second listener or a parallel transit is required to
  # actually carry SR traffic.
  confluent_extra_fqdns = compact([
    var.confluent_schema_registry_fqdn, # e.g., "psrc-XXXXX.{region}.azure.confluent.cloud"
  ])

  ncc_additional_domain_names = concat(
    [local.confluent_real_fqdn, local.confluent_real_wildcard_fqdn],
    local.confluent_extra_fqdns,
  )
}

# =============================================================================
# Transit infrastructure (Application Gateway v2 TCP/TLS proxy + PE to Confluent)
# =============================================================================
#
# This module:
#   1. Creates a transit VNet (or reuses an existing one — see vars).
#   2. Creates three subnets: App Gateway data subnet, PE subnet for
#      the connection to Confluent, App Gateway Private Link subnet.
#   3. Creates the Application Gateway v2 with a TCP listener on
#      kafka_port pointing at the Confluent PE's private IP as the
#      backend.
#   4. Creates the Private Endpoint to Confluent (using Confluent's
#      PLS alias).
#   5. Enables App Gateway's native Private Link configuration — App
#      GW itself becomes the target the Databricks NCC PE rule attaches
#      to, no separate PLS resource needed.

module "transit" {
  source = "../../modules/appgw-transit"

  resource_group_name = azurerm_resource_group.transit.name
  location            = var.location
  name_prefix         = var.name_prefix

  # Confluent Cloud target (PLS alias, fetched from Confluent Cloud Console)
  confluent_private_link_service_alias = var.confluent_private_link_service_alias
  pe_request_message                   = var.pe_request_message

  # Network
  create_vnet                             = var.create_vnet
  vnet_name                               = var.vnet_name
  vnet_address_space                      = var.vnet_address_space
  appgw_subnet_address_prefix             = var.appgw_subnet_address_prefix
  pe_subnet_address_prefix                = var.pe_subnet_address_prefix
  appgw_privatelink_subnet_address_prefix = var.appgw_privatelink_subnet_address_prefix
  existing_vnet_id                        = var.existing_vnet_id
  existing_vnet_resource_group            = var.existing_vnet_resource_group

  # Application Gateway v2 & data port
  appgw_name         = "appgw-confluent-transit"
  appgw_sku_capacity = var.appgw_sku_capacity
  appgw_frontend_ip  = var.appgw_frontend_ip
  kafka_port         = var.kafka_port

  tags = local.tags
}

# =============================================================================
# Databricks NCC private-endpoint rule
# =============================================================================
#
# This module:
#   - Creates a new NCC (set ncc_name + region). If an existing NCC is
#     being reused, replace this module call with a direct REST API call
#     (or once supported, a databricks_mws_ncc_private_endpoint_rule
#     resource targeting App Gateway) against the existing NCC's ID.
#   - Creates the PE rule pointing at the App Gateway's Resource ID.
#   - Registers Confluent FQDNs via `additional_domain_names` so NCC's
#     managed DNS injects PE-IP resolution for them.
#   - Triggers PE auto-approval on the App Gateway side.
#   - Binds the NCC to the listed workspaces.
#
# NOTE: For App Gateway transit, the Databricks Terraform provider does
# not yet support the PE rule resource type natively. The module falls
# back to a REST API call, which requires `databricks_account_id` and
# `databricks_host` (both passed below).

module "ncc_pe_rule" {
  source = "../../modules/databricks-ncc-confluent"

  providers = {
    databricks = databricks.account
  }

  ncc_name = var.ncc_name
  region   = var.location

  # App Gateway path: NCC PE rule targets the App GW's Resource ID and
  # uses Databricks' REST API (no native terraform resource yet).
  transit_mode          = "appgw"
  transit_resource_id   = module.transit.appgw_id
  databricks_account_id = var.databricks_account_id
  databricks_host       = "https://accounts.azuredatabricks.net"

  # For the auto-approval helper that the module runs after creating the PE rule
  transit_resource_group_name = azurerm_resource_group.transit.name
  transit_resource_name       = module.transit.appgw_name
  auto_approve_pe             = true

  # The module builds bootstrap + wildcard FQDNs from cluster_id and
  # region. For Confluent Network clusters the real FQDN includes the
  # network-id component (registered via additional_domain_names below).
  confluent_cluster_id = var.confluent_cluster_id
  confluent_region     = var.location

  additional_domain_names = local.ncc_additional_domain_names

  workspace_ids = var.databricks_workspace_ids

  depends_on = [module.transit]
}

# =============================================================================
# Outputs
# =============================================================================

output "transit_appgw_id" {
  description = "Resource ID of the App Gateway. This is what the NCC PE rule targets."
  value       = module.transit.appgw_id
}

output "transit_appgw_name" {
  description = "Name of the transit App Gateway."
  value       = module.transit.appgw_name
}

output "transit_frontend_ip" {
  description = "Private IP of the App Gateway frontend."
  value       = module.transit.frontend_ip
}

output "ncc_id" {
  description = "Databricks NCC ID (the one the module created or referenced)."
  value       = module.ncc_pe_rule.ncc_id
}

output "registered_fqdns" {
  description = "All FQDNs the NCC PE rule will inject DNS for. Validate against Confluent's advertised hostnames before declaring success."
  value       = local.ncc_additional_domain_names
}
