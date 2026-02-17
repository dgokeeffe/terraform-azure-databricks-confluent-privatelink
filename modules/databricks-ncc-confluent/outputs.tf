# =============================================================================
# NCC Outputs
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
# Private Endpoint Rule Outputs
# =============================================================================

output "pe_rule_id" {
  description = "Private Endpoint Rule ID"
  value       = databricks_mws_ncc_private_endpoint_rule.confluent.rule_id
}

output "pe_rule_connection_state" {
  description = "Private Endpoint Rule connection state"
  value       = databricks_mws_ncc_private_endpoint_rule.confluent.connection_state
}

output "domain_names" {
  description = "Domain names configured for DNS interception"
  value       = databricks_mws_ncc_private_endpoint_rule.confluent.domain_names
}

# =============================================================================
# Workspace Binding Outputs
# =============================================================================

output "workspace_bindings" {
  description = "Workspace IDs bound to this NCC"
  value       = [for b in databricks_mws_network_connectivity_config_workspace_binding.confluent : b.workspace_id]
}

# =============================================================================
# Kafka Connection String
# =============================================================================

output "kafka_bootstrap_servers" {
  description = "Kafka bootstrap servers connection string for Spark"
  value       = "${local.bootstrap_fqdn}:9092"
}

output "kafka_bootstrap_fqdn" {
  description = "Kafka bootstrap server FQDN (without port)"
  value       = local.bootstrap_fqdn
}

# =============================================================================
# Connection Summary
# =============================================================================

output "connection_summary" {
  description = "Summary of NCC configuration"
  value = {
    ncc_id           = databricks_mws_network_connectivity_config.confluent.network_connectivity_config_id
    ncc_name         = databricks_mws_network_connectivity_config.confluent.name
    region           = var.region
    pe_rule_id       = databricks_mws_ncc_private_endpoint_rule.confluent.rule_id
    connection_state = databricks_mws_ncc_private_endpoint_rule.confluent.connection_state
    domain_names     = databricks_mws_ncc_private_endpoint_rule.confluent.domain_names
    workspaces       = [for b in databricks_mws_network_connectivity_config_workspace_binding.confluent : b.workspace_id]
    bootstrap_server = "${local.bootstrap_fqdn}:9092"
  }
}

# =============================================================================
# Spark Configuration Helper
# =============================================================================

output "spark_kafka_options" {
  description = "Spark DataFrame options for reading from Kafka"
  value = {
    "kafka.bootstrap.servers" = "${local.bootstrap_fqdn}:9092"
    "kafka.security.protocol" = "SASL_SSL"
    "kafka.sasl.mechanism"    = "PLAIN"
    "kafka.sasl.jaas.config"  = "org.apache.kafka.common.security.plain.PlainLoginModule required username='<API_KEY>' password='<API_SECRET>';"
  }
  sensitive = false
}
