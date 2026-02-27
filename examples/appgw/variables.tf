# =============================================================================
# Required variables
# =============================================================================

variable "databricks_account_id" {
  description = "Databricks account ID (UUID format)"
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.databricks_account_id))
    error_message = "Databricks account ID must be a valid UUID."
  }
}

variable "databricks_workspace_ids" {
  description = "List of Databricks workspace IDs to attach the NCC to"
  type        = list(string)

  validation {
    condition     = length(var.databricks_workspace_ids) > 0
    error_message = "At least one workspace ID must be provided."
  }
}

variable "confluent_private_link_service_alias" {
  description = "Confluent Cloud Private Link Service alias (s-xxxxx.privatelink.confluent.cloud)"
  type        = string
}

variable "confluent_cluster_id" {
  description = "Confluent cluster ID (e.g., pkc-xxxxx or lkc-xxxxx)"
  type        = string
}

variable "confluent_region" {
  description = "Confluent Cloud region (usually matches Azure region)"
  type        = string
}

# =============================================================================
# Azure configuration
# =============================================================================

variable "resource_group_name" {
  description = "Name of the Azure resource group to create"
  type        = string
  default     = "rg-confluent-transit"
}

variable "location" {
  description = "Azure region - must match Databricks workspace region"
  type        = string
  default     = "eastus"
}

# =============================================================================
# Network configuration
# =============================================================================

variable "vnet_address_space" {
  description = "Address space for the transit VNet"
  type        = list(string)
  default     = ["10.200.0.0/16"]
}

variable "appgw_subnet_address_prefix" {
  description = "Address prefix for the App Gateway subnet"
  type        = string
  default     = "10.200.1.0/24"
}

variable "pe_subnet_address_prefix" {
  description = "Address prefix for the Private Endpoint subnet"
  type        = string
  default     = "10.200.2.0/24"
}

variable "appgw_privatelink_subnet_address_prefix" {
  description = "Address prefix for the App GW Private Link subnet"
  type        = string
  default     = "10.200.3.0/24"
}

variable "appgw_frontend_ip" {
  description = "Static private IP for App GW frontend. Leave empty for dynamic."
  type        = string
  default     = ""
}

# =============================================================================
# App Gateway / Kafka configuration
# =============================================================================

variable "kafka_port" {
  description = "Kafka broker port"
  type        = number
  default     = 9092
}

variable "appgw_sku_capacity" {
  description = "App Gateway instance count"
  type        = number
  default     = 2
}

variable "broker_count" {
  description = "Number of Kafka brokers (for DNS records)"
  type        = number
  default     = 6
}

# =============================================================================
# Optional features
# =============================================================================

variable "enable_dns_zone" {
  description = "Create Private DNS Zone for classic compute access"
  type        = bool
  default     = true
}

variable "auto_approve_databricks_pe" {
  description = "Automatically approve Databricks PE connection on the App Gateway"
  type        = bool
  default     = true
}

# =============================================================================
# Tags
# =============================================================================

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    ManagedBy = "terraform"
    Purpose   = "databricks-confluent-privatelink"
  }
}
