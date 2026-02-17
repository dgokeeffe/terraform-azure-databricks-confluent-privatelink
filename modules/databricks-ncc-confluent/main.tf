# =============================================================================
# Local Variables
# =============================================================================

locals {
  # Build Confluent FQDNs for DNS interception
  bootstrap_fqdn = "${var.confluent_cluster_id}.${var.confluent_region}.azure.confluent.cloud"
  wildcard_fqdn  = "*.${var.confluent_cluster_id}.${var.confluent_region}.azure.confluent.cloud"

  # Combine all domain names
  all_domain_names = distinct(concat(
    [local.bootstrap_fqdn, local.wildcard_fqdn],
    var.additional_domain_names
  ))
}

# =============================================================================
# Network Connectivity Configuration
# =============================================================================

resource "databricks_mws_network_connectivity_config" "confluent" {
  name   = var.ncc_name
  region = var.region
}

# =============================================================================
# Private Endpoint Rule
# =============================================================================

resource "databricks_mws_ncc_private_endpoint_rule" "confluent" {
  network_connectivity_config_id = databricks_mws_network_connectivity_config.confluent.network_connectivity_config_id
  resource_id                    = var.private_link_service_id
  group_id                       = var.group_id

  # Domain names for DNS interception - these tell serverless compute
  # to route traffic for these domains through the private endpoint
  domain_names = local.all_domain_names
}

# Wait for PE rule to be created before attempting approval
resource "time_sleep" "wait_for_pe_rule" {
  depends_on = [databricks_mws_ncc_private_endpoint_rule.confluent]

  create_duration = "60s"
}

# =============================================================================
# Auto-approve PE connection on Private Link Service
# =============================================================================

resource "null_resource" "approve_databricks_pe" {
  count = var.auto_approve_pe ? 1 : 0

  depends_on = [time_sleep.wait_for_pe_rule]

  triggers = {
    pe_rule_id = databricks_mws_ncc_private_endpoint_rule.confluent.rule_id
  }

  provisioner "local-exec" {
    command = <<-EOT
      #!/bin/bash
      set -e

      echo "Checking for pending Private Endpoint connections on ${var.pls_name}..."

      # Wait a bit for the PE to appear
      sleep 10

      # Get pending connections
      PENDING_CONNECTIONS=$(az network private-link-service show \
        --name "${var.pls_name}" \
        --resource-group "${var.pls_resource_group_name}" \
        --query "privateEndpointConnections[?privateLinkServiceConnectionState.status=='Pending'].name" \
        -o tsv 2>/dev/null || echo "")

      if [ -z "$PENDING_CONNECTIONS" ]; then
        echo "No pending connections found. Connection may already be approved or still propagating."

        # Check if there are any established connections
        ESTABLISHED=$(az network private-link-service show \
          --name "${var.pls_name}" \
          --resource-group "${var.pls_resource_group_name}" \
          --query "privateEndpointConnections[?privateLinkServiceConnectionState.status=='Approved'].name" \
          -o tsv 2>/dev/null || echo "")

        if [ -n "$ESTABLISHED" ]; then
          echo "Found established connections: $ESTABLISHED"
        fi
        exit 0
      fi

      echo "Found pending connections: $PENDING_CONNECTIONS"

      # Approve each pending connection
      for CONN in $PENDING_CONNECTIONS; do
        echo "Approving connection: $CONN"
        az network private-link-service connection update \
          --name "$CONN" \
          --service-name "${var.pls_name}" \
          --resource-group "${var.pls_resource_group_name}" \
          --connection-status Approved \
          --description "Auto-approved by Terraform for Databricks NCC" \
          2>/dev/null || echo "Warning: Could not approve $CONN - may already be approved"
      done

      echo "PE approval process completed."
    EOT

    interpreter = ["bash", "-c"]
  }
}

# =============================================================================
# Workspace Bindings
# =============================================================================

resource "databricks_mws_network_connectivity_config_workspace_binding" "confluent" {
  for_each = toset(var.workspace_ids)

  network_connectivity_config_id = databricks_mws_network_connectivity_config.confluent.network_connectivity_config_id
  workspace_id                   = each.value

  depends_on = [null_resource.approve_databricks_pe]
}

# Wait for bindings to propagate
resource "time_sleep" "wait_for_binding" {
  depends_on = [databricks_mws_network_connectivity_config_workspace_binding.confluent]

  create_duration = "30s"
}
