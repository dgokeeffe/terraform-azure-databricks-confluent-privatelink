# =============================================================================
# Required: location & target
# =============================================================================

variable "region" {
  description = <<-EOT
    Azure region short name (e.g. "australiaeast", "westus2"). Used three ways:
    - the location of the private endpoint and DNS resources,
    - the `<region>.service-direct` private-DNS A-record name, and
    - the `region` field of the databricks_endpoint registration.
  EOT
  type        = string
}

variable "resource_group_name" {
  description = "Resource group that will hold the private endpoint (and the private DNS zone, if this module creates it)."
  type        = string
}

variable "private_endpoint_subnet_id" {
  description = "Resource ID of the subnet that will host the private endpoint. Must have private-endpoint network policies disabled (the Azure default) and be different from the workspace's own subnets if you reuse the workspace VNet."
  type        = string
}

variable "databricks_pls_resource_id" {
  description = <<-EOT
    The Databricks-published Private Link Service resource ID for
    performance-intensive services in your region. Pull the current value from
    the Microsoft Learn region table (Service-direct resource IDs) — these are
    per-region and managed by Databricks, so do NOT hard-code them long-term:
    https://learn.microsoft.com/en-us/azure/databricks/resources/ip-domain-region#service-direct-resource-ids
  EOT
  type        = string
}

# =============================================================================
# Required when registering on the Databricks account side
# =============================================================================

variable "databricks_account_id" {
  description = "Databricks account ID (UUID). Required when register_with_databricks = true. The databricks provider must be configured at ACCOUNT level."
  type        = string
  default     = ""

  validation {
    condition     = var.databricks_account_id == "" || can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.databricks_account_id))
    error_message = "databricks_account_id must be a valid UUID or an empty string."
  }
}

variable "register_with_databricks" {
  description = "Create the databricks_endpoint resource that registers the private endpoint on the account side (PENDING -> APPROVED). Set false to manage only the Azure side."
  type        = bool
  default     = true
}

# =============================================================================
# Naming
# =============================================================================

variable "name_prefix" {
  description = "Optional prefix prepended to created resource names."
  type        = string
  default     = ""
}

variable "private_endpoint_name" {
  description = "Name of the Azure private endpoint."
  type        = string
  default     = "pe-service-direct"
}

variable "private_service_connection_name" {
  description = "Name of the private_service_connection block on the private endpoint."
  type        = string
  default     = "service-direct-psc"
}

variable "subresource_name" {
  description = <<-EOT
    Target sub-resource (group ID) for the private endpoint connection. Per
    Microsoft Learn this is `service_direct` (underscore). Exposed as a variable
    only so it can be overridden if Databricks changes the published group ID
    during Public Preview.
  EOT
  type        = string
  default     = "service_direct"
}

variable "endpoint_display_name" {
  description = "Display name for the databricks_endpoint registration. Must conform to RFC-1034 (letters, numbers, hyphens; starts with a letter; <= 63 chars)."
  type        = string
  default     = "service-direct-pe"

  validation {
    condition     = can(regex("^[a-zA-Z]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$", var.endpoint_display_name))
    error_message = "endpoint_display_name must be RFC-1034 compliant: start with a letter, contain only letters/numbers/hyphens, end with a letter or number, max 63 chars."
  }
}

variable "request_message" {
  description = "Request message attached to the manual private-endpoint connection."
  type        = string
  default     = "Databricks service-direct private endpoint (performance-intensive services)"
}

# =============================================================================
# DNS
# =============================================================================

variable "create_private_dns_zone" {
  description = "Whether to create the privatelink.azuredatabricks.net private DNS zone. Set false to reuse an existing zone (common when the workspace already uses inbound Private Link); the A record is added to the existing zone."
  type        = bool
  default     = true
}

variable "private_dns_zone_name" {
  description = "Name of the private DNS zone. service-direct shares the workspace front-end Private Link zone."
  type        = string
  default     = "privatelink.azuredatabricks.net"
}

variable "private_dns_zone_resource_group_name" {
  description = "Resource group of the private DNS zone. Defaults to resource_group_name when null."
  type        = string
  default     = null
}

variable "vnet_ids_to_link" {
  description = "VNet IDs to link to the private DNS zone (only used when create_private_dns_zone = true). When reusing an existing zone, manage links separately."
  type        = list(string)
  default     = []
}

variable "vnet_link_names" {
  description = "Optional names for the VNet links, positionally matched to vnet_ids_to_link. Falls back to link-<index> when shorter."
  type        = list(string)
  default     = []
}

variable "dns_a_record_ttl" {
  description = "TTL (seconds) for the <region>.service-direct A record."
  type        = number
  default     = 3600
}

# =============================================================================
# Misc
# =============================================================================

variable "tags" {
  description = "Tags applied to all created resources."
  type        = map(string)
  default     = {}
}
