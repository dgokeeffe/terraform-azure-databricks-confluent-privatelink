# =============================================================================
# Full-stack example — Databricks Serverless → Confluent Cloud (Azure)
# =============================================================================
#
# Target topology:
#   Databricks Serverless
#       │  NCC PE rule (Resource ID of the transit PLS + Confluent FQDNs)
#       ▼
#   Customer-owned transit: Standard LB + VMSS HAProxy + PLS
#       │
#       ▼
#   Customer-owned PE → Confluent Cloud (via Confluent's PLS alias)
#       │
#       ▼
#   Confluent Cloud cluster (LKC-XXXXX in a Confluent Network)
#
# Why this transit exists:
#   - Databricks NCC private-endpoint rules accept only Azure Resource IDs,
#     not Private Link Service aliases. Confluent Cloud publishes aliases
#     across tenants, not Resource IDs — so NCC cannot attach directly.
#   - The transit's PLS lives in the customer's tenant where the Resource ID
#     is available; the transit's own PE attaches to Confluent via alias
#     (the standard cross-tenant flow).
#   - Result: the transit is an API-shape adapter between NCC ("Resource ID
#     only") and Confluent ("alias only").
#
# Transit choice in this file: VMSS + HAProxy (Option B, GA, cheaper).
# Option A (App Gateway v2 TCP/TLS proxy) is now GA and is the
# recommended primary pattern when managed-service ops is preferred
# over cost optimisation. To swap to App GW, change the module source
# from `vmss-haproxy-transit` to `appgw-transit` and adjust the NCC
# module's transit_mode from "pls" to "appgw".
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
  subscription_id = var.azure_subscription_id
}

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
  # FQDN here makes DNS resolve, but the transit module only proxies one
  # port. A second proxy chain is required to actually carry SR traffic.
  confluent_extra_fqdns = compact([
    var.confluent_schema_registry_fqdn, # e.g., "psrc-XXXXX.{region}.azure.confluent.cloud"
  ])

  ncc_additional_domain_names = concat(
    [local.confluent_real_fqdn, local.confluent_real_wildcard_fqdn],
    local.confluent_extra_fqdns,
  )
}

# =============================================================================
# Transit infrastructure (LB + VMSS HAProxy + PLS + PE to Confluent)
# =============================================================================
#
# This module:
#   1. Creates a transit VNet (or reuses an existing one — see vars).
#   2. Creates a Standard Internal LB.
#   3. Creates a VMSS running HAProxy that proxies kafka_port TCP from the
#      LB backend to the Confluent PE's private IP.
#   4. Creates the Private Endpoint to Confluent (using Confluent's PLS
#      alias).
#   5. Creates the Private Link Service that fronts the LB — this is what
#      Databricks' NCC will attach to.

module "transit" {
  source = "../../modules/vmss-haproxy-transit"

  resource_group_name = azurerm_resource_group.transit.name
  location            = var.location
  name_prefix         = var.name_prefix

  # Confluent Cloud target (PLS alias, fetched from Confluent Cloud Console)
  confluent_private_link_service_alias = var.confluent_private_link_service_alias
  pe_request_message                   = var.pe_request_message

  # Network
  create_vnet                  = var.create_vnet
  vnet_name                    = var.vnet_name
  vnet_address_space           = var.vnet_address_space
  lb_subnet_address_prefix     = var.lb_subnet_address_prefix
  pe_subnet_address_prefix     = var.pe_subnet_address_prefix
  vmss_subnet_address_prefix   = var.vmss_subnet_address_prefix
  existing_vnet_id             = var.existing_vnet_id
  existing_vnet_resource_group = var.existing_vnet_resource_group

  # Load Balancer & data port
  lb_name        = "lb-confluent-transit"
  lb_frontend_ip = var.lb_frontend_ip
  kafka_port     = var.kafka_port

  # VMSS sizing
  vmss_name                 = "vmss-haproxy-confluent"
  vmss_sku                  = var.vmss_sku
  vmss_instances            = var.vmss_instances
  vmss_admin_ssh_public_key = var.vmss_admin_ssh_public_key

  # PLS exposed to Databricks
  pls_name         = "pls-confluent-transit"
  pls_nat_ip_count = var.pls_nat_ip_count

  # Restrict who can attach a PE to the transit PLS. Auto-approve
  # Databricks' managed serverless subscription so the NCC PE rule comes
  # up clean without manual intervention. Get the region-specific ID from
  # the Databricks docs ("Microsoft Azure subscriptions used by Databricks
  # managed services").
  pls_visibility_subscription_ids    = [var.databricks_managed_subscription_id]
  pls_auto_approval_subscription_ids = [var.databricks_managed_subscription_id]

  tags = local.tags
}

# =============================================================================
# Databricks NCC private-endpoint rule
# =============================================================================
#
# This module:
#   - Creates a new NCC (set ncc_name + region). If an existing NCC is
#     being reused, replace this module call with a direct
#     `databricks_mws_ncc_private_endpoint_rule` resource referencing the
#     existing NCC's ID.
#   - Creates the PE rule pointing at the transit's PLS.
#   - Registers Confluent FQDNs via `additional_domain_names` so NCC's
#     managed DNS injects PE-IP resolution for them.
#   - Triggers PLS-side auto-approval for the Databricks-managed PE.
#   - Binds the NCC to the listed workspaces.

module "ncc_pe_rule" {
  source = "../../modules/databricks-ncc-confluent"

  providers = {
    databricks = databricks.account
  }

  ncc_name = var.ncc_name
  region   = var.location

  transit_mode        = "pls"
  transit_resource_id = module.transit.pls_id

  transit_resource_group_name = azurerm_resource_group.transit.name
  transit_resource_name       = module.transit.pls_name
  auto_approve_pe             = true

  # The module builds bootstrap + wildcard FQDNs from cluster_id and
  # region. For Confluent Network clusters the real FQDN includes the
  # network-id component (registered via additional_domain_names below).
  confluent_cluster_id = var.confluent_cluster_id
  confluent_region     = var.location

  additional_domain_names = local.ncc_additional_domain_names

  workspace_ids = var.databricks_workspace_ids

  # group_id for customer-managed-PLS rules. The repo's module default is
  # "confluent-kafka" (legacy Databricks-internal name). The canonical
  # current value is "azure_private_link_service". If terraform apply
  # fails with a 4xx on the NCC PE rule, swap by overriding here:
  # group_id = "azure_private_link_service"

  depends_on = [module.transit]
}

# =============================================================================
# Outputs
# =============================================================================

output "transit_pls_id" {
  description = "Resource ID of the transit PLS. This is what the NCC PE rule targets."
  value       = module.transit.pls_id
}

output "transit_pls_name" {
  description = "Name of the transit PLS."
  value       = module.transit.pls_name
}

output "transit_lb_frontend_ip" {
  description = "Private IP of the transit load balancer frontend."
  value       = module.transit.lb_frontend_ip
}

output "confluent_pe_private_ip" {
  description = "Private IP of the PE connecting the transit to Confluent Cloud. Useful for HAProxy config debugging."
  value       = module.transit.confluent_pe_private_ip
}

output "ncc_id" {
  description = "Databricks NCC ID (the one the module created or referenced)."
  value       = module.ncc_pe_rule.ncc_id
}

output "registered_fqdns" {
  description = "All FQDNs the NCC PE rule will inject DNS for. Validate against Confluent's advertised hostnames before declaring success."
  value       = local.ncc_additional_domain_names
}
