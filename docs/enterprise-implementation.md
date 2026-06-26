# Enterprise Implementation Guide

This guide describes how to implement the proven enterprise pattern:

```text
Databricks serverless compute
  -> Databricks Network Connectivity Configuration (NCC)
  -> Databricks-managed private endpoint
  -> Application Gateway Private Link
  -> Application Gateway private listener
  -> Private backend, such as Confluent Cloud Private Link
```

The live proof showed that private dataplane connectivity through Application
Gateway is viable. It also showed that `Standard_v2` Application Gateway cannot
be deployed as a private-only gateway in this pattern. Azure requires a public
IP resource. The enterprise-safe implementation is therefore a required but
unused public frontend, a private listener only, and subnet-level controls that
deny public Internet ingress.

## Decision Checklist

Before implementation, confirm which requirement applies.

| Requirement | Recommended pattern |
| --- | --- |
| Private dataplane, public IP resource allowed if unused and blocked | Application Gateway v2 with private listener, unused public frontend, and Internet-deny NSG. |
| No public listener, no public ingress, but public IP resource can exist | Application Gateway v2 pattern in this repo. |
| No public IP resource may exist at all | Do not use Application Gateway v2. Use customer-owned Azure Private Link Service plus a TCP or SNI-aware proxy. |
| Multi-zone Confluent Cloud production cluster | Extend this repo with one Confluent private endpoint and one App Gateway private frontend/listener per zone, or use a TCP proxy pattern. |

## Roles And Ownership

Split ownership explicitly. Most production delays come from unclear ownership
of Private Link approval, DNS names, and network policy.

| Area | Owner | Responsibility |
| --- | --- | --- |
| Databricks account | Databricks account admin | Create or select NCC, create private endpoint rule, bind workspace to NCC, run serverless validation. |
| Azure networking | Customer cloud/network team | Transit VNet, subnets, Application Gateway, NSG, Private Endpoint approvals. |
| Confluent Cloud | Kafka/platform team | Private Link aliases, cluster DNS names, topic, API credentials, endpoint approval. |
| Security | Enterprise security team | Approve public-IP fallback, confirm no public listener, verify NSG denies Internet inbound. |

## Target Azure Shape

Use separate subnets for the gateway, Private Link configuration, private
endpoints, and optional backend workloads.

```text
vnet-transit
  snet-appgw
    Application Gateway v2
    NSG attached
  snet-appgw-pl
    Application Gateway Private Link configuration
  snet-private-endpoints
    Private Endpoint to Confluent Cloud or other backend service
```

Minimum Application Gateway shape:

- SKU: `Standard_v2`.
- Frontend `frontend-private`: static private IP in `snet-appgw`.
- Frontend `frontend-public-unused`: required public IP resource.
- Listener: private frontend only.
- Routing rule: private listener only.
- Private Link configuration: associated with `frontend-private`.
- Backend pool: private endpoint IP or private backend service.

Do not attach any listener or routing rule to the public frontend.

## Step 1: Collect Inputs

From Databricks:

- Account ID.
- Workspace ID.
- Workspace region.
- Account admin authentication.
- Decision on whether to reuse an existing NCC or create a dedicated NCC.

From Azure:

- Subscription ID.
- Resource group.
- Region matching the Databricks workspace.
- Transit VNet CIDR.
- Subnet CIDRs.
- Permission to create Application Gateway, Public IP, NSG, Private Endpoints,
  and approve Private Endpoint connections.

From Confluent Cloud:

- Private Link service alias per cluster zone.
- Bootstrap server.
- Private DNS domain and wildcard names that Kafka clients may dial.
- Topic name for validation.
- API key and secret with produce and consume permissions.

## Step 2: Deploy The Backend Private Target

For Confluent Cloud, create one Azure Private Endpoint per Confluent Private
Link service alias. In the simple single-zone pattern this is one endpoint. In a
multi-zone production pattern this is one endpoint per zone.

Validation gate:

- Azure Private Endpoint provisioning state is `Succeeded`.
- Confluent endpoint connection is approved.
- Private IP addresses are known.

## Step 3: Deploy Application Gateway

Deploy Application Gateway v2 with:

