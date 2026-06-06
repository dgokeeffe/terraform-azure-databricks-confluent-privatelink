variable "azure_subscription_id" {
  description = "Azure subscription ID to deploy into."
  type        = string
}

variable "region" {
  description = "Azure region short name (e.g. australiaeast). Must match your workspace region."
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group to create for the private endpoint and DNS zone."
  type        = string
  default     = "rg-service-direct-pe"
}

variable "private_endpoint_subnet_id" {
  description = "Resource ID of an existing subnet to host the private endpoint (PE network policies disabled)."
  type        = string
}

variable "databricks_pls_resource_id" {
  description = "Databricks per-region PLS resource ID for performance-intensive services (from the MS Learn region table)."
  type        = string
}

variable "databricks_account_id" {
  description = "Databricks account ID (UUID)."
  type        = string
}

variable "create_private_dns_zone" {
  description = "Create privatelink.azuredatabricks.net here, or reuse an existing zone."
  type        = bool
  default     = true
}

variable "vnet_ids_to_link" {
  description = "VNet IDs to link to the DNS zone (used only when create_private_dns_zone = true)."
  type        = list(string)
  default     = []
}

variable "vnet_link_names" {
  description = "Optional names for the VNet links, positionally matched to vnet_ids_to_link."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to created resources."
  type        = map(string)
  default     = {}
}
