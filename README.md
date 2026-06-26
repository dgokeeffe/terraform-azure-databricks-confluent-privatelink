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

## Minimal deployment

```bash
cd examples/appgw
cp terraform.tfvars.example terraform.tfvars
# Fill in Databricks account/workspace IDs, Confluent aliases, and NCC domains.

terraform init
terraform plan
terraform apply
```

After apply:

1. Approve the Confluent private endpoint connections in Confluent Cloud if they
   are not auto-approved.
2. Approve the Databricks private endpoint connection on the Application Gateway
   if required by Azure.
3. Run a Databricks serverless job or notebook using the Confluent bootstrap
   server and SASL_SSL credentials.

## Topic smoke test

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
