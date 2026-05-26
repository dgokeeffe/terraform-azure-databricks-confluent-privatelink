# Why this transit architecture exists

A deeper rationale for the patterns in this repo — specifically: why a transit
is required at all, why it must be a TCP-level (not HTTP) proxy, what the
"TLS" in "TCP/TLS proxy" means, and how to choose between Application Gateway
v2 and VMSS + HAProxy.

This document supplements the [README](../README.md) with the *why* behind the
choices. Read this when designing or reviewing the architecture for a new
customer; read the README when you just need to deploy.

## TL;DR

The transit exists because three independent Azure / Databricks platform
constraints all force it. Once you accept that a transit is required, it must
be a TCP (L4) proxy because Kafka uses a binary wire protocol, not HTTP. The
"TLS" suffix on Azure's "TCP/TLS proxy" listener refers to its ability to
inspect TLS SNI without decrypting payload bytes — useful for multi-cluster
routing, optional for single-cluster setups. App Gateway v2's TCP/TLS listener
went GA in late 2025 and is now the recommended primary transit; VMSS +
HAProxy remains a valid cost-saver alternative.

## Three stacked constraints force the transit

The transit cannot be designed away. Any one of these constraints alone would
force it; all three together make it a hard requirement.

### 1. NCC accepts Azure Resource IDs, not PLS aliases

The Databricks Terraform resource for an NCC private-endpoint rule —
`databricks_mws_ncc_private_endpoint_rule.resource_id` — accepts only a full
Azure ARM Resource ID. Confluent Cloud publishes its Private Link Service as
a cross-tenant *alias* (the standard mechanism for SaaS Private Link).
Aliases are not Resource IDs.

NCC's API therefore cannot point at Confluent's PLS, regardless of any
visibility policy. This is the most fundamental of the three constraints
because it survives any future change Confluent might make to their
visibility allow-list.

### 2. Confluent's PLS visibility does not include Databricks' subscription

Even if NCC could accept aliases, Confluent Cloud's PLS visibility allow-list
does not include Databricks' managed serverless subscription IDs (and
Databricks does not publish these IDs as a stable, customer-addressable
surface). A PE attachment attempt from outside the allow-list is rejected at
the Azure platform layer.

### 3. Azure Standard LB cannot use Private Endpoint IPs as backends

This is the constraint that often surprises engineers familiar with on-prem
load balancing. Azure SDN treats PE private IPs as hooks into the Azure
backbone tunnel, not as ordinary IPs reachable via normal routing. Azure
Standard Load Balancer's backend-pool plumbing rejects PE IPs as backend
targets.

This is why a naive "Standard LB → backend = Confluent PE IP" design fails.
Some intermediary with an ordinary NIC and an ordinary private IP is required
between the LB and the Confluent PE — and that intermediary is the TCP proxy.

> **Historical note:** the original version of this repo attempted the naive
> design before this constraint was understood. See git history (initial
> commit) for the broken module and the subsequent commit
> *"Replace broken SLB transit module with App GW v2 and VMSS HAProxy
> options"* for the fix.

## Why a TCP-level (L4) proxy, not HTTP (L7)

App Gateway is best known for its L7 (HTTP/HTTPS) capabilities: URL routing,
host-header matching, Web Application Firewall, etc. None of that applies to
the Kafka broker path:

- **Kafka uses a binary TCP wire protocol.** Clients open raw TCP sockets and
  exchange binary frames (`Produce`, `Fetch`, `Metadata`, etc.). There is no
  HTTP request, no `GET /path`, no headers an L7 proxy could match on.
- **An L7 proxy would terminate and re-establish TLS.** Kafka client → broker
  encryption is end-to-end (often mTLS). Terminating TLS at the proxy breaks
  the mTLS chain and adds latency.
- **Schema Registry does use HTTP**, but the brokers — the primary workload —
  do not. SR can ride an L7 listener; brokers cannot.

L4 (TCP passthrough) is therefore the only viable proxy mode. The proxy
accepts a TCP socket from one side and forwards bytes to a TCP socket on the
other side, never inspecting payload bytes.

## What "TLS" means in "TCP/TLS proxy"

Azure App Gateway v2's L4 listener is named "TCP/TLS proxy" — but the proxy
does **not** terminate TLS. The end-to-end Databricks → broker TLS session is
preserved.

