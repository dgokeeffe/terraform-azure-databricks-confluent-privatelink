# Pattern: Databricks NCC to Confluent Cloud through Application Gateway

This is the core workflow this repo demonstrates:

```text
Databricks serverless job or notebook
  dials Confluent bootstrap FQDN
    -> NCC domain interception
    -> Databricks-managed private endpoint
    -> Application Gateway Private Link
    -> App Gateway private TCP listener
    -> Confluent Cloud Azure private endpoint
    -> Kafka broker/topic
```

## What is private

- Kafka traffic from Databricks serverless compute enters the customer transit
  VNet through an NCC-created private endpoint.
- Kafka traffic is routed by Application Gateway to private endpoint IPs for
  Confluent Cloud.
- The Application Gateway listener used by Kafka is private.
- Kafka TLS is passed through. Application Gateway is a TCP proxy here, not a
  Kafka-aware proxy.

## What is not possible with App Gateway today

A strict "no public IP resource on Application Gateway" requirement conflicts
with the App Gateway Private Link path that Databricks NCC needs.

In a live Azure proof in `australiaeast`, private-only `Standard_v2`
Application Gateway deployment failed with:

```text
Application Gateway ... does not support Application Gateway without Public IP
for the selected SKU tier Standard_v2. Supported SKU tiers are Standard,WAF.
```

Because this repo uses Application Gateway v2 TCP/TLS proxy behavior, this repo
models the viable App Gateway shape:

- No public Kafka listener.
- No public Kafka ingress path.
- An unused public IP resource exists on the Application Gateway because
  `Standard_v2` requires it.
- The Application Gateway subnet has an NSG that denies inbound traffic from
  the `Internet` service tag.

If a security standard forbids the existence of any public IP resource, use a
customer-owned Azure Private Link Service in front of a TCP proxy instead of
Application Gateway.

## Enterprise Confluent shape

For Confluent Cloud Azure Private Link, do not assume one endpoint and one DNS
record for the production enterprise design.

Confluent documents this shape:

- Single-zone cluster: create one Azure private endpoint to the Confluent
  service alias for that zone.
- Multi-zone cluster: create three Azure private endpoints, one to each zonal
  service alias.
- DNS maps the Confluent private-link domain to those private endpoint IPs.
- Bootstrap records point at all zonal endpoint IPs.
- Zonal wildcard records such as `*.az1`, `*.az2`, and `*.az3` point at the
  matching zonal endpoint.
- Kafka broker names returned in metadata are not static, so do not hardcode
  broker hostnames.

This repo demonstrates the smallest correct path:

- `modules/appgw-transit` creates one private endpoint to one supplied
  Confluent service alias.
- `modules/databricks-ncc-confluent` accepts explicit Confluent domain names
  so the NCC rule intercepts both bootstrap and broker metadata re-dials.

## Multi-zone caution

Do not model Confluent multi-zone Private Link by putting `az1`, `az2`, and
`az3` private endpoint IPs into one Application Gateway TCP backend pool. In TCP
proxy mode, Application Gateway selects a backend from the pool and opens a new
backend connection. It does not preserve the DNS answer the Kafka client would
have received from Confluent's recommended private DNS records.

That matters because a Kafka client connects to bootstrap, receives metadata,
and then dials broker hostnames. Confluent's private DNS guidance maps zonal
broker wildcard records such as `*.az1`, `*.az2`, and `*.az3` to their matching
private endpoint IPs. A single undifferentiated TCP backend pool can send an
`az1` broker connection to the `az2` private endpoint.

A likely App Gateway enterprise extension is:

1. One App Gateway private frontend/listener/backend pool for bootstrap.
2. One App Gateway private frontend/listener/backend pool per Confluent zone.
3. One Databricks NCC private endpoint rule per App Gateway frontend group ID.
4. Domain assignments such as bootstrap FQDN -> bootstrap frontend,
   `*.az1.<domain>` -> az1 frontend, `*.az2.<domain>` -> az2 frontend, and
   `*.az3.<domain>` -> az3 frontend.

This repo intentionally does not implement that larger multi-zone shape.

## NCC domain names

