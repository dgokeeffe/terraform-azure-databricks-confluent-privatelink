# =============================================================================
# Required Variables
# =============================================================================

variable "resource_group_name" {
  description = "Name of the Azure resource group to create resources in"
  type        = string
}

variable "location" {
  description = "Azure region - must match Databricks workspace and Confluent cluster region"
  type        = string
}

variable "confluent_private_link_service_alias" {
  description = <<-EOT
    Confluent Cloud Private Link Service alias.
    Find this in Confluent Cloud Console:
    Cluster -> Settings -> Networking -> Private Link -> Azure Private Link Service alias
    Format: s-xxxxx.privatelink.confluent.cloud
  EOT
  type        = string

  validation {
    condition     = can(regex("^s-[a-z0-9]+\\.privatelink\\.confluent\\.cloud$", var.confluent_private_link_service_alias))
    error_message = "Confluent Private Link service alias must be in format: s-xxxxx.privatelink.confluent.cloud"
  }
}

# =============================================================================
# Network Configuration
# =============================================================================

variable "create_vnet" {
  description = "Create a new VNet for transit, or use existing"
  type        = bool
  default     = true
}

variable "vnet_name" {
  description = "Name of the transit VNet (created or existing)"
  type        = string
  default     = "vnet-confluent-transit"
}

variable "vnet_address_space" {
  description = "Address space for the transit VNet (if creating)"
  type        = list(string)
  default     = ["10.200.0.0/16"]
}

variable "existing_vnet_id" {
  description = "Resource ID of existing VNet (required if create_vnet = false)"
  type        = string
  default     = ""
}

variable "existing_vnet_resource_group" {
  description = "Resource group of existing VNet (required if create_vnet = false)"
  type        = string
  default     = ""
}

variable "create_subnets" {
  description = "Create new subnets, or use existing"
  type        = bool
  default     = true
}

variable "lb_subnet_name" {
  description = "Name of subnet for Load Balancer and Private Link Service"
  type        = string
  default     = "snet-lb"
}

variable "lb_subnet_address_prefix" {
  description = "Address prefix for LB subnet (if creating)"
  type        = string
  default     = "10.200.1.0/24"
}

variable "pe_subnet_name" {
  description = "Name of subnet for Private Endpoint to Confluent"
  type        = string
  default     = "snet-privateendpoints"
}

variable "pe_subnet_address_prefix" {
  description = "Address prefix for PE subnet (if creating)"
  type        = string
  default     = "10.200.2.0/24"
}

variable "existing_lb_subnet_id" {
  description = "Resource ID of existing LB subnet (required if create_subnets = false)"
  type        = string
  default     = ""
}

variable "existing_pe_subnet_id" {
  description = "Resource ID of existing PE subnet (required if create_subnets = false)"
  type        = string
  default     = ""
}

# =============================================================================
# Load Balancer Configuration
# =============================================================================

variable "lb_name" {
  description = "Name of the Azure Standard Load Balancer"
  type        = string
  default     = "lb-confluent-transit"
}

variable "lb_frontend_ip" {
  description = "Static private IP for Load Balancer frontend (must be in lb_subnet range). Leave empty for dynamic allocation."
  type        = string
  default     = ""
}

variable "lb_sku" {
  description = "Load Balancer SKU - must be Standard for Private Link"
  type        = string
  default     = "Standard"

  validation {
    condition     = var.lb_sku == "Standard"
    error_message = "Load Balancer SKU must be 'Standard' for Private Link Service support."
  }
}

# =============================================================================
# Kafka Port Configuration
# =============================================================================

variable "kafka_ports" {
  description = <<-EOT
    List of Kafka ports to configure on the Load Balancer.
    Default: 9092 (standard Kafka port)
    Add 443 if using Confluent Cloud with TLS on port 443
  EOT
  type        = list(number)
  default     = [9092]
}

variable "enable_kafka_rest_proxy" {
  description = "Enable port 443 for Kafka REST Proxy / Schema Registry"
  type        = bool
  default     = false
}

# =============================================================================
# Health Probe Configuration
# =============================================================================

variable "health_probe_interval" {
  description = "Health probe interval in seconds"
  type        = number
  default     = 5
}

variable "health_probe_count" {
  description = "Number of consecutive probe failures before marking unhealthy"
  type        = number
  default     = 2
}

# =============================================================================
# Private Link Service Configuration
# =============================================================================

variable "pls_name" {
  description = "Name of the Private Link Service"
  type        = string
  default     = "pls-confluent-transit"
}

variable "pls_nat_ip_count" {
  description = "Number of NAT IPs for Private Link Service (for scale)"
  type        = number
  default     = 1

  validation {
    condition     = var.pls_nat_ip_count >= 1 && var.pls_nat_ip_count <= 8
    error_message = "NAT IP count must be between 1 and 8."
  }
}

variable "pls_auto_approval_subscription_ids" {
  description = "List of subscription IDs to auto-approve PE connections (empty = manual approval)"
  type        = list(string)
  default     = []
}

variable "pls_visibility_subscription_ids" {
  description = "List of subscription IDs that can see this PLS (empty = all)"
  type        = list(string)
  default     = []
}

variable "enable_proxy_protocol" {
  description = "Enable proxy protocol on Private Link Service"
  type        = bool
  default     = false
}

# =============================================================================
# Private Endpoint Configuration
# =============================================================================

variable "pe_name" {
  description = "Name of the Private Endpoint to Confluent Cloud"
  type        = string
  default     = "pe-confluent-kafka"
}

variable "pe_request_message" {
  description = "Message to include with Private Endpoint connection request to Confluent"
  type        = string
  default     = "Databricks serverless connectivity via transit architecture"
}

# =============================================================================
# Naming and Tagging
# =============================================================================

variable "name_prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
