# =============================================================================
# Transit Infrastructure Outputs
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

output "confluent_pe_ip" {
  description = "Confluent Private Endpoint IP"
  value       = module.confluent_transit.confluent_pe_ip
}

# =============================================================================
# Databricks NCC Outputs
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
# Kafka Connection
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
# DNS Outputs (if enabled)
# =============================================================================

output "dns_zone_id" {
  description = "Private DNS Zone ID (if enabled)"
  value       = var.enable_dns_zone ? module.confluent_dns[0].dns_zone_id : null
}

output "dns_zone_name" {
  description = "Private DNS Zone name (if enabled)"
  value       = var.enable_dns_zone ? module.confluent_dns[0].dns_zone_name : null
}

# =============================================================================
# Next Steps
# =============================================================================

output "next_steps" {
  description = "Manual steps required after Terraform apply"
  value       = <<-EOT

    ============================================================
    NEXT STEPS - Complete these manual actions:
    ============================================================

    1. APPROVE CONFLUENT PE CONNECTION
       - Go to Confluent Cloud Console
       - Navigate to: Cluster -> Settings -> Networking -> Private Link
       - Find pending connection from: ${module.confluent_transit.confluent_pe_name}
       - Click "Approve"

    2. VERIFY NCC STATUS
       - Go to Databricks Account Console
       - Navigate to: Security -> Network Connectivity Configurations
       - Select: ${module.databricks_ncc.ncc_name}
       - Verify PE rule status is "ESTABLISHED"

    3. TEST KAFKA CONNECTIVITY
       Run this in a serverless notebook:

       ```python
       df = spark.read \
         .format("kafka") \
         .option("kafka.bootstrap.servers", "${module.databricks_ncc.kafka_bootstrap_servers}") \
         .option("subscribe", "your-topic-name") \
         .option("kafka.security.protocol", "SASL_SSL") \
         .option("kafka.sasl.mechanism", "PLAIN") \
         .option("kafka.sasl.jaas.config",
                 "org.apache.kafka.common.security.plain.PlainLoginModule required " +
                 "username='<YOUR_API_KEY>' password='<YOUR_API_SECRET>';") \
         .option("startingOffsets", "earliest") \
         .option("maxOffsetsPerTrigger", 100) \
         .load()

       display(df.selectExpr("CAST(key AS STRING)", "CAST(value AS STRING)"))
       ```

    ============================================================
  EOT
}
