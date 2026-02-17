# =============================================================================
# Required Variables
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

variable "private_link_service_id" {
  description = "Resource ID of the Private Link Service (from confluent-transit-slb module)"
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
# PE Approval Configuration
# =============================================================================

variable "pls_resource_group_name" {
  description = "Resource group containing the Private Link Service (for PE approval)"
  type        = string
}

variable "pls_name" {
  description = "Name of the Private Link Service (for PE approval)"
  type        = string
}

variable "auto_approve_pe" {
  description = "Automatically approve the PE connection on the Private Link Service"
  type        = bool
  default     = true
}

# =============================================================================
# Advanced Configuration
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