- Required public IP resource.
- Private frontend IP.
- Private listener only.
- Backend pool pointing to the private backend IP.
- Private Link configuration associated with the private frontend.

The live proof attempted a private-only `Standard_v2` gateway first. Azure
rejected it with a SKU validation error. Do not spend production time trying to
force private-only `Standard_v2`; use the controlled fallback or choose the PLS
plus proxy design.

Validation gate:

```bash
az network application-gateway show \
  --resource-group <rg> \
  --name <appgw> \
  --query "{state:provisioningState,operational:operationalState,frontends:frontendIPConfigurations[].name,listeners:httpListeners[].frontendIPConfiguration.id}"
```

Confirm:

- `provisioningState` is `Succeeded`.
- `operationalState` is `Running`.
- The only listener references the private frontend.
- The public frontend exists but is unused.

## Step 4: Attach NSG Controls

Attach an NSG to the Application Gateway subnet.

Required inbound rules:

| Priority | Name | Source | Destination port | Action | Purpose |
| --- | --- | --- | --- | --- | --- |
| 100 | `Allow-GatewayManager-AppGwV2` | `GatewayManager` | `65200-65535` | Allow | Required Application Gateway v2 infrastructure access. |
| 110 | `Allow-AzureLoadBalancer` | `AzureLoadBalancer` | `*` | Allow | Required Azure load balancer health probes. |
| 120 | `Allow-Private-Http` or protocol-specific equivalent | `VirtualNetwork` | Application port, for example `80` or `9092` | Allow | Private clients through Private Link. |
| 200 | `Deny-Internet-Inbound` | `Internet` | `*` | Deny | Explicit public Internet block. |

For Kafka, replace the HTTP port with the Kafka listener port, usually `9092`.
If you use TLS/TCP listeners, keep the same source and deny strategy.

Validation gate:

```bash
az network nsg rule list \
  --resource-group <rg> \
  --nsg-name <nsg> \
  --query "[].{name:name,priority:priority,access:access,direction:direction,source:sourceAddressPrefix,destPort:destinationPortRange}" \
  -o table
```

Confirm:

- The `Internet` source has an explicit inbound deny before the default rules.
- Private client traffic is allowed only from private address sources.
- Application Gateway remains `Running`.
- Backend health remains healthy.

## Step 5: Create Or Select The NCC

Create a regional NCC if one is not already assigned to the workspace:

```bash
databricks account network-connectivity create-network-connectivity-configuration \
  <ncc-name> <region> \
  -p <account-profile> \
  -o json
```

Bind the workspace to the NCC:

```bash
databricks account workspaces update <workspace-id> \
  --network-connectivity-config-id <ncc-id> \
  --update-mask network_connectivity_config_id \
  --expected-workspace-status RUNNING \
  -p <account-profile> \
  -o json
```

Validation gate:

```bash
databricks account workspaces get <workspace-id> \
  -p <account-profile> \
  -o json
```

Confirm `network_connectivity_config_id` matches the intended NCC.

## Step 6: Create The NCC Private Endpoint Rule

Create a private endpoint rule targeting the Application Gateway resource ID.
For Application Gateway, the `group_id` must match the frontend IP
configuration name exposed through Private Link.

```bash
databricks account network-connectivity create-private-endpoint-rule <ncc-id> \
  --json '{
    "resource_id": "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/applicationGateways/<appgw>",
    "group_id": "frontend-private",
    "domain_names": [
      "<bootstrap-or-test-fqdn>",
      "*.example.private.kafka.domain"
    ]
  }' \
  -p <account-profile> \
  -o json
```

For Confluent Cloud, the `domain_names` list must include every hostname the
Kafka client may dial: bootstrap plus broker metadata hostnames or wildcard
domains.

Validation gate:

```bash
databricks account network-connectivity get-private-endpoint-rule \
  <ncc-id> <rule-id> \
  -p <account-profile> \
  -o json
```

The rule will usually start as `PENDING`.

## Step 7: Approve The Azure Private Endpoint Connection

After Databricks creates the managed Private Endpoint, approve the pending
connection on the Application Gateway.

If the Azure CLI has first-class private endpoint connection commands for your
installed version, use those. Otherwise, read and approve the child resource via
ARM:

