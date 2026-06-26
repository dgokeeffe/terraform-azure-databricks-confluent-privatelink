# Azure Databricks Serverless to Confluent Cloud over Private Link

This repo is a stripped-back Terraform demonstrator for one workflow:

```text
Databricks serverless compute
  -> Databricks Network Connectivity Configuration (NCC)
  -> Azure Private Endpoint to Application Gateway
  -> Application Gateway v2 TCP listener
  -> Azure Private Endpoint to Confluent Cloud
  -> Kafka topic
```

The goal is to show the private connectivity pattern and the Kafka-specific DNS
shape. It is not a full enterprise landing zone module.

## Important constraint

The exact design "Application Gateway with no public IP resource, exposed to
Databricks NCC through Application Gateway Private Link" is not currently a
valid Azure Application Gateway design.

Azure Application Gateway supports private-only deployments, but Microsoft
documents that Application Gateway Private Link is unsupported with a
private-only gateway. Databricks NCC reaches Application Gateway through that
Private Link feature. In practice, the App Gateway pattern requires an
Application Gateway that has no public listener for Kafka traffic, but still has
an unused public IP resource so Private Link can be enabled.

If the enterprise requirement is strictly "no public IP resource may exist",
use a customer-owned Azure Private Link Service in front of a TCP proxy instead
of Application Gateway. That is a different pattern.

## What this repo keeps

| Path | Purpose |
| --- | --- |
| `modules/appgw-transit` | Customer transit VNet, Application Gateway v2 TCP listener, and one Confluent Cloud private endpoint. |
| `modules/databricks-ncc-confluent` | Databricks NCC, App Gateway private endpoint rule, domain interception, and workspace binding. |
| `examples/appgw` | Minimal caller that wires the two modules together. |
| `examples/appgw/kafka_topic_smoke_test.py` | Databricks notebook-style smoke test that writes to and reads from a Kafka topic. |
| `docs/pattern.md` | Architecture notes, enterprise assumptions, and Kafka connectivity details. |

## Confluent Cloud connectivity model

For Confluent Cloud on Azure Private Link, expect the Confluent console to give
you:

- A bootstrap server endpoint.
- A DNS domain / subdomain for the Private Link network.
- One service alias for a single-zone cluster, or three zonal service aliases
  for a multi-zone cluster.

This core demo uses one Confluent service alias and one Azure private endpoint.
That is enough to demonstrate the end-to-end path without pretending to solve
every high-availability detail.

For a multi-zone enterprise cluster, create one Azure private endpoint per
Confluent zonal service alias. Do not put all zonal endpoint IPs into one App
Gateway TCP backend pool and call it done. Kafka clients do not only connect to
the bootstrap server; they receive broker metadata and reconnect to broker
hostnames. Confluent's zonal broker hostnames are expected to land on their
matching zonal private endpoint.

The likely multi-zone App Gateway extension is separate App Gateway private
frontends/listeners/backend pools per Confluent zone, plus separate Databricks
NCC private endpoint rules that map each zonal wildcard domain to the matching
Application Gateway frontend. If a customer does not need App Gateway
specifically, a Private Link Service in front of an SNI-aware TCP proxy is often
the cleaner strict-private design.

Databricks NCC must intercept every FQDN the Kafka client may dial. In practice
that means passing explicit domain names such as:

```hcl
confluent_ncc_domain_names = [
  "lkc-123abc-4kgzg.eastus.azure.confluent.cloud",
  "*.4kgzg.eastus.azure.confluent.cloud",
]
```

Use the values from the Confluent Cloud networking details page for your
cluster. The example above is illustrative only.

## How to use this repo

### 1. Confirm the design fit

Use this repo when you need to demonstrate Databricks serverless private
connectivity to Confluent Cloud Kafka through a customer-owned Application
Gateway.

Do not use this repo as-is when the security requirement is "no public IP
resource may exist anywhere on Application Gateway." That stricter requirement
needs a different transit design, such as a customer-owned Private Link Service
fronting a TCP proxy.

