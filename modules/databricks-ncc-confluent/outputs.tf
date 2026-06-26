# =============================================================================
# NCC outputs
# =============================================================================

output "ncc_id" {
  description = "Network Connectivity Configuration ID"
  value       = databricks_mws_network_connectivity_config.confluent.network_connectivity_config_id
}

output "ncc_name" {
  description = "Network Connectivity Configuration name"
  value       = databricks_mws_network_connectivity_config.confluent.name
}

# =============================================================================
# Private Endpoint Rule outputs
# =============================================================================

output "pe_rule_id" {
  description = "Private Endpoint Rule ID"
  value       = "managed-via-rest-api"
}

output "pe_rule_connection_state" {
  description = "Private Endpoint Rule connection state"
  value       = "check-account-console"
}

output "domain_names" {
  description = "Domain names configured for DNS interception"
  value       = local.all_domain_names
}

# =============================================================================
# Workspace binding outputs
# =============================================================================

output "workspace_bindings" {
  description = "Workspace IDs bound to this NCC"
  value       = [for b in databricks_mws_ncc_binding.confluent : b.workspace_id]
}

# =============================================================================
# Kafka connection string
# =============================================================================

output "kafka_bootstrap_servers" {
  description = "Kafka bootstrap servers connection string for Spark"
  value       = var.confluent_bootstrap_servers
}

# =============================================================================
# Connection summary
# =============================================================================

output "connection_summary" {
  description = "Summary of NCC configuration"
  value = {
    ncc_id           = databricks_mws_network_connectivity_config.confluent.network_connectivity_config_id
    ncc_name         = databricks_mws_network_connectivity_config.confluent.name
    region           = var.region
    transit_mode     = "appgw"
    pe_rule_id       = "managed-via-rest-api"
    connection_state = "check-account-console"
    domain_names     = local.all_domain_names
    workspaces       = [for b in databricks_mws_ncc_binding.confluent : b.workspace_id]
    bootstrap_server = var.confluent_bootstrap_servers
  }
}

# =============================================================================
# Spark configuration helper
# =============================================================================

output "spark_kafka_options" {
  description = "Spark DataFrame options for reading from Kafka"
  value = {
    "kafka.bootstrap.servers" = var.confluent_bootstrap_servers
    "kafka.security.protocol" = "SASL_SSL"
    "kafka.sasl.mechanism"    = "PLAIN"
    "kafka.sasl.jaas.config"  = "org.apache.kafka.common.security.plain.PlainLoginModule required username='<API_KEY>' password='<API_SECRET>';"
  }
  sensitive = false
}
