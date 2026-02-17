# =============================================================================
# Required Variables
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
  description = <<-EOT
    Confluent Cloud Private Link Service alias.
    Find this in Confluent Cloud Console:
    Cluster -> Settings -> Networking -> Private Link -> Azure Private Link Service alias
    Format: s-xxxxx.privatelink.confluent.cloud
  EOT
  type        = string
}

variable "confluent_cluster_id" {
  description = "Confluent cluster ID (e.g., pkc-xxxxx or lkc-xxxxx)"
  type        = string
}

variable "confluent_region" {
  description = "Confluent Cloud region (e.g., eastus, westus2). Usually matches Azure region."
  type        = string
}

# =============================================================================
# Azure Configuration
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
# Network Configuration
# =============================================================================

variable "vnet_address_space" {
  description = "Address space for the transit VNet"
  type        = list(string)
  default     = ["10.200.0.0/16"]
}

variable "lb_subnet_address_prefix" {
  description = "Address prefix for the Load Balancer subnet"
  type        = string
  default     = "10.200.1.0/24"
}

variable "pe_subnet_address_prefix" {
  description = "Address prefix for the Private Endpoint subnet"
  type        = string
  default     = "10.200.2.0/24"
}

variable "lb_frontend_ip" {
  description = "Static private IP for Load Balancer frontend. Leave empty for dynamic allocation."
  type        = string
  default     = "10.200.1.100"
}

# =============================================================================
# Kafka Configuration
# =============================================================================

variable "kafka_ports" {
  description = "Kafka ports to configure on the Load Balancer"
  type        = list(number)
  default     = [9092]
}

variable "broker_count" {
  description = "Number of Kafka brokers in the Confluent cluster (for DNS records)"
  type        = number
  default     = 6
}

# =============================================================================
# Optional Features
# =============================================================================

variable "enable_dns_zone" {
  description = "Create Private DNS Zone for classic compute access"
  type        = bool
  default     = true
}

variable "auto_approve_subscription_ids" {
  description = "Azure subscription IDs to auto-approve on the Private Link Service"
  type        = list(string)
  default     = []
}

variable "auto_approve_databricks_pe" {
  description = "Automatically approve Databricks PE connection on the Private Link Service"
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
