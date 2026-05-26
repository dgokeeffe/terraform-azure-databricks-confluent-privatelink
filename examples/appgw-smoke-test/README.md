# App Gateway v2 TCP/TLS Smoke Test

A self-contained end-to-end test that **proves the core architecture works**:
Databricks Serverless compute can reach a TLS-protected backend through an
Azure Application Gateway v2 TCP/TLS proxy, with NCC handling the
Databricks-side private endpoint and DNS injection.

The backend is a mock socat-based TLS echo, so this test isolates the
network-and-proxy layers (L1-L4) from the eventual Kafka or Confluent
application layer.

## What this validates

| Layer | What it proves |
|---|---|
| **L1 — DNS injection** | NCC's managed DNS resolves the registered FQDN to a Databricks-managed PE IP from inside Serverless |
| **L2 — TCP path** | Traffic flows Serverless → PE → Azure backbone → App GW frontend |
| **L3 — TLS passthrough** | App GW's TCP/TLS listener carries a TLS 1.3 handshake intact, without termination — the peer cert returned to the client is the *backend's* cert |
| **L4 — Round-trip echo** | Bidirectional bytes traverse the full chain and return unchanged |

A successful run produces a **Databricks Jobs run URL** in the workspace —
durable, auditable evidence that anyone with workspace access can inspect:

```
https://adb-<workspace-id>.<shard>.azuredatabricks.net/jobs/runs/<run-id>
```

### Optional: Kafka producer + consumer validation

The L1-L4 smoke test above uses a mock TLS-echo backend (socat). For a
deeper proof that exercises the full Kafka wire protocol, swap the backend
for a real Apache Kafka broker:

```bash
# 1. Replace socat with Apache Kafka 3.7 (KRaft mode) on the backend VM.
#    A reference install script lives at /tmp/install-kafka.sh in this
#    session — or write your own to: install Java 17, download Kafka,
#    configure server.properties with
#      advertised.listeners=PLAINTEXT://<your test_fqdn>:9092
#    and start as a systemd unit.
#    Add /etc/hosts entry on the VM so local admin tools can resolve the
#    advertised FQDN to 127.0.0.1.

# 2. Submit a Spark Kafka producer + consumer Job from Serverless:
export DATABRICKS_HOST=https://adb-<your-workspace>.azuredatabricks.net
uv run python submit_kafka_job.py
```

The submitter:
- Uploads a notebook to `/Users/<your-email>/kafka-producer-consumer-smoke-test`
- Submits a one-time Serverless Job
- The notebook produces N rows to the topic via `df.write.format("kafka")`,
  reads them back via `spark.read.format("kafka")`, and verifies a full
  round-trip match
- Returns a Jobs run URL

A successful run validates additional layers that the socat test cannot:

| Layer | What it proves |
|---|---|
| **L5 — Kafka bootstrap** | Spark client opens initial connection to `bootstrap.servers` through the proxy |
| **L6 — Metadata response handling** | Broker returns `advertised.listeners` matching the registered NCC FQDN; client re-resolves and connects via the same NCC + App GW path |
| **L7 — Produce request** | Spark's `df.write.format("kafka")` lands rows on the broker through the proxy |
| **L8 — Fetch request** | Spark's `spark.read.format("kafka")` retrieves rows through the proxy |

This validates the most production-realistic behaviour — the same
two-hop FQDN re-resolution Confluent Cloud clients perform.

## What this does NOT yet validate

These layers are independent of the App Gateway TCP/TLS proxy mechanism and
need their own validations when the target moves from mock backend to a real
Confluent Cloud cluster:

1. The customer-tenant PE → Confluent Cloud PLS handshake (cross-tenant
   alias-based PE creation; needs Confluent approval).
2. The Kafka wire protocol on top of the TLS path — bootstrap, metadata
   exchange, per-partition leader connections, `advertised.listeners`
   re-resolution.
3. Confluent Cloud Schema Registry (separate `psrc-*` FQDN, separate
   Confluent PLS, would need its own NCC PE rule and transit listener).
4. Kafka Connect on AKS, if used. Connect is a *parallel* data-integration
   tier — it doesn't sit in the network path between Databricks and
   Confluent Cloud Kafka. Customer-side outbound (Connect → Confluent) is
   their own concern; Databricks rarely needs to reach Connect's REST API.

## Prerequisites

- Azure subscription with quota for App Gateway v2 + 1 small Linux VM
- Existing resource group (this example deploys into it; does not create the RG)
- Azure CLI authenticated (`az login`) — the same session is used for both
  terraform and the Job submitter
- A Databricks Premium workspace in the same region as the resource group
- The workspace's account ID and numeric workspace ID
- Workspace user has CAN_MANAGE_RUN permission to submit jobs

## Configuration

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars to fill in your IDs
```

| Variable | Source |
|---|---|
| `azure_subscription_id` | `az account show --query id -o tsv` |
| `azure_tenant_id` | `az account show --query tenantId -o tsv` |
| `resource_group_name` | An existing RG in the target region |
| `databricks_account_id` | Databricks account console → user dropdown |
| `databricks_workspace_id` | Workspace settings or `databricks workspaces list` |
| `test_fqdn` | Anything **not** ending in `.internal`, `.local`, or `.test` (NCC rejects reserved TLDs). `example.com` is RFC 2606 reserved for documentation and works well. |

## Deploy + run

```bash
# 1. Provision App GW, NCC, PE rule, workspace binding, mock backend
terraform init
terraform apply