```bash
az network application-gateway show \
  --resource-group <rg> \
  --name <appgw> \
  --query "privateEndpointConnections[].{name:name,id:id,state:properties.privateLinkServiceConnectionState.status}"
```

Then approve the pending child resource using `az rest` with the current child
resource body and `privateLinkServiceConnectionState.status` set to `Approved`.

Validation gate:

- Azure private endpoint connection status is `Approved`.
- Azure child resource provisioning state is `Succeeded`.
- Databricks NCC private endpoint rule becomes `ESTABLISHED`.

## Step 8: Validate Private Dataplane From Databricks Serverless

Use a serverless notebook or one-time job. The minimum validation is:

1. Resolve the FQDN that NCC intercepts.
2. Confirm the resolved IP is private.
3. Open a socket or protocol connection.
4. Perform an application-level operation.

For a generic HTTP proof:

```python
import socket
import urllib.request

host = "<private-fqdn>"
print(socket.getaddrinfo(host, 80, proto=socket.IPPROTO_TCP))

with urllib.request.urlopen(f"http://{host}/", timeout=20) as response:
    print(response.status)
    print(response.read(200))
```

For Confluent Kafka, use `examples/appgw/kafka_topic_smoke_test.py`. A real
enterprise validation should write to and read from a topic, not only test TCP
connectivity.

Validation gate:

- Serverless job succeeds.
- DNS resolves to a private address.
- Kafka produce and consume succeed, or HTTP test returns the expected backend
  response for a non-Kafka proof.

## Step 9: Validate Public Isolation

Prove both configuration and behavior.

Configuration checks:

```bash
az network application-gateway show \
  --resource-group <rg> \
  --name <appgw> \
  --query "{frontends:frontendIPConfigurations[].name,listeners:httpListeners[].frontendIPConfiguration.id,rules:requestRoutingRules[].httpListener.id}"

az network nsg rule list \
  --resource-group <rg> \
  --nsg-name <nsg> \
  -o table
```

Behavior check from outside the VNet:

```bash
curl --noproxy '*' -m 8 http://<public-ip>/
```

Expected result:

- No listener is bound to the public frontend.
- NSG has explicit inbound deny from `Internet`.
- Direct public request cannot connect.
- Private Databricks serverless request still succeeds.

## Step 10: Production Hardening

Before production use, add these controls:

- Use capacity `2` or autoscale for Application Gateway high availability.
- Use zone-redundant subnets and zonal Confluent endpoints where required.
- Emit Application Gateway access logs, performance logs, and firewall/NSG flow
  logs to the enterprise logging platform.
- Monitor NCC private endpoint rule state.
- Monitor backend health and alert on degraded probes.
- Store Confluent credentials in Databricks secrets or a governed secret store.
- Keep DNS names under change control; Kafka broker metadata names are
  load-bearing.
- Document the public-IP exception as "required by Azure, unused by listener,
  denied by NSG, and tested unreachable."

## Live Proof Evidence

The proof deployment in `rg-davidokeeffe-05` validated the pattern with a
private HTTP backend:

| Evidence | Result |
| --- | --- |
| Private-only `Standard_v2` attempt | Failed Azure validation because `Standard_v2` requires a public IP. |
| App Gateway | `agw-nccproof05`, `Succeeded`, `Running`. |
| Listener | Only `listener-http-private`, bound to `frontend-private`. |
| Public frontend | `frontend-public-unused`, no listener. |
| NSG | `nsg-nccproof-appgw` attached to `snet-appgw`. |
| Public deny | `Deny-Internet-Inbound`, source `Internet`, destination `*`, priority `200`. |
| NCC | `3de05356-9377-4119-8dbe-a427bbcf4d06`. |
| NCC PE rule | `e2ade178-4c32-47d9-ae60-1f3777d680d8`, `ESTABLISHED`. |
| Serverless DNS | `agw-nccproof05.dbxdemo.net` resolved to `172.22.112.8`. |
| Serverless app response | HTTP `200` from private backend. |
| Public behavior | Direct proxy-bypassed request to public IP port 80 failed to connect. |
| Backend health | `Healthy`, probe received HTTP `200`. |

This proves the enterprise-safe App Gateway fallback: private dataplane works
through Databricks NCC, and the required public IP is not a public ingress path.
