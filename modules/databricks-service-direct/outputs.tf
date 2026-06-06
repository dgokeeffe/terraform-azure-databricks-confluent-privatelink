# =============================================================================
# Azure private endpoint
# =============================================================================

output "private_endpoint_id" {
  description = "Resource ID of the Azure private endpoint."
  value       = azurerm_private_endpoint.this.id
}

output "private_endpoint_name" {
  description = "Name of the Azure private endpoint."
  value       = azurerm_private_endpoint.this.name
}

output "private_endpoint_resource_guid" {
  description = "properties.resourceGuid of the private endpoint (read via azapi; consumed by the account-side registration)."
  value       = local.pe_resource_guid
}

output "private_ip_address" {
  description = "Private IP assigned to the private endpoint."
  value       = local.pe_private_ip
}

# =============================================================================
# DNS
# =============================================================================

output "dns_fqdn" {
  description = "Resolvable FQDN clients use for service-direct."
  value       = "${local.a_record_name}.${var.private_dns_zone_name}"
}

output "dns_zone_name" {
  description = "Private DNS zone holding the service-direct A record."
  value       = var.private_dns_zone_name
}

# =============================================================================
# Account-side registration
# =============================================================================

output "endpoint_id" {
  description = "Databricks endpoint_id of the registration (null when register_with_databricks = false)."
  value       = var.register_with_databricks ? databricks_endpoint.this[0].endpoint_id : null
}

output "endpoint_state" {
  description = "State of the registered endpoint. Must be APPROVED to be usable. (null when not registered.)"
  value       = var.register_with_databricks ? databricks_endpoint.this[0].state : null
}

output "endpoint_use_case" {
  description = "use_case of the registered endpoint — expected SERVICE_DIRECT. (null when not registered.)"
  value       = var.register_with_databricks ? databricks_endpoint.this[0].use_case : null
}

# =============================================================================
# Summary
# =============================================================================

output "connection_summary" {
  description = "Summary of the service-direct configuration."
  value = {
    region                = var.region
    private_endpoint_name = azurerm_private_endpoint.this.name
    private_ip_address    = local.pe_private_ip
    dns_fqdn              = "${local.a_record_name}.${var.private_dns_zone_name}"
    registered            = var.register_with_databricks
    endpoint_state        = var.register_with_databricks ? databricks_endpoint.this[0].state : "not-registered"
    use_case              = var.register_with_databricks ? databricks_endpoint.this[0].use_case : "not-registered"
  }
}
