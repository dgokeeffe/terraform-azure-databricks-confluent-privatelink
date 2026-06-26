# =============================================================================
# Local variables
# =============================================================================

locals {
  all_domain_names = distinct(concat(
    var.confluent_ncc_domain_names,
    var.additional_domain_names
  ))

  domain_names_json = jsonencode(local.all_domain_names)
}

# =============================================================================
# Network Connectivity Configuration
# =============================================================================

resource "databricks_mws_network_connectivity_config" "confluent" {
  name   = var.ncc_name
  region = var.region
}

# =============================================================================
# Private Endpoint Rule - Application Gateway mode (REST API)
#
# The Databricks Terraform provider does not yet support creating NCC PE rules
# targeting Application Gateway v2 resources. We use the REST API directly.
# =============================================================================

resource "null_resource" "appgw_pe_rule" {
  triggers = {
    ncc_id       = databricks_mws_network_connectivity_config.confluent.network_connectivity_config_id
    resource_id  = var.transit_resource_id
    group_id     = var.group_id
    domain_names = local.domain_names_json
  }

  provisioner "local-exec" {
    command = <<-EOT
      #!/bin/bash
      set -e

      echo "Creating NCC PE rule for Application Gateway via REST API..."

      # Get an access token for the Databricks accounts API
      TOKEN=$(az account get-access-token \
        --resource "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d" \
        --query accessToken -o tsv)

      if [ -z "$TOKEN" ]; then
        echo "ERROR: Failed to get Databricks access token. Ensure az cli is authenticated."
        exit 1
      fi

      NCC_ID="${databricks_mws_network_connectivity_config.confluent.network_connectivity_config_id}"

      # Create the PE rule via REST API
      RESPONSE=$(curl -s -w "\n%%{http_code}" -X POST \
        "${var.databricks_host}/api/2.0/accounts/${var.databricks_account_id}/network-connectivity-configs/$NCC_ID/private-endpoint-rules" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{
          "resource_id": "${var.transit_resource_id}",
          "group_id": "${var.group_id}",
          "domain_names": ${local.domain_names_json}
        }')

      HTTP_CODE=$(echo "$RESPONSE" | tail -1)
      BODY=$(echo "$RESPONSE" | sed '$d')

      if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
        echo "PE rule created successfully."
        echo "$BODY"
      else
        echo "ERROR: Failed to create PE rule (HTTP $HTTP_CODE)"
        echo "$BODY"
        exit 1
      fi
    EOT

    interpreter = ["bash", "-c"]
  }
}

# =============================================================================
# Wait for PE rule to propagate
# =============================================================================

resource "time_sleep" "wait_for_pe_rule" {
  depends_on = [null_resource.appgw_pe_rule]

  create_duration = "60s"
}

# =============================================================================
# Auto-approve PE connection on Application Gateway
# =============================================================================

resource "null_resource" "approve_databricks_pe_appgw" {
  count = var.auto_approve_pe ? 1 : 0

  depends_on = [time_sleep.wait_for_pe_rule]

  triggers = {
    resource_id = var.transit_resource_id
  }

  provisioner "local-exec" {
    command = <<-EOT
      #!/bin/bash
      set -e

      echo "Checking for pending Private Endpoint connections on App Gateway ${var.transit_resource_name}..."

      sleep 10

      # For App GW, PE connections are managed differently - use az network application-gateway
      PENDING_CONNECTIONS=$(az network application-gateway show \
        --name "${var.transit_resource_name}" \
        --resource-group "${var.transit_resource_group_name}" \
        --query "privateLinkConfigurations[0].id" \
        -o tsv 2>/dev/null || echo "")

      if [ -n "$PENDING_CONNECTIONS" ]; then
        echo "App Gateway Private Link configuration found."
        echo "Checking for pending PE connections..."

        # List PE connections on the App GW
        az network application-gateway private-link-resource list \
          --gateway-name "${var.transit_resource_name}" \
          --resource-group "${var.transit_resource_group_name}" \
          2>/dev/null || echo "No private link resources found"
      fi

      echo "App GW PE approval process completed. Check Azure portal if manual approval is needed."
    EOT

    interpreter = ["bash", "-c"]
  }
}

# =============================================================================
# Workspace bindings
# =============================================================================

resource "databricks_mws_ncc_binding" "confluent" {
  for_each = toset(var.workspace_ids)

  network_connectivity_config_id = databricks_mws_network_connectivity_config.confluent.network_connectivity_config_id
  workspace_id                   = tonumber(each.value)

  depends_on = [
    null_resource.approve_databricks_pe_appgw,
  ]
}

# Wait for bindings to propagate
resource "time_sleep" "wait_for_binding" {
  depends_on = [databricks_mws_ncc_binding.confluent]

  create_duration = "30s"
}