### 2. Collect required values

From Databricks:

- Account ID.
- Workspace ID for each workspace that should use the NCC.
- Account-admin authentication for the Databricks account API.

From Confluent Cloud:

- Kafka bootstrap server, including port.
- Azure Private Link service alias for the target Kafka cluster zone.
- DNS domain/subdomain values that Kafka clients will dial.
- API key/secret with produce and consume rights on the test topic.

From Azure:

- Subscription and resource group target.
- Region aligned to the Databricks workspace and Confluent network.
- Address ranges for the transit VNet and subnets.
- Permission to create Application Gateway, Private Endpoint, Public IP, and
  networking resources.

### 3. Deploy the Terraform example

```bash
cd examples/appgw
cp terraform.tfvars.example terraform.tfvars
# Fill in Databricks account/workspace IDs, Confluent aliases, and NCC domains.

terraform init
terraform plan
terraform apply
```

The important `terraform.tfvars` fields are:

```hcl
databricks_account_id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
databricks_workspace_ids = ["1234567890123456"]

confluent_private_link_service_alias = "s-xxxxx.privatelink.confluent.cloud"
confluent_bootstrap_servers          = "lkc-123abc-4kgzg.eastus.azure.confluent.cloud:9092"
confluent_ncc_domain_names = [
  "lkc-123abc-4kgzg.eastus.azure.confluent.cloud",
  "*.4kgzg.eastus.azure.confluent.cloud",
]
```

### 4. Approve and verify private endpoints

1. Approve the Confluent private endpoint connection in Confluent Cloud if it
   is not auto-approved.
2. Approve the Databricks private endpoint connection on the Application Gateway
   if required by Azure.
3. In the Databricks account console, verify the NCC private endpoint rule is
   established or approved.
4. Confirm the target workspaces are bound to the NCC.

### 5. Run the topic smoke test

Run `examples/appgw/kafka_topic_smoke_test.py` on Databricks serverless compute
after the private endpoint connections are approved. It writes a unique key to
an existing topic, then reads the same key back. That proves the client can
bootstrap, receive Kafka metadata, reconnect to the broker hostname, and perform
real topic I/O through the private path.

The notebook expects these widgets:

| Widget | Value |
| --- | --- |
| `bootstrap_servers` | Confluent bootstrap servers, including port. |
| `topic` | Existing topic that the API key can produce to and consume from. |
| `secret_scope` | Databricks secret scope containing Confluent credentials. |
| `api_key_secret` | Secret key for the Confluent API key. |
| `api_secret_secret` | Secret key for the Confluent API secret. |

The underlying Spark Kafka options are:

```python
options = {
    "kafka.bootstrap.servers": "<bootstrap-from-confluent-console>:9092",
    "kafka.security.protocol": "SASL_SSL",
    "kafka.sasl.mechanism": "PLAIN",
    "kafka.sasl.jaas.config": (
        "org.apache.kafka.common.security.plain.PlainLoginModule required "
        "username='<API_KEY>' password='<API_SECRET>';"
    ),
}
```

## What this repo deliberately does not cover

- Databricks workspace front-end Private Link.
- Unity Catalog storage private endpoints.
- Kafka Connect on AKS.
- Schema Registry private connectivity.
- Strict no-public-IP designs using Private Link Service plus a TCP proxy.

## References

- Microsoft Learn: [Private Application Gateway deployment](https://learn.microsoft.com/en-us/azure/application-gateway/application-gateway-private-deployment).
- Microsoft Learn: [Application Gateway TCP/TLS proxy overview](https://learn.microsoft.com/en-us/azure/application-gateway/tcp-tls-proxy-overview).
- Microsoft Learn: [Azure Databricks serverless private connectivity](https://learn.microsoft.com/en-us/azure/databricks/security/network/serverless-network-security/serverless-private-link).
- Confluent Docs: [Azure Private Link connections with Confluent Cloud](https://docs.confluent.io/cloud/current/networking/private-links/azure-privatelink.html).
