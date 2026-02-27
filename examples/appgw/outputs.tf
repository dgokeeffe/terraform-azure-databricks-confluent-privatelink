# =============================================================================
# Transit infrastructure outputs
# =============================================================================

output "vnet_id" {
  description = "Transit VNet resource ID"
  value       = module.confluent_transit.vnet_id
}

output "appgw_id" {
  description = "Application Gateway resource ID"
  value       = module.confluent_transit.appgw_id
}

output "frontend_ip" {
  description = "App Gateway frontend IP (DNS target)"
  value       = module.confluent_transit.frontend_ip
}

output "confluent_pe_ip" {
  description = "Confluent Private Endpoint IP"
  value       = module.confluent_transit.confluent_pe_ip
}

# =============================================================================
# Databricks NCC outputs
# =============================================================================

output "ncc_id" {
  description = "Databricks NCC ID"
  value       = module.databricks_ncc.ncc_id
}

output "ncc_name" {
  description = "Databricks NCC name"
  value       = module.databricks_ncc.ncc_name
}

output "pe_rule_connection_state" {
  description = "NCC PE Rule connection state (check account console for appgw mode)"
  value       = module.databricks_ncc.pe_rule_connection_state
}

output "workspace_bindings" {
  description = "Workspaces bound to the NCC"
  value       = module.databricks_ncc.workspace_bindings
}

# =============================================================================
# Kafka connection
# =============================================================================

output "kafka_bootstrap_servers" {
  description = "Kafka bootstrap servers for Spark jobs"
  value       = module.databricks_ncc.kafka_bootstrap_servers
}

output "spark_kafka_options" {
  description = "Spark DataFrame options for Kafka (fill in API key/secret)"
  value       = module.databricks_ncc.spark_kafka_options
}

# =============================================================================
# DNS outputs (if enabled)
# =============================================================================

output "dns_zone_id" {
  description = "Private DNS Zone ID (if enabled)"
  value       = var.enable_dns_zone ? module.confluent_dns[0].dns_zone_id : null
}