# 2. Approve the inbound PE on the App GW (auto-approve poller has CLI bug;
#    do this manually until terraform pattern is fixed)
PE_NAME=$(az rest --method GET \
  --url "$(terraform output -raw appgw_id)/privateEndpointConnections?api-version=2024-05-01" \
  --query "value[?starts_with(name, 'databricks-')].name | [0]" -o tsv)
az rest --method PUT \
  --url "$(terraform output -raw appgw_id)/privateEndpointConnections/${PE_NAME}?api-version=2024-05-01" \
  --body '{"properties":{"privateLinkServiceConnectionState":{"status":"Approved","description":"smoke"}}}'

# 3. Run the validation as a Serverless Job (produces shareable URL)
export DATABRICKS_HOST=https://adb-<your-workspace>.azuredatabricks.net
uv run python submit_job.py

# OR for faster iteration without notebook upload, use Databricks Connect:
uv run python run_test.py
```

The Job submitter uploads a notebook to `/Users/<your-email>/appgw-tls-smoke-test`
and submits a one-time run. Expect 30-90 seconds for the run to complete.

## Teardown

```bash
terraform destroy
```

Some sandbox subscriptions have resource locks at the subscription scope —
these will block deletion of VMs, NSGs, NICs, etc. Terraform will report
those failures but continue with what it can delete. Manual cleanup may be
needed if the lock is permanent.

## Gotchas encountered while building this (worked around in the code)

These bit us during development and are now handled in `main.tf` /
`variables.tf` / the scripts. Folding them in to save the next person.

| # | Issue | Workaround in this example |
|---|---|---|
| 1 | Azure VMs reject ED25519 SSH keys | `tls_private_key.vm_ssh` uses `algorithm = "RSA"`, `rsa_bits = 2048` |
| 2 | Databricks provider auth picks wrong tenant under multi-tenant az-cli auth | Explicit `azure_tenant_id` on the provider block |
| 3 | App GW v2 won't deploy without a public IP unless the `EnableApplicationGatewayNetworkIsolation` subscription feature flag is registered (registration is slow / unpredictable) | Provision a `azurerm_public_ip` and bind it to a `frontend-public` IP config; the listener still binds to that frontend |
| 4 | App GW v2 private frontend IP must be **Static** allocation, not Dynamic | `privateIPAllocationMethod = "Static"` + explicit `privateIPAddress` |
| 5 | NCC PE rule rejects reserved TLDs (`.internal`, `.local`, `.test`) — silently in earlier versions, with a clear error now | `test_fqdn` defaults to `*.example.com` |
| 6 | Subscription-level resource locks block VM replacement when cert changes propagate to `custom_data` | `lifecycle.ignore_changes = [custom_data, admin_ssh_key]` on the backend VM |
| 7 | App GW PE `group_id` must be the **frontend IP config name** (e.g., `frontend-public`), NOT the PL config name. Discovered via `az network private-link-resource list --type Microsoft.Network/applicationGateways` | REST body sets `"group_id":"frontend-public"` |
| 8 | App GW PL config must reference the frontend IP config it's bound to, not just exist standalone | Frontend IP config has `privateLinkConfiguration = { id = ... }` |
| 9 | `az network application-gateway private-link list` returns empty even when PE connections exist (CLI sub-command bug in current preview) | Manual approval via `az rest PUT` to `/privateEndpointConnections/<name>` |
| 10 | `databricks-connect>=18.2.0` is incompatible with Serverless sessions | `pyproject.toml` pins to `>=18.1,<18.2`, Python 3.12 |
| 11 | Sandbox VMs sometimes auto-stop after idle period; cloud-init may not re-run on restart | Re-provision socat manually via `az vm run-command` after VM restarts |
| 12 | App GW v2 takes ~20-25 min to provision on first apply; partial-fail-and-retry is common during iteration | Plan for the wait; terraform's incremental convergence handles partial state cleanly |

## How this maps to the production architecture

The production target — Databricks Serverless → Confluent Cloud Kafka over
Azure Private Link — uses the same five-layer pattern with three mechanical
substitutions:

```
This smoke test                          Production with Confluent Cloud
───────────────                          ──────────────────────────────
NCC PE rule resource_id = App GW    →    Same. App GW Resource ID.
NCC domain_names = ["smoke-broker"] →    Confluent FQDNs:
                                          - <cluster-id>.<network-id>.<region>.azure.confluent.cloud
                                          - *.<network-id>.<region>.azure.confluent.cloud
App GW backend = socat VM IP        →    App GW backend = PE IP pointing
                                          at Confluent's PLS (alias)
Client TLS: ssl.CERT_NONE           →    Client TLS: default CERT_REQUIRED
  (self-signed)                            (Confluent has public CA cert)
```

The App GW listener, the NCC binding, the PE handshake, the TLS passthrough
— all unchanged. The single new layer in production is the
`azurerm_private_endpoint` on the App GW backend pointing at Confluent's
service alias; that PE has its own approval flow with Confluent's side.

For the terraform that wires the production path, see
[`../full-stack/`](../full-stack/) which uses `modules/appgw-transit/` with
the full Confluent integration.

## Files

- `main.tf` — VNet, App GW v2 (TCP/TLS + PL), backend VM with socat,
  NCC + workspace binding, REST-based PE rule + approval poller
- `variables.tf` — input definitions
- `terraform.tfvars.example` — placeholder values to copy + customise
- `run_test.py` — Databricks Connect runner (fast iteration, ephemeral)
- `submit_job.py` — One-time Serverless Job submitter (durable URL proof)
- `pyproject.toml` / `uv.lock` — Python environment for the scripts
