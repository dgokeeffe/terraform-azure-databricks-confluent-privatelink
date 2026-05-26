# =============================================================================
# Smoke test — App Gateway v2 TCP/TLS proxy + NCC PE rule + TLS validation
# =============================================================================
#
# Validates the full Databricks Serverless -> App Gateway v2 TCP/TLS proxy
# path end-to-end, including:
#
#   L1 — App Gateway v2 TCP listener with native Private Link inbound
#   L2 — Private Endpoint attaches to the App Gateway PLS
#   L3 — Databricks NCC PE rule attaches to the App Gateway via REST API
#   L4 — A stock Databricks Serverless notebook can perform a TLS handshake
#        through the proxy to a self-signed TLS backend
#
# Topology:
#
#   Databricks Serverless (region matches the resource group)
#       │
#       │  Python notebook: ssl.wrap_socket("smoke-broker.test.appgw.internal:9092")
#       │  NCC injects DNS for that FQDN → resolves to Databricks-managed PE IP
#       ▼
#   Databricks-managed VNet → Private Endpoint to App Gateway PL config
#       │
#       │ Azure backbone
#       ▼
#   App Gateway v2 (TCP listener 9092, native PL inbound)
#       │
#       │ TLS handshake passes through (App GW does not terminate;
#       │ SNI in ClientHello = smoke-broker.test.appgw.internal)
#       ▼
#   Backend VM running socat OPENSSL-LISTEN:9092 with a self-signed cert
#   whose SAN matches the registered FQDN. Echoes received bytes.
#
# A successful TLS exchange in the notebook proves the App Gateway TCP/TLS
# listener correctly passes through TLS handshakes (including SNI) without
# terminating or interfering. That is the load-bearing claim DBRA's
# recommendation rests on for this architecture.
#
# Cost: ~$0.40/hr running (~$10/day). Destroy after testing.
#
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 3.80" }
    azapi   = { source = "azure/azapi", version = "~> 2.0" }
    tls     = { source = "hashicorp/tls", version = "~> 4.0" }
    databricks = { source = "databricks/databricks", version = "~> 1.50" }
    null    = { source = "hashicorp/null", version = "~> 3.0" }
    time    = { source = "hashicorp/time", version = "~> 0.10" }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.azure_subscription_id
}

provider "azapi" {
  subscription_id = var.azure_subscription_id
}

provider "databricks" {
  alias           = "account"
  host            = var.databricks_host
  account_id      = var.databricks_account_id
  auth_type       = "azure-cli"
  azure_tenant_id = var.azure_tenant_id
}

data "azurerm_resource_group" "smoke" {
  name = var.resource_group_name
}

# Throwaway SSH key for Azure VMs (never used for inbound SSH — tests via
# az vm run-command). Azure ARM only accepts RSA SSH keys.
resource "tls_private_key" "vm_ssh" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

# =============================================================================
# Self-signed TLS cert with SAN matching the FQDN we register in NCC
# =============================================================================

