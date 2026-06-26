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

variable "transit_resource_id" {
  description = "Resource ID of the Application Gateway used as the NCC private endpoint target"
  type        = string
}

variable "confluent_bootstrap_servers" {
  description = "Confluent bootstrap servers value to use in Kafka clients, including port"
  type        = string
}

variable "confluent_ncc_domain_names" {
  description = "Confluent FQDNs and wildcard domains that Databricks NCC must intercept"
  type        = list(string)

  validation {
    condition     = length(var.confluent_ncc_domain_names) > 0
    error_message = "At least one Confluent NCC domain name must be provided."
  }
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
# PE approval configuration
# =============================================================================

variable "transit_resource_group_name" {
  description = "Resource group containing the transit resource (PLS or App GW) for PE approval"
  type        = string
}

variable "transit_resource_name" {
  description = "Name of the Application Gateway for PE approval"
  type        = string
}

variable "auto_approve_pe" {
  description = "Automatically approve the PE connection on the transit resource"
  type        = bool
  default     = true
}

# =============================================================================
# App Gateway REST API configuration
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
  description = "Additional domain names to add to the NCC PE rule"
  type        = list(string)
  default     = []
}

variable "group_id" {
  description = "Application Gateway private link group ID. This must match the frontend IP configuration name exposed through Private Link."
  type        = string
  default     = "frontend-private"
}
