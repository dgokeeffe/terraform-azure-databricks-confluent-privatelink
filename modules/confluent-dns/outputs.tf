# =============================================================================
# DNS Zone Outputs
# =============================================================================

output "dns_zone_id" {
  description = "Private DNS Zone resource ID"
  value       = azurerm_private_dns_zone.confluent.id
}

output "dns_zone_name" {
  description = "Private DNS Zone name"
  value       = azurerm_private_dns_zone.confluent.name
}

# =============================================================================
# DNS Record Outputs
# =============================================================================

output "bootstrap_fqdn" {
  description = "Bootstrap server FQDN"
  value       = "${azurerm_private_dns_a_record.bootstrap.name}.${azurerm_private_dns_zone.confluent.name}"
}

output "bootstrap_record" {
  description = "Bootstrap DNS record details"
  value = {
    name    = azurerm_private_dns_a_record.bootstrap.name
    fqdn    = azurerm_private_dns_a_record.bootstrap.fqdn
    records = azurerm_private_dns_a_record.bootstrap.records
    ttl     = azurerm_private_dns_a_record.bootstrap.ttl
  }
}

output "broker_fqdns" {
  description = "List of broker FQDNs"
  value = [
    for broker in azurerm_private_dns_a_record.brokers :
    "${broker.name}.${azurerm_private_dns_zone.confluent.name}"
  ]
}

output "wildcard_record" {
  description = "Wildcard DNS record details"
  value = {
    name    = azurerm_private_dns_a_record.wildcard.name
    fqdn    = azurerm_private_dns_a_record.wildcard.fqdn
    records = azurerm_private_dns_a_record.wildcard.records
    ttl     = azurerm_private_dns_a_record.wildcard.ttl
  }
}

# =============================================================================
# VNet Link Outputs
# =============================================================================

output "vnet_link_ids" {
  description = "VNet link resource IDs"
  value       = [for link in azurerm_private_dns_zone_virtual_network_link.confluent : link.id]
}

output "vnet_link_names" {
  description = "VNet link names"
  value       = [for link in azurerm_private_dns_zone_virtual_network_link.confluent : link.name]
}

# =============================================================================
# Connection String
# =============================================================================

output "kafka_connection_string" {
  description = "Kafka bootstrap server connection string"
  value       = "${azurerm_private_dns_a_record.bootstrap.name}.${azurerm_private_dns_zone.confluent.name}:9092"
}

# =============================================================================
# DNS Summary
# =============================================================================

output "dns_records_summary" {
  description = "Summary of all DNS records created"
  value = {
    zone      = azurerm_private_dns_zone.confluent.name
    target_ip = var.target_ip
    records = {
      bootstrap = "${azurerm_private_dns_a_record.bootstrap.name}.${azurerm_private_dns_zone.confluent.name}"
      wildcard  = "${azurerm_private_dns_a_record.wildcard.name}.${azurerm_private_dns_zone.confluent.name}"
      brokers   = [for b in azurerm_private_dns_a_record.brokers : "${b.name}.${azurerm_private_dns_zone.confluent.name}"]
    }
    vnet_links = [for link in azurerm_private_dns_zone_virtual_network_link.confluent : link.name]
  }
}