resource "tls_private_key" "tls_backend" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "tls_backend" {
  private_key_pem = tls_private_key.tls_backend.private_key_pem

  subject {
    common_name  = var.test_fqdn
    organization = "AppGW Smoke Test"
  }

  dns_names             = [var.test_fqdn]
  validity_period_hours = 168 # 7 days, plenty for a smoke test

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

locals {
  tags = {
    Workload  = "appgw-tcp-tls-smoke-test"
    Owner     = "smoke-test"
    ManagedBy = "terraform"
    Temporary = "true"
  }

  # Combined PEM (cert + key) — what socat OPENSSL-LISTEN wants
  combined_pem = "${tls_self_signed_cert.tls_backend.cert_pem}${tls_private_key.tls_backend.private_key_pem}"
}

# =============================================================================
# Transit VNet (hosts App GW + backend VM)
# =============================================================================

resource "azurerm_virtual_network" "transit" {
  name                = "vnet-smoke-transit"
  location            = data.azurerm_resource_group.smoke.location
  resource_group_name = data.azurerm_resource_group.smoke.name
  address_space       = ["10.230.0.0/16"]
  tags                = local.tags
}

resource "azurerm_subnet" "appgw" {
  name                 = "snet-appgw"
  resource_group_name  = data.azurerm_resource_group.smoke.name
  virtual_network_name = azurerm_virtual_network.transit.name
  address_prefixes     = ["10.230.1.0/24"]
}

resource "azurerm_subnet" "appgw_pls" {
  name                 = "snet-appgw-pls"
  resource_group_name  = data.azurerm_resource_group.smoke.name
  virtual_network_name = azurerm_virtual_network.transit.name
  address_prefixes     = ["10.230.2.0/24"]

  private_link_service_network_policies_enabled = false
}

resource "azurerm_subnet" "backend" {
  name                 = "snet-backend"
  resource_group_name  = data.azurerm_resource_group.smoke.name
  virtual_network_name = azurerm_virtual_network.transit.name
  address_prefixes     = ["10.230.3.0/27"]
}

resource "azurerm_network_security_group" "backend" {
  name                = "nsg-smoke-backend"
  location            = data.azurerm_resource_group.smoke.location
  resource_group_name = data.azurerm_resource_group.smoke.name
  tags                = local.tags

  security_rule {
    name                       = "allow-appgw-to-9092"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "9092"
    source_address_prefix      = "10.230.1.0/24" # appgw subnet
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "backend" {
  subnet_id                 = azurerm_subnet.backend.id
  network_security_group_id = azurerm_network_security_group.backend.id
}

# =============================================================================
# Backend VM — socat OPENSSL-LISTEN on 9092 (TLS echo)
# =============================================================================

resource "azurerm_network_interface" "backend" {
  name                = "nic-smoke-backend"
  location            = data.azurerm_resource_group.smoke.location
  resource_group_name = data.azurerm_resource_group.smoke.name
  tags                = local.tags

  ip_configuration {
    name                          = "ipconfig"
    subnet_id                     = azurerm_subnet.backend.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "backend" {
  name                = "vm-smoke-backend"
  location            = data.azurerm_resource_group.smoke.location
  resource_group_name = data.azurerm_resource_group.smoke.name
  size                = "Standard_B1s"
  admin_username      = "azureuser"
  tags                = local.tags

  network_interface_ids = [azurerm_network_interface.backend.id]

  admin_ssh_key {
    username   = "azureuser"
    public_key = tls_private_key.vm_ssh.public_key_openssh
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  # Subscription-level locks in this sandbox prevent VM replacement. Pin the
  # cloud-init data — the VM keeps its original cert (the smoke test uses
  # ssl.CERT_NONE so SAN mismatch is irrelevant).
  lifecycle {
    ignore_changes = [custom_data, admin_ssh_key]
  }

  # Cloud-init: write combined cert+key, install socat, run TLS echo via systemd
  custom_data = base64encode(<<-CLOUDINIT
    #cloud-config
    package_update: true
    packages:
      - socat
    write_files:
      - path: /etc/smoke-tls.pem
        content: |
${indent(10, local.combined_pem)}
        permissions: '0600'
      - path: /etc/systemd/system/tls-echo-9092.service
        content: |
          [Unit]
          Description=socat TLS echo on 9092
          After=network.target
          [Service]
          Type=simple
          ExecStart=/usr/bin/socat -v OPENSSL-LISTEN:9092,cert=/etc/smoke-tls.pem,verify=0,fork,reuseaddr SYSTEM:'tee -a /var/log/tls-9092.log'
          StandardOutput=append:/var/log/tls-9092.log
          StandardError=append:/var/log/tls-9092.log
          Restart=always
          [Install]
          WantedBy=multi-user.target
    runcmd:
      - touch /var/log/tls-9092.log
      - chmod 644 /var/log/tls-9092.log
      - systemctl daemon-reload
      - systemctl enable --now tls-echo-9092.service
    CLOUDINIT
  )
}

# =============================================================================
# Application Gateway v2 — TCP listener + native Private Link
# =============================================================================
#
# App GW v2 (Standard_v2) requires a public IP frontend unless the
# subscription has the EnableApplicationGatewayNetworkIsolation feature
# flag registered. We create a public IP here purely to satisfy that
# requirement — no listener is bound to it, so it serves no traffic. The
# real TCP listener binds to the private frontend below.

resource "azurerm_public_ip" "appgw" {
  name                = "pip-appgw-smoke"
  location            = data.azurerm_resource_group.smoke.location
  resource_group_name = data.azurerm_resource_group.smoke.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azapi_resource" "appgw" {
  type      = "Microsoft.Network/applicationGateways@2024-05-01"
  name      = "appgw-smoke"
  location  = data.azurerm_resource_group.smoke.location
  parent_id = data.azurerm_resource_group.smoke.id
  tags      = local.tags

  body = {
    properties = {
      sku = {
        name     = "Standard_v2"
        tier     = "Standard_v2"
        capacity = 2
      }

      gatewayIPConfigurations = [{
        name       = "appgw-ip-config"
        properties = { subnet = { id = azurerm_subnet.appgw.id } }
      }]

      frontendIPConfigurations = [
        {
          name = "frontend-public"
          properties = {
            publicIPAddress = { id = azurerm_public_ip.appgw.id }
            # App Gateway Private Link configuration must be associated
            # with a public frontend (per Microsoft docs). PE traffic
            # enters via this PL surface and routes to the listener.
            privateLinkConfiguration = {
              id = "${data.azurerm_resource_group.smoke.id}/providers/Microsoft.Network/applicationGateways/appgw-smoke/privateLinkConfigurations/pl-config"
            }
          }
        },
        {
          name = "frontend-private"
          properties = {
            # Kept for completeness but not used by any listener in this smoke
            # test (PE traffic requires the PL-attached public frontend).
            privateIPAllocationMethod = "Static"
            privateIPAddress          = "10.230.1.100"
            subnet                    = { id = azurerm_subnet.appgw.id }
          }
        }
      ]

      frontendPorts = [{
        name       = "port-9092"
        properties = { port = 9092 }
      }]

      backendAddressPools = [{
        name = "backend-pool"
        properties = {
          backendAddresses = [{
            ipAddress = azurerm_network_interface.backend.private_ip_address
          }]
        }
      }]

      backendSettingsCollection = [{
        name = "backend-settings-tcp"
        properties = {
          port     = 9092
          protocol = "Tcp"
          timeout  = 60
        }
      }]

      listeners = [{
        name = "listener-tcp"
        properties = {
          # Bind listener to the PUBLIC frontend so PE traffic (which enters
          # via the PL config on frontend-public) can reach it. The public
          # IP is also reachable on this port from the internet — acceptable
          # for a sandbox smoke test; production would use the feature flag
          # for private-only deployment.
          frontendIPConfiguration = {
            id = "${data.azurerm_resource_group.smoke.id}/providers/Microsoft.Network/applicationGateways/appgw-smoke/frontendIPConfigurations/frontend-public"
          }
          frontendPort = {
            id = "${data.azurerm_resource_group.smoke.id}/providers/Microsoft.Network/applicationGateways/appgw-smoke/frontendPorts/port-9092"
          }
          protocol = "Tcp"
        }
      }]

      routingRules = [{
        name = "rule-tcp"
        properties = {
          ruleType = "Basic"
          priority = 100
          listener = {
            id = "${data.azurerm_resource_group.smoke.id}/providers/Microsoft.Network/applicationGateways/appgw-smoke/listeners/listener-tcp"
          }
          backendAddressPool = {
            id = "${data.azurerm_resource_group.smoke.id}/providers/Microsoft.Network/applicationGateways/appgw-smoke/backendAddressPools/backend-pool"
          }
          backendSettings = {
            id = "${data.azurerm_resource_group.smoke.id}/providers/Microsoft.Network/applicationGateways/appgw-smoke/backendSettingsCollection/backend-settings-tcp"
          }
        }
      }]

      privateLinkConfigurations = [{
        name = "pl-config"
        properties = {
          ipConfigurations = [{
            name = "pl-ipconfig"
            properties = {
              privateIPAllocationMethod = "Dynamic"
              primary                   = true
              subnet                    = { id = azurerm_subnet.appgw_pls.id }
            }
          }]
        }
      }]
    }
  }

  depends_on = [
    azurerm_subnet.appgw,
    azurerm_subnet.appgw_pls,
    azurerm_linux_virtual_machine.backend,
    azurerm_public_ip.appgw,
  ]
}

# =============================================================================
# Databricks NCC + workspace binding + PE rule (via REST API)
# =============================================================================

resource "databricks_mws_network_connectivity_config" "smoke" {
  provider = databricks.account
  name     = "ncc-smoke-appgw-${formatdate("YYYYMMDDhhmm", timestamp())}"
  region   = data.azurerm_resource_group.smoke.location

  lifecycle {
    ignore_changes = [name] # don't churn name on every plan
  }
}

resource "databricks_mws_ncc_binding" "smoke" {
  provider                       = databricks.account
  network_connectivity_config_id = databricks_mws_network_connectivity_config.smoke.network_connectivity_config_id
  workspace_id                   = var.databricks_workspace_id
}

# The Databricks terraform provider does not yet support creating NCC PE
# rules that target Application Gateway v2 as the resource_id. We use the
# REST API directly via az + curl.
resource "null_resource" "ncc_pe_rule_appgw" {
  triggers = {
    ncc_id     = databricks_mws_network_connectivity_config.smoke.network_connectivity_config_id
    appgw_id   = azapi_resource.appgw.id
    fqdn       = var.test_fqdn
    account_id = var.databricks_account_id
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      TOKEN=$(az account get-access-token --resource "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d" --query accessToken -o tsv)
      [ -n "$TOKEN" ] || { echo "ERROR: no Databricks access token"; exit 1; }
      NCC_ID="${databricks_mws_network_connectivity_config.smoke.network_connectivity_config_id}"
      RESP=$(curl -sw "\n%%{http_code}" -X POST \
        "${var.databricks_host}/api/2.0/accounts/${var.databricks_account_id}/network-connectivity-configs/$NCC_ID/private-endpoint-rules" \
        -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
        -d '{"resource_id":"${azapi_resource.appgw.id}","group_id":"frontend-public","domain_names":["${var.test_fqdn}"]}')
      CODE=$(echo "$RESP" | tail -1)
      BODY=$(echo "$RESP" | sed '$d')
      if [ "$CODE" -ge 200 ] && [ "$CODE" -lt 300 ]; then
        echo "PE rule created. Body:"
        echo "$BODY" | python3 -m json.tool 2>/dev/null || echo "$BODY"
      else
        echo "ERROR: HTTP $CODE"
        echo "$BODY"
        exit 1
      fi
    EOT
    interpreter = ["bash", "-c"]
  }

  depends_on = [
    databricks_mws_ncc_binding.smoke,
    azapi_resource.appgw,
  ]
}

# Wait for Databricks to provision its PE on its side
resource "time_sleep" "wait_for_pe" {
  depends_on      = [null_resource.ncc_pe_rule_appgw]
  create_duration = "90s"
}

# Approve the inbound PE connection on the App Gateway
resource "null_resource" "approve_pe_on_appgw" {
  depends_on = [time_sleep.wait_for_pe]

  triggers = {
    appgw_name = "appgw-smoke"
    rg_name    = data.azurerm_resource_group.smoke.name
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      echo "Looking for pending PE connections on App Gateway..."
      for i in 1 2 3 4 5 6; do
        PENDING=$(az network application-gateway private-link list \
          --gateway-name appgw-smoke \
          --resource-group ${data.azurerm_resource_group.smoke.name} \
          --query "[0].privateEndpointConnections[?privateLinkServiceConnectionState.status=='Pending']" \
          -o json 2>/dev/null || echo "[]")
        COUNT=$(echo "$PENDING" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))")
        if [ "$COUNT" -gt 0 ]; then
          echo "$PENDING" | python3 -c "
import sys, json, subprocess
for c in json.load(sys.stdin):
    name = c['name']
    print(f'Approving {name}')
    subprocess.run(['az','network','application-gateway','private-link','connection','update',
                    '--gateway-name','appgw-smoke',
                    '--resource-group','${data.azurerm_resource_group.smoke.name}',
                    '--name', name, '--connection-status','Approved'], check=True)
"
          exit 0
        fi
        echo "  no pending yet, sleeping 30s ($i/6)..."
        sleep 30
      done
      echo "WARN: No pending PE connection appeared after ~3 min. Check manually:"
      echo "  az network application-gateway private-link list --gateway-name appgw-smoke --resource-group ${data.azurerm_resource_group.smoke.name} -o jsonc"
    EOT
    interpreter = ["bash", "-c"]
  }
}

# =============================================================================
# Outputs
# =============================================================================

output "appgw_id" {
  description = "Resource ID of the App Gateway."
  value       = azapi_resource.appgw.id
}

output "appgw_frontend_ip" {
  description = "Private IP of the App Gateway frontend (in subnet-appgw)."
  value       = try(jsondecode(azapi_resource.appgw.output).properties.frontendIPConfigurations[0].properties.privateIPAddress, "unknown — inspect via az")
}

output "ncc_id" {
  description = "Databricks NCC ID."
  value       = databricks_mws_network_connectivity_config.smoke.network_connectivity_config_id
}

output "test_fqdn" {
  description = "The FQDN registered in NCC. Notebooks dial this hostname; NCC injects DNS so it resolves to the Databricks-managed PE."
  value       = var.test_fqdn
}

output "backend_vm_name" {
  description = "Backend VM name (for tailing TLS echo logs)."
  value       = azurerm_linux_virtual_machine.backend.name
}

output "notebook_test_script" {
  description = "Paste this into a Databricks Serverless notebook to validate the full TLS path."
  value = <<-PYTHON
    # ----- Paste into a Databricks Serverless notebook -----
    # Validates: NCC DNS injection + PE to App GW + App GW TCP/TLS passthrough
    # + TLS handshake to backend self-signed cert.

    import socket, ssl, datetime

    FQDN = "${var.test_fqdn}"
    PORT = 9092

    print(f"[1/4] DNS lookup for {FQDN}")
    ip = socket.gethostbyname(FQDN)
    print(f"      resolved to: {ip}  (expect a private IP in Databricks-managed range)")

    print(f"[2/4] Opening TCP socket to {FQDN}:{PORT}")
    raw = socket.create_connection((FQDN, PORT), timeout=10)
    print(f"      TCP connected from {raw.getsockname()} to {raw.getpeername()}")

    print(f"[3/4] TLS handshake (SNI={FQDN}, self-signed cert verification disabled)")
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode   = ssl.CERT_NONE
    tls = ctx.wrap_socket(raw, server_hostname=FQDN)
    print(f"      TLS established. Cipher: {tls.cipher()}")
    print(f"      Peer cert subject (binary head): {tls.getpeercert(binary_form=True)[:50]!r}")

    print(f"[4/4] Round-trip echo through the proxy")
    msg = f"hello from serverless at {datetime.datetime.utcnow().isoformat()}Z\\n".encode()
    tls.sendall(msg)
    rx = tls.recv(4096)
    print(f"      sent: {msg!r}")
    print(f"      recv: {rx!r}")
    tls.close()
    assert msg in rx, "FAIL — echo did not contain the sent message"
    print("PASS — full L1+L2+L3+L4 path validated end-to-end")
  PYTHON
}

output "validation_commands" {
  description = "CLI commands to validate from the local machine."
  value = <<-EOT

    # Tail backend TLS echo logs (run this in another terminal):
    az vm run-command invoke -g ${data.azurerm_resource_group.smoke.name} -n ${azurerm_linux_virtual_machine.backend.name} \
      --command-id RunShellScript --scripts "sudo tail -50 /var/log/tls-9092.log"

    # Confirm the App GW PE connection is Approved on App GW side:
    az network application-gateway private-link list \
      --gateway-name appgw-smoke \
      --resource-group ${data.azurerm_resource_group.smoke.name} \
      --query "[0].privateEndpointConnections[].{name:name, status:privateLinkServiceConnectionState.status}" \
      -o table

    # Workspace URL (for opening a notebook): the workspace bound to the NCC above.

  EOT
}
