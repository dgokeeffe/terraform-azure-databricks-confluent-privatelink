# Terraform: Azure Databricks Serverless to Confluent Cloud via Private Link

This repository provides Terraform modules to establish private connectivity from **Databricks Serverless Compute** to **Confluent Cloud Kafka** on Azure using a transit architecture with Azure Private Link.

## Why a transit architecture?

Databricks Serverless Compute connects to external services via **NCC Private Endpoint Rules**. These rules target either a **Private Link Service (PLS)** or an **Application Gateway v2** in your subscription. Since Confluent Cloud is a SaaS service reachable only via Private Endpoint, we need a transit layer between the NCC PE and the Confluent PE.

This repo provides **two transit architecture options** - pick the one that fits your needs.

## Architecture options

### Option A: Application Gateway v2 with TCP proxy

```
Databricks Serverless
        │
        │ NCC PE Rule (targets App GW Private Link)
        ▼
┌───────────────────────────────────────────────┐
│            Customer transit VNet               │
│                                                │
│   ┌──────────────────────────────┐             │
│   │  Application Gateway v2      │             │
│   │  (TCP listener on 9092)      │             │
│   │  + Native Private Link       │             │
│   └──────────────┬───────────────┘             │
│                  │                             │
│                  ▼                             │
│   ┌──────────────────────────────┐             │
│   │  Private Endpoint            │             │
│   │  (to Confluent Cloud)        │             │
│   └──────────────┬───────────────┘             │
└──────────────────┼─────────────────────────────┘
                   │ Azure Private Link
                   ▼
            Confluent Cloud Kafka
```

### Option B: VMSS HAProxy with Standard Load Balancer

```
Databricks Serverless
        │
        │ NCC PE Rule (targets PLS)
        ▼
┌───────────────────────────────────────────────┐
│            Customer transit VNet               │
│                                                │
│   ┌──────────────────────────────┐             │
│   │  Private Link Service        │             │
│   │  (exposes LB to Databricks)  │             │
│   └──────────────┬───────────────┘             │
│                  │                             │
│                  ▼                             │
│   ┌──────────────────────────────┐             │
│   │  Standard Load Balancer      │             │
│   │  (frontend on 9092)          │             │
│   └──────────────┬───────────────┘             │
│                  │                             │
│                  ▼                             │
│   ┌──────────────────────────────┐             │
│   │  VMSS (Ubuntu + HAProxy)     │             │
│   │  TCP proxy to Confluent PE   │             │
│   └──────────────┬───────────────┘             │
│                  │                             │
│                  ▼                             │
│   ┌──────────────────────────────┐             │
│   │  Private Endpoint            │             │
│   │  (to Confluent Cloud)        │             │
│   └──────────────┬───────────────┘             │
└──────────────────┼─────────────────────────────┘
                   │ Azure Private Link
                   ▼
            Confluent Cloud Kafka
```

### Comparison

