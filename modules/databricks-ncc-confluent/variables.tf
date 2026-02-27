# =============================================================================
# Required variables
# =============================================================================

variable "ncc_name" {
  description = "Name for the Network Connectivity Configuration"
  type        = string
  default     = "ncc-confluent"
}

variable "region" {
  description = "Azure region - must match workspace region"
  type        = string
}

variable "transit_mode" {
  description = <<-EOT
    Transit architecture mode:
    - "pls": Private Link Service (used with vmss-haproxy-transit module)
    - "appgw": Application Gateway v2 (used with appgw-transit module)
  EOT
  type        = string
  default     = "pls"

  validation {
    condition     = contains(["pls", "appgw"], var.transit_mode)
    error_message = "transit_mode must be either 'pls' or 'appgw'."
  }
}

variable "transit_resource_id" {
  description = "Resource ID of the transit resource (PLS ID for pls mode, App GW ID for appgw mode)"
  type        = string
}

variable "confluent_cluster_id" {
  description = "Confluent cluster ID (e.g., pkc-xxxxx)"
  type        = string

  validation {
    condition     = can(regex("^(pkc|lkc)-[a-z0-9]+$", var.confluent_cluster_id))
    error_message = "Confluent cluster ID must be in format: pkc-xxxxx or lkc-xxxxx"
  }
}

variable "confluent_region" {
  description = "Confluent Cloud region (e.g., eastus, westus2)"
  type        = string
}

variable "workspace_ids" {
  description = "List of Databricks workspace IDs to attach this NCC to"
  type        = list(string)

  validation {
    condition     = length(var.workspace_ids) > 0
    error_message = "At least one workspace ID must be provided."
  }
}

# =============================================================================
# PE approval configuration (PLS mode)
# =============================================================================

variable "transit_resource_group_name" {
  description = "Resource group containing the transit resource (PLS or App GW) for PE approval"
  type        = string
}

variable "transit_resource_name" {
  description = "Name of the transit resource (PLS name or App GW name) for PE approval"
  type        = string
}

variable "auto_approve_pe" {
  description = "Automatically approve the PE connection on the transit resource"
  type        = bool
  default     = true
}

# =============================================================================
# App GW mode configuration
# =============================================================================

variable "databricks_account_id" {
  description = "Databricks account ID (required for appgw mode REST API calls)"
  type        = string
  default     = ""

  validation {
    condition     = var.databricks_account_id == "" || can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.databricks_account_id))
    error_message = "Databricks account ID must be a valid UUID or empty string."
  }
}

variable "databricks_host" {
  description = "Databricks accounts API host (for appgw mode REST API calls)"
  type        = string
  default     = "https://accounts.azuredatabricks.net"
}

# =============================================================================
# Advanced configuration
# =============================================================================

variable "additional_domain_names" {
  description = "Additional domain names to add to the NCC PE rule (beyond bootstrap and wildcard)"
  type        = list(string)
  default     = []
}

variable "group_id" {
  description = "Group ID for the private endpoint rule"
  type        = string
  default     = "confluent-kafka"
}
