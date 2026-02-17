# =============================================================================
# VNet Outputs
# =============================================================================

output "vnet_id" {
  description = "Transit VNet resource ID"
  value       = var.create_vnet ? azurerm_virtual_network.transit[0].id : var.existing_vnet_id
}

output "vnet_name" {
  description = "Transit VNet name"
  value       = var.create_vnet ? azurerm_virtual_network.transit[0].name : var.vnet_name
}

output "lb_subnet_id" {
  description = "Load Balancer subnet ID"
  value       = local.lb_subnet_id
}

output "pe_subnet_id" {
  description = "Private Endpoint subnet ID"
  value       = local.pe_subnet_id
}

# =============================================================================
# Confluent Private Endpoint Outputs
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
# Load Balancer Outputs
# =============================================================================

output "lb_id" {
  description = "Load Balancer resource ID"
  value       = azurerm_lb.transit.id
}

output "lb_name" {
  description = "Load Balancer name"
  value       = azurerm_lb.transit.name
}

output "lb_frontend_ip" {
  description = "Load Balancer frontend private IP"
  value       = azurerm_lb.transit.frontend_ip_configuration[0].private_ip_address
}

output "lb_frontend_ip_configuration_id" {
  description = "Load Balancer frontend IP configuration ID"
  value       = azurerm_lb.transit.frontend_ip_configuration[0].id
}

output "lb_backend_pool_id" {
  description = "Load Balancer backend pool ID"
  value       = azurerm_lb_backend_address_pool.confluent.id
}

output "lb_probe_ids" {
  description = "Load Balancer health probe IDs"
  value       = { for k, v in azurerm_lb_probe.kafka : k => v.id }
}

output "lb_rule_ids" {
  description = "Load Balancer rule IDs"
  value       = { for k, v in azurerm_lb_rule.kafka : k => v.id }
}

# =============================================================================
# Private Link Service Outputs
# =============================================================================

output "pls_id" {
  description = "Private Link Service resource ID - use this in Databricks NCC"
  value       = azurerm_private_link_service.transit.id
}

output "pls_name" {
  description = "Private Link Service name"
  value       = azurerm_private_link_service.transit.name
}

output "pls_alias" {
  description = "Private Link Service alias - can be shared with other teams"
  value       = azurerm_private_link_service.transit.alias
}

output "pls_nat_ips" {
  description = "Private Link Service NAT IPs"
  value = [
    for nat in azurerm_private_link_service.transit.nat_ip_configuration : nat.private_ip_address
  ]
}

# =============================================================================
# Databricks NCC Configuration Helper
# =============================================================================

output "databricks_ncc_config" {
  description = "Configuration values needed for Databricks NCC Private Endpoint Rule"
  value = {
    resource_id = azurerm_private_link_service.transit.id
    group_id    = "confluent-kafka"
    description = "Use these values when creating databricks_mws_ncc_private_endpoint_rule"
  }
}

# =============================================================================
# Connection Summary
# =============================================================================

output "connection_summary" {
  description = "Summary of the transit architecture components"
  value = {
    architecture = "Databricks Serverless -> NCC PE -> PLS -> LB -> Confluent PE -> Confluent Cloud"

    confluent_pe = {
      name   = azurerm_private_endpoint.confluent.name
      ip     = azurerm_private_endpoint.confluent.private_service_connection[0].private_ip_address
      status = "Approve in Confluent Cloud Console"
    }

    load_balancer = {
      name        = azurerm_lb.transit.name
      frontend_ip = azurerm_lb.transit.frontend_ip_configuration[0].private_ip_address
      ports       = local.all_kafka_ports
    }

    private_link_service = {
      name  = azurerm_private_link_service.transit.name
      id    = azurerm_private_link_service.transit.id
      alias = azurerm_private_link_service.transit.alias
    }

    next_steps = [
      "1. Approve PE connection in Confluent Cloud Console",
      "2. Create Databricks NCC using databricks-ncc-confluent module",
      "3. Verify NCC PE status is ESTABLISHED",
      "4. Test Kafka connectivity from serverless compute"
    ]
  }
}

# =============================================================================
# DNS Target
# =============================================================================

output "kafka_bootstrap_target_ip" {
  description = "IP address that Kafka bootstrap server FQDNs should resolve to"
  value       = azurerm_lb.transit.frontend_ip_configuration[0].private_ip_address
}