The critical implementation detail is that Spark does not only connect to the
bootstrap server. The Kafka client connects to the bootstrap server, receives
metadata with broker hostnames, and then opens new connections to those broker
hostnames.

Every hostname that may be dialed must be covered by the NCC private endpoint
rule `domain_names`.

Use the Confluent Cloud networking details page as the source of truth. A
typical private DNS resolution configuration looks like this:

```hcl
confluent_bootstrap_servers = "lkc-123abc-4kgzg.eastus.azure.confluent.cloud:9092"

confluent_ncc_domain_names = [
  "lkc-123abc-4kgzg.eastus.azure.confluent.cloud",
  "*.4kgzg.eastus.azure.confluent.cloud",
]
```

If Confluent uses public/chased-private DNS for the network, the bootstrap name
may include `glb`. Confirm whether Databricks NCC must intercept the `glb`
bootstrap name, the non-GLB CNAME target, or both for the customer's resolver
path.

## Kafka client settings

For Confluent Cloud, the Spark Kafka options are usually:

```python
spark.readStream.format("kafka").options(**{
    "kafka.bootstrap.servers": "<bootstrap-from-confluent-console>:9092",
    "kafka.security.protocol": "SASL_SSL",
    "kafka.sasl.mechanism": "PLAIN",
    "kafka.sasl.jaas.config": (
        "org.apache.kafka.common.security.plain.PlainLoginModule required "
        "username='<API_KEY>' password='<API_SECRET>';"
    ),
})
```

The network path only proves that sockets can reach Confluent. You still need
Confluent API credentials and topic ACLs/RBAC that allow the producer or
consumer operation.

## Validation

Minimum proof for a customer conversation:

1. Terraform creates the transit VNet, Application Gateway, Confluent private
   endpoint, NCC, NCC private endpoint rule, and workspace binding.
2. Confluent private endpoint connection shows `Approved`.
3. Databricks NCC private endpoint connection shows established/approved.
4. From Databricks serverless compute, DNS resolution and Kafka producer or
   consumer calls succeed using the Confluent bootstrap server.
5. The test writes to and reads from a real topic, proving bootstrap plus broker
   metadata re-resolution.
6. If Application Gateway has the required public IP fallback, the public
   frontend has no listeners and an NSG explicitly denies inbound `Internet`
   traffic.

The included `examples/appgw/kafka_topic_smoke_test.py` notebook is the minimal
topic-level test for steps 4 and 5. Use an existing topic and Confluent
credentials with produce and consume rights. A successful run prints the unique
key and value that were written and read back.

## Live proof summary

The proof deployment used a private HTTP backend so the Databricks/App Gateway
path could be tested without depending on Confluent credentials. The important
evidence was:

- Private-only `Standard_v2` Application Gateway failed validation, so the
  public-IP fallback is required for this SKU.
- Application Gateway `agw-nccproof05` deployed with private frontend
  `frontend-private` and unused public frontend `frontend-public-unused`.
- The only listener was bound to `frontend-private`.
- Databricks NCC private endpoint rule for `frontend-private` reached
  `ESTABLISHED`.
- Workspace `dbc-davidokeeffe-demo-05` was bound to the NCC.
- A Databricks serverless job resolved `agw-nccproof05.dbxdemo.net` to private
  IP `172.22.112.8` and returned HTTP `200` from the private backend.
- NSG `nsg-nccproof-appgw` was attached to the Application Gateway subnet with
  `Deny-Internet-Inbound` from source `Internet`.
- A direct proxy-bypassed request to the public IP on port 80 failed to connect.

## References

- Microsoft Learn: [Private Application Gateway deployment](https://learn.microsoft.com/en-us/azure/application-gateway/application-gateway-private-deployment).
- Microsoft Learn: [Application Gateway TCP/TLS proxy overview](https://learn.microsoft.com/en-us/azure/application-gateway/tcp-tls-proxy-overview).
- Microsoft Learn: [Azure Databricks serverless private connectivity](https://learn.microsoft.com/en-us/azure/databricks/security/network/serverless-network-security/serverless-private-link).
- Confluent Docs: [Azure Private Link connections with Confluent Cloud](https://docs.confluent.io/cloud/current/networking/private-links/azure-privatelink.html).
