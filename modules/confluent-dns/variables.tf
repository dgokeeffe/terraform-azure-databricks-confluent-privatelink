# =============================================================================
# Required Variables
# =============================================================================

variable "resource_group_name" {
  description = "Azure resource group name"
  type        = string
}

variable "location" {
  description = "Azure region"
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

variable "target_ip" {
  description = "IP address to resolve Confluent FQDNs to (Load Balancer frontend IP or Confluent PE IP)"
  type        = string

  validation {
    condition     = can(regex("^(?:[0-9]{1,3}\\.){3}[0-9]{1,3}$", var.target_ip))
    error_message = "Target IP must be a valid IPv4 address."
  }
}

# =============================================================================
# Broker Configuration
# =============================================================================

variable "broker_count" {
  description = "Number of Kafka brokers in the Confluent cluster (typically 3-12)"
  type        = number
  default     = 6

  validation {
    condition     = var.broker_count >= 1 && var.broker_count <= 100
    error_message = "Broker count must be between 1 and 100."
  }
}

# =============================================================================
# VNet Linking
# =============================================================================

variable "vnet_ids_to_link" {
  description = "List of VNet IDs to link to the Private DNS Zone"
  type        = list(string)

  validation {
    condition     = length(var.vnet_ids_to_link) > 0
    error_message = "At least one VNet ID must be provided."
  }
}

variable "vnet_names" {
  description = "Names for VNet links (must match length of vnet_ids_to_link)"
  type        = list(string)

  validation {
    condition     = length(var.vnet_names) > 0
    error_message = "At least one VNet name must be provided."
  }
}

# =============================================================================
# Zonal Endpoints (Optional)
# =============================================================================

variable "enable_zonal_endpoints" {
  description = "Enable zonal endpoint DNS records (lkc-xxxxx-xxxx.eastus.azure.confluent.cloud)"
  type        = bool
  default     = false
}

variable "zonal_endpoint_id" {
  description = "Zonal endpoint ID if using dedicated endpoints (e.g., lkc-xxxxx)"
  type        = string
  default     = ""
}

# =============================================================================
# DNS Settings
# =============================================================================

variable "ttl" {
  description = "DNS record TTL in seconds"
  type        = number
  default     = 300
}

# =============================================================================
# Tagging
# =============================================================================

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
