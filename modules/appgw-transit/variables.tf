# =============================================================================
# Required variables
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
# Network configuration
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

variable "appgw_subnet_name" {
  description = "Name of subnet for Application Gateway (requires /24 or larger)"
  type        = string
  default     = "snet-appgw"
}

variable "appgw_subnet_address_prefix" {
  description = "Address prefix for App Gateway subnet (if creating)"
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

variable "appgw_privatelink_subnet_name" {
  description = "Name of subnet for App Gateway Private Link configuration"
  type        = string
  default     = "snet-appgw-privatelink"
}

variable "appgw_privatelink_subnet_address_prefix" {
  description = "Address prefix for App Gateway Private Link subnet (if creating)"
  type        = string
  default     = "10.200.3.0/24"
}

variable "existing_appgw_subnet_id" {
  description = "Resource ID of existing App Gateway subnet (required if create_subnets = false)"
  type        = string
  default     = ""
}

variable "existing_pe_subnet_id" {
  description = "Resource ID of existing PE subnet (required if create_subnets = false)"
  type        = string
  default     = ""
}

variable "existing_appgw_privatelink_subnet_id" {
  description = "Resource ID of existing App Gateway Private Link subnet (required if create_subnets = false)"
  type        = string
  default     = ""
}

# =============================================================================
# Application Gateway configuration
# =============================================================================

variable "appgw_name" {
  description = "Name of the Application Gateway v2"
  type        = string
  default     = "appgw-confluent-transit"
}

variable "appgw_sku_capacity" {
  description = "App Gateway instance count (2+ for HA)"
  type        = number
  default     = 2

  validation {
    condition     = var.appgw_sku_capacity >= 1 && var.appgw_sku_capacity <= 10
    error_message = "App Gateway capacity must be between 1 and 10."
  }
}

variable "appgw_frontend_ip" {
  description = "Static private IP for App Gateway frontend (must be in appgw_subnet range). Leave empty for dynamic allocation."
  type        = string
  default     = ""
}

variable "kafka_port" {
  description = "Kafka broker port to proxy"
  type        = number
  default     = 9092
}

# =============================================================================
# Private Endpoint configuration
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
# Naming and tagging
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
