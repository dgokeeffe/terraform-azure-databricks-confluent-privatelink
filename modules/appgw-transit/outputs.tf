# =============================================================================
# VNet outputs
# =============================================================================

output "vnet_id" {
  description = "Transit VNet resource ID"
  value       = var.create_vnet ? azurerm_virtual_network.transit[0].id : var.existing_vnet_id
}

output "vnet_name" {
  description = "Transit VNet name"
  value       = var.create_vnet ? azurerm_virtual_network.transit[0].name : var.vnet_name
}

# =============================================================================
# Confluent Private Endpoint outputs
# =============================================================================

output "confluent_pe_id" {
  description = "Confluent Private Endpoint resource ID"
  value       = azurerm_private_endpoint.confluent.id
}

output "confluent_pe_name" {
  description = "Confluent Private Endpoint name"
  value       = azurerm_private_endpoint.confluent.name
}

output "confluent_pe_ip" {
  description = "Confluent Private Endpoint private IP address"
  value       = azurerm_private_endpoint.confluent.private_service_connection[0].private_ip_address
}

# =============================================================================
# Application Gateway outputs
# =============================================================================

output "appgw_id" {
  description = "Application Gateway resource ID - use this in Databricks NCC"
  value       = azapi_resource.appgw.id
}

output "appgw_name" {
  description = "Application Gateway name"
  value       = azapi_resource.appgw.name
}

output "frontend_ip" {
  description = "Application Gateway frontend private IP"
  value       = try(azapi_resource.appgw.output.properties.frontendIPConfigurations[0].properties.privateIPAddress, "dynamic - check Azure portal")
}

# =============================================================================
# DNS target
# =============================================================================

output "kafka_bootstrap_target_ip" {
  description = "IP address that Kafka bootstrap server FQDNs should resolve to (App GW frontend)"
  value       = try(azapi_resource.appgw.output.properties.frontendIPConfigurations[0].properties.privateIPAddress, "dynamic - check Azure portal")
}

# =============================================================================
# Connection summary
# =============================================================================

output "connection_summary" {
  description = "Summary of the transit architecture components"
  value = {
    architecture = "Databricks Serverless -> NCC PE -> App GW v2 (TCP proxy) -> Confluent PE -> Confluent Cloud"

    confluent_pe = {
      name   = azurerm_private_endpoint.confluent.name
      ip     = azurerm_private_endpoint.confluent.private_service_connection[0].private_ip_address
      status = "Approve in Confluent Cloud Console"
    }

    application_gateway = {
      name = azapi_resource.appgw.name
      id   = azapi_resource.appgw.id
      note = "TCP proxy is in preview - requires API version 2024-05-01+"
    }

    next_steps = [
      "1. Approve PE connection in Confluent Cloud Console",
      "2. Create Databricks NCC using databricks-ncc-confluent module with transit_mode = appgw",
      "3. Verify NCC PE status is ESTABLISHED",
      "4. Test Kafka connectivity from serverless compute"
    ]
  }
}
