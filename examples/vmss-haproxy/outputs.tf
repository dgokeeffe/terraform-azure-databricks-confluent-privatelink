# =============================================================================
# Transit infrastructure outputs
# =============================================================================

output "vnet_id" {
  description = "Transit VNet resource ID"
  value       = module.confluent_transit.vnet_id
}

output "lb_frontend_ip" {
  description = "Load Balancer frontend IP (DNS target)"
  value       = module.confluent_transit.lb_frontend_ip
}

output "pls_id" {
  description = "Private Link Service resource ID"
  value       = module.confluent_transit.pls_id
}

output "pls_alias" {
  description = "Private Link Service alias"
  value       = module.confluent_transit.pls_alias
}

output "vmss_id" {
  description = "VMSS resource ID"
  value       = module.confluent_transit.vmss_id
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
  description = "NCC Private Endpoint Rule connection state"
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
