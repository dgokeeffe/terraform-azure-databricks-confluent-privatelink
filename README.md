# Terraform: Azure Databricks Serverless to Confluent Cloud via Private Link

This repository provides Terraform modules to establish private connectivity from **Databricks Serverless Compute** to **Confluent Cloud Kafka** on Azure using a transit architecture with Azure Private Link.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                     Databricks Serverless Compute Plane                         │
│                         (Databricks-managed)                                    │
│   ┌─────────────────────┐                                                       │
│   │  Spark Streaming    │                                                       │
│   │  Job / Notebook     │                                                       │
│   └──────────┬──────────┘                                                       │
│              │                                                                  │
│              ▼                                                                  │
│   ┌─────────────────────┐     NCC Private Endpoint Rule                         │
│   │  Private Endpoint   │     (domain: *.confluent.cloud)                       │
│   │  (NCC-managed)      │                                                       │
│   └──────────┬──────────┘                                                       │
└──────────────┼──────────────────────────────────────────────────────────────────┘
               │  Azure Private Link
               │
┌──────────────┼──────────────────────────────────────────────────────────────────┐
│              │              Customer VNet (Transit)                             │
│              ▼                                                                  │
│   ┌─────────────────────┐                                                       │
│   │  Private Link       │◄──── Exposes LB to Databricks                         │
│   │  Service            │                                                       │
│   └──────────┬──────────┘                                                       │
│              │                                                                  │
│              ▼                                                                  │
│   ┌─────────────────────┐                                                       │
│   │  Azure Standard     │      Backend: Confluent PE IPs                        │
│   │  Load Balancer      │      Ports: 9092 (Kafka)                              │
│   └──────────┬──────────┘                                                       │
│              │                                                                  │
│              ▼                                                                  │
│   ┌─────────────────────┐                                                       │
│   │  Private Endpoint   │◄──── Points to Confluent's PLS                        │
│   │  (to Confluent)     │                                                       │
│   └──────────┬──────────┘                                                       │
└──────────────┼──────────────────────────────────────────────────────────────────┘
               │  Azure Private Link
               │
┌──────────────┼──────────────────────────────────────────────────────────────────┐
│              ▼                   Confluent Cloud                                │
│   ┌─────────────────────────────────────────────────────────────────────────┐   │
│   │                         Kafka Cluster                                   │   │
│   │   [Broker 1]  [Broker 2]  [Broker 3]                                    │   │
│   │                     Kafka Topics                                        │   │
│   └─────────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## Why this architecture?

Databricks Serverless Compute can only establish private connectivity to resources behind an **Azure Standard Load Balancer**. Since Confluent Cloud is a SaaS service, we need a "transit" architecture:

1. **Confluent Private Endpoint** - Connects your VNet to Confluent Cloud
2. **Azure Load Balancer** - Routes traffic to the Confluent PE
3. **Private Link Service** - Exposes the LB to Databricks Serverless
4. **Databricks NCC** - Creates a private endpoint to your PLS with DNS interception

## Modules

| Module | Description |
|--------|-------------|
| `confluent-transit-slb` | Azure infrastructure: VNet, Load Balancer, Private Link Service, Confluent PE |
| `databricks-ncc-confluent` | Databricks NCC and private endpoint rule configuration |
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

## Quick start

```bash
# Clone the repository
git clone https://github.com/david-databricks/terraform-azure-databricks-confluent-privatelink.git
cd terraform-azure-databricks-confluent-privatelink/examples/complete

# Copy and edit the tfvars file
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values

# Initialize and apply
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

## Post-deployment steps

1. **Approve Confluent PE connection**
   - Go to Confluent Cloud Console
   - Cluster → Settings → Networking → Private Link
   - Approve the pending connection

2. **Verify NCC status**
   - Go to Databricks Account Console
   - Security → Network Connectivity Configurations
   - Verify status is `ESTABLISHED`

3. **Test connectivity**
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

## Module usage

### Using individual modules

```hcl
module "confluent_transit" {
  source = "github.com/david-databricks/terraform-azure-databricks-confluent-privatelink//modules/confluent-transit-slb"

  resource_group_name                  = "rg-confluent-transit"
  location                             = "eastus"
  confluent_private_link_service_alias = "s-xxxxx.privatelink.confluent.cloud"

  tags = {
    Environment = "production"
  }
}

module "databricks_ncc" {
  source = "github.com/david-databricks/terraform-azure-databricks-confluent-privatelink//modules/databricks-ncc-confluent"

  providers = {
    databricks = databricks.account
  }

  ncc_name                = "ncc-confluent-eastus"
  region                  = "eastus"
  private_link_service_id = module.confluent_transit.pls_id
  confluent_cluster_id    = "pkc-xxxxx"
  confluent_region        = "eastus"
  workspace_ids           = ["1234567890123456"]

  pls_resource_group_name = "rg-confluent-transit"
  pls_name                = module.confluent_transit.pls_name
}
```

## DNS configuration

### Serverless compute

For serverless compute, DNS is handled automatically by the NCC private endpoint rule's `domain_names` configuration. No additional DNS setup is required.

### Classic compute

For classic compute clusters, use the `confluent-dns` module to create a Private DNS Zone:

```hcl
module "confluent_dns" {
  source = "github.com/david-databricks/terraform-azure-databricks-confluent-privatelink//modules/confluent-dns"

  resource_group_name  = "rg-confluent-transit"
  location             = "eastus"
  confluent_cluster_id = "pkc-xxxxx"
  confluent_region     = "eastus"
  target_ip            = module.confluent_transit.lb_frontend_ip
  broker_count         = 6

  vnet_ids_to_link = [module.confluent_transit.vnet_id]
  vnet_names       = ["transit-vnet"]
}
```

## Costs

This architecture incurs costs for:

- Azure Standard Load Balancer (~$18/month base + data processing)
- Azure Private Link Service (~$7/month + data processing)
- Private Endpoints (~$7/month each)
- Databricks serverless networking charges

## Troubleshooting

### PE connection stuck in Pending

- Verify the Confluent Private Link Service alias is correct
- Check Confluent Cloud console for pending approval
- Ensure your Azure subscription is allowlisted in Confluent

### NCC PE rule not establishing

- Verify the Private Link Service resource ID is correct
- Check for pending approval on the Private Link Service
- Ensure region alignment between workspace, NCC, and PLS

### Kafka connection timeouts

- Verify all domain names are in the NCC PE rule
- Check Load Balancer health probes are healthy
- Verify Confluent PE connection is approved

## Contributing

Contributions are welcome! Please open an issue or PR.

## License

Apache 2.0