| | App Gateway v2 (Option A) | VMSS HAProxy (Option B) |
|---|---|---|
| **Maturity** | Preview (TCP proxy) | GA (all components) |
| **Azure provider** | Requires `azapi` (azurerm doesn't support TCP listeners) | `azurerm` only |
| **NCC PE rule** | REST API only (via `null_resource`) | Native Terraform resource |
| **Compute** | Fully managed PaaS | VMs you manage (patching, scaling) |
| **Cost** | ~$200+/month (App GW v2 Standard) | ~$60/month (2x Standard_B2s + LB) |
| **Complexity** | Lower (no VMs) | Higher (VMSS, cloud-init, HAProxy config) |
| **HA** | Built-in | VMSS with 2+ instances behind LB |
| **When to choose** | Production workloads, prefer managed | Cost-sensitive, need GA components, full control |

## Modules

| Module | Description |
|--------|-------------|
| `appgw-transit` | App Gateway v2 with TCP proxy, Confluent PE, and native Private Link |
| `vmss-haproxy-transit` | Standard LB + VMSS HAProxy + PLS + Confluent PE |
| `databricks-ncc-confluent` | Databricks NCC with PE rule (supports both transit modes) |
| `confluent-dns` | Private DNS Zone for classic compute (optional) |

## Prerequisites

1. **Confluent Cloud**
   - Dedicated or Enterprise cluster with Private Link enabled
   - Private Link Service alias from Confluent Cloud console

2. **Databricks**
   - Premium or Enterprise tier workspace
   - Account admin access for NCC configuration

3. **Azure**
   - Subscription with permissions to create networking resources
   - Azure CLI authenticated (`az login`)
   - For App GW option: register the TCP proxy preview feature flag

## Quick start

### Option A: App Gateway v2

```bash
cd examples/appgw
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values

terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

### Option B: VMSS HAProxy

```bash
cd examples/vmss-haproxy
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values

terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

## Required inputs

| Variable | Description | Example |
|----------|-------------|---------|
| `databricks_account_id` | Databricks account ID | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| `databricks_workspace_ids` | Workspace IDs to attach NCC | `["1234567890123456"]` |
| `confluent_private_link_service_alias` | From Confluent Cloud console | `s-xxxxx.privatelink.confluent.cloud` |
| `confluent_cluster_id` | Confluent cluster ID | `pkc-xxxxx` |
| `location` | Azure region | `eastus` |
| `vmss_admin_ssh_public_key` | SSH key for VMSS (Option B only) | `ssh-rsa AAAA...` |

## Module usage

### Option A: App Gateway v2

```hcl
module "confluent_transit" {
  source = "github.com/dgokeeffe/terraform-azure-databricks-confluent-privatelink//modules/appgw-transit"

  resource_group_name                  = "rg-confluent-transit"
  location                             = "eastus"
  confluent_private_link_service_alias = "s-xxxxx.privatelink.confluent.cloud"

  tags = { Environment = "production" }
}

module "databricks_ncc" {
  source = "github.com/dgokeeffe/terraform-azure-databricks-confluent-privatelink//modules/databricks-ncc-confluent"

  providers = {
    databricks = databricks.account
  }

  ncc_name             = "ncc-confluent-eastus"
  region               = "eastus"
  transit_mode         = "appgw"
  transit_resource_id  = module.confluent_transit.appgw_id
  confluent_cluster_id = "pkc-xxxxx"
  confluent_region     = "eastus"
  workspace_ids        = ["1234567890123456"]

  databricks_account_id       = var.databricks_account_id
  transit_resource_group_name = "rg-confluent-transit"
  transit_resource_name       = module.confluent_transit.appgw_name
  auto_approve_pe             = true
}
```

### Option B: VMSS HAProxy

```hcl
module "confluent_transit" {
  source = "github.com/dgokeeffe/terraform-azure-databricks-confluent-privatelink//modules/vmss-haproxy-transit"

  resource_group_name                  = "rg-confluent-transit"
  location                             = "eastus"
  confluent_private_link_service_alias = "s-xxxxx.privatelink.confluent.cloud"

  vmss_admin_ssh_public_key = var.vmss_admin_ssh_public_key

  tags = { Environment = "production" }
}

module "databricks_ncc" {
  source = "github.com/dgokeeffe/terraform-azure-databricks-confluent-privatelink//modules/databricks-ncc-confluent"

  providers = {
    databricks = databricks.account
  }

  ncc_name             = "ncc-confluent-eastus"
  region               = "eastus"
  transit_mode         = "pls"
  transit_resource_id  = module.confluent_transit.pls_id
  confluent_cluster_id = "pkc-xxxxx"
  confluent_region     = "eastus"
  workspace_ids        = ["1234567890123456"]

  transit_resource_group_name = "rg-confluent-transit"
  transit_resource_name       = module.confluent_transit.pls_name
  auto_approve_pe             = true
}
```

## DNS configuration

### Serverless compute

DNS is handled automatically by the NCC private endpoint rule's `domain_names` configuration. No additional DNS setup is required.

### Classic compute

For classic compute clusters, use the `confluent-dns` module to create a Private DNS Zone:

```hcl
module "confluent_dns" {
  source = "github.com/dgokeeffe/terraform-azure-databricks-confluent-privatelink//modules/confluent-dns"

  resource_group_name  = "rg-confluent-transit"
  location             = "eastus"
  confluent_cluster_id = "pkc-xxxxx"
  confluent_region     = "eastus"
  target_ip            = module.confluent_transit.frontend_ip  # Works for both options
  broker_count         = 6

  vnet_ids_to_link = [module.confluent_transit.vnet_id]
  vnet_names       = ["transit-vnet"]
}
```

## Post-deployment steps

1. **Approve Confluent PE connection**
   - Go to Confluent Cloud Console
   - Cluster > Settings > Networking > Private Link
   - Approve the pending connection

2. **Approve NCC PE connection** (if `auto_approve_pe = false`)
   - For App GW: approve in Azure portal on the Application Gateway Private Link tab
   - For PLS: approve in Azure portal on the Private Link Service

3. **Verify NCC status**
   - Go to Databricks Account Console
   - Security > Network Connectivity Configurations
   - Verify PE rule status is `ESTABLISHED`

4. **Test connectivity** from a Databricks notebook:
   ```python
   df = spark.read \
     .format("kafka") \
     .option("kafka.bootstrap.servers", "pkc-xxxxx.eastus.azure.confluent.cloud:9092") \
     .option("subscribe", "your-topic") \
     .option("kafka.security.protocol", "SASL_SSL") \
     .option("kafka.sasl.mechanism", "PLAIN") \
     .option("kafka.sasl.jaas.config",
             "org.apache.kafka.common.security.plain.PlainLoginModule required " +
             "username='<API_KEY>' password='<API_SECRET>';") \
     .load()
   ```

## Costs

### Option A: App Gateway v2

- Application Gateway v2 Standard (~$200/month base + data processing)
- Private Endpoints (~$7/month each)
- Databricks serverless networking charges

### Option B: VMSS HAProxy

- Azure Standard Load Balancer (~$18/month base + data processing)
- VMSS instances (2x Standard_B2s ~$35/month)
- Private Link Service (~$7/month + data processing)
- Private Endpoints (~$7/month each)
- Databricks serverless networking charges

## Troubleshooting

### PE connection stuck in Pending

- Verify the Confluent Private Link Service alias is correct
- Check Confluent Cloud console for pending approval
- Ensure your Azure subscription is allowlisted in Confluent

### NCC PE rule not establishing

- For PLS mode: verify the Private Link Service resource ID is correct
- For App GW mode: verify the App Gateway resource ID and check the account console for PE rule status
- Check for pending approval on the target resource
- Ensure region alignment between workspace, NCC, and transit resources

### Kafka connection timeouts

- Verify all domain names are in the NCC PE rule
- For VMSS option: check Load Balancer health probes and HAProxy status on VMSS instances
- For App GW option: check App Gateway backend health
- Verify Confluent PE connection is approved

### App GW TCP proxy issues

- Ensure the TCP proxy preview feature flag is registered in your subscription
- App GW TCP proxy requires API version 2024-05-01 or later
- The `azurerm` provider does not support TCP listeners - `azapi` is required

## Contributing

Contributions are welcome! Please open an issue or PR.

## License

Apache 2.0