The "TLS" suffix refers to two capabilities:

1. **SNI inspection without decryption.** TLS clients send a `ClientHello` at
   the start of the handshake whose Server Name Indication (SNI) field is in
   cleartext inside an otherwise-encrypted record. A TCP/TLS listener can
   read SNI to make routing decisions (e.g., one App Gateway fronting
   multiple Confluent clusters), without ever decrypting the ciphertext that
   follows.
2. **Operational signalling.** Naming the listener "TCP/TLS" tells operators
   and SecOps reviewers that the listener is designed for TLS-encrypted TCP
   traffic specifically — important when answering "is this proxy seeing
   plaintext?" (No; it sees TLS bytes; only the SNI is exposed.)

For single-cluster deployments, SNI inspection isn't needed; treat the
listener as a plain TCP proxy. The capability is there if you ever fan-out
to multiple Confluent clusters via SNI-based routing.

## Choosing between App Gateway v2 and VMSS + HAProxy

Both fill the same role — L4 TCP proxy with PLS inbound. They differ in
operating model:

| Aspect | App Gateway v2 TCP/TLS | VMSS + HAProxy |
|---|---|---|
| **Operational ownership** | Managed PaaS — Microsoft patches, scales, monitors | Customer owns OS patching, HAProxy config, log shipping |
| **Scaling** | Auto-scales 1→125 instances | Manual / autoscale rules; bounded by VMSS limits |
| **PLS inbound** | Native — App GW exposes itself as PLS directly | Standard LB fronts the VMSS; PLS attaches to the LB |
| **Cost (steady state)** | ~$200/mo | ~$60/mo (B2s instances) |
| **HA model** | Built-in zone redundancy when configured | Customer configures across AZs |
| **Compliance** | First-party Azure managed service | Customer-owned VMs subject to customer compliance |
| **GA status** | GA since 2025-11-26 | GA since this module was written |
| **Terraform provider** | `azapi` (azurerm doesn't yet support TCP listener config) | `azurerm` |

**App Gateway v2 is the recommended default** when managed-service ops
ergonomics are preferred. Most enterprise security teams favour "managed
Azure service with SLA" over "VMs we patch monthly" for the same job.

**VMSS + HAProxy remains a defensible cost-saver** when the ~$140/mo delta
per environment, multiplied across many environments, becomes material — or
when full control over the proxy's runtime behaviour is required.

> **Caveat:** the customer-response draft at the repo root (`RESPONSE.md`)
> describes App Gateway TCP proxy as "currently in preview". That note is
> stale: the feature went GA on 2025-11-26 (Microsoft Learn:
> [TCP/TLS proxy overview](https://learn.microsoft.com/en-us/azure/application-gateway/tcp-tls-proxy-overview)).
> Refresh `RESPONSE.md` before re-using its language with a customer.

## See also

- [`README.md`](../README.md) — top-level architecture diagrams for both transit options.
- [`modules/appgw-transit/`](../modules/appgw-transit/) — Option A implementation.
- [`modules/vmss-haproxy-transit/`](../modules/vmss-haproxy-transit/) — Option B implementation.
- [`modules/databricks-ncc-confluent/`](../modules/databricks-ncc-confluent/) — NCC + PE rule for either transit.
- [`examples/full-stack/`](../examples/full-stack/) — end-to-end caller wiring both modules together.

## External references

- Microsoft Learn — *Manage private endpoint rules* (NCC supported target list):
  <https://learn.microsoft.com/en-us/azure/databricks/security/network/serverless-network-security/manage-private-endpoint-rules>
- Microsoft Learn — *Configure private connectivity for serverless compute*:
  <https://learn.microsoft.com/en-us/azure/databricks/security/network/serverless-network-security/serverless-private-link>
- Microsoft Learn — *Application Gateway TCP/TLS proxy overview* (GA 2025-11-26):
  <https://learn.microsoft.com/en-us/azure/application-gateway/tcp-tls-proxy-overview>
- Confluent — *Azure Private Link for Confluent Cloud*:
  <https://docs.confluent.io/cloud/current/networking/private-links/azure-privatelink.html>
- Confluent — *Schema Registry Private Link*:
  <https://docs.confluent.io/cloud/current/sr/fundamentals/sr-private-link.html>
