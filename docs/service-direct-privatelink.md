# Reference — Azure Databricks "service-direct" Private Link (inbound, performance-intensive services)

A distilled reference for **service-direct Private Link** on Azure Databricks —
the inbound (front-end) Private Link path for *performance-intensive services*,
currently **Zerobus Ingest** and **Lakebase Autoscaling**.

This is a *companion* to the rest of this repo, not part of the Serverless →
Kafka path. The repo's core pattern ([`pattern.md`](pattern.md)) is about
**outbound** connectivity *from* Serverless compute via NCC private-endpoint
rules. service-direct is the opposite direction: **inbound** private
connectivity *to* Databricks-hosted performance-intensive services. They share
the word "Private Link" and the `privatelink.azuredatabricks.net` DNS zone, and
almost nothing else — which is exactly why they get conflated.

> **Status:** Public Preview as of 2026-05 (per Microsoft Learn). Re-check GA
> status before quoting timelines to a customer.

## TL;DR

"service-direct" is **not** the classic workspace front-end Private Link
(the `databricks_ui_api` sub-resource that fronts the web app + REST API).
It is a separate, newer construct:

- It privately exposes **performance-intensive services** — today **Zerobus
  Ingest** and **Lakebase Autoscaling** — to clients in your VNet.
- The private endpoint targets a **per-region Databricks-published Private
  Link Service resource ID**, with **target sub-resource `service_direct`**
  (underscore, not hyphen) — *not* the workspace resource and *not*
  `databricks_ui_api`.
- DNS reuses the `privatelink.azuredatabricks.net` zone, with an **A record
  named `<region>.service-direct`** pointing at the private-endpoint IP. So the
  resolvable name is `<region>.service-direct.privatelink.azuredatabricks.net`.
- It is **account-level and regional**: registering one endpoint
  automatically affects **all Premium workspaces in that region**.

## The idiosyncrasies (in order of how often each bites)

### 1. Account-level + regional blast radius

This is the biggest surprise relative to classic front-end Private Link.
A performance-intensive-services private endpoint is **registered at the
account level and automatically applies to every Premium workspace in the
same region** — it is not scoped to a single workspace. Plan it as a regional
networking decision, not a per-workspace one. (Limit: 5 such endpoints per
region, 100 per account.)

### 2. Gated behind a Public-Preview self-enrollment feature

The account must be on the **Premium tier**, and you must enable the
**"Private connectivity for performance-intensive services"** Public Preview
feature from the account console. **Until that feature is enabled, the private
endpoints do not appear in the account console at all** — the classic
"the option I'm reading about isn't in my UI" confusion. Enable the feature
first, then the registration surface appears.

### 3. The target sub-resource is `service_direct`, against a regional PLS

When you create the Azure private endpoint, you:

- choose **"Connect to an Azure resource by resource ID or alias"**,
- enter the **Private Link Service resource ID for performance-intensive
  services for your region** (Databricks publishes these per region), and
- set **Target sub-resource = `service_direct`**.

It is easy to wrongly reuse the workspace's `databricks_ui_api` group ID or the
workspace resource ID here — neither works for this path.

### 4. DNS: reuse the `privatelink.azuredatabricks.net` zone, add a `<region>.service-direct` A record

DNS is configured **manually** (see #5). The steps:

1. Use (or create) the Azure private DNS zone **`privatelink.azuredatabricks.net`**.
   If the workspace already uses inbound Private Link, **reuse the existing
   zone** rather than creating a second one.
2. **Link** that zone to the VNet hosting the private endpoint.
3. Add an **A record**:
   - **Name:** `<region>.service-direct` (e.g. `westus2.service-direct`)
   - **Type:** A
   - **IP:** the private endpoint's private IP
     (`properties.customDnsConfigs[0].ipAddresses[0]` in the PE's JSON view)

Verify resolution from inside the VNet (or a workspace job attached to the
zone):

```bash
dig +short westus2.service-direct.privatelink.azuredatabricks.net
# → returns the private endpoint IP
```

### 5. "Integrate with private DNS zone = No" at creation time

During private-endpoint creation, leave **Integrate with private DNS zone**
set to **No**. Azure's auto-integration writes a record that does not match the
`<region>.service-direct` naming this path expects; you create the A record
manually in step 4 instead.

### 6. The endpoint sits in `Pending` until you register it

After the Azure-side private endpoint deploys, its connection state shows
**`Pending`**. This is expected — it stays `Pending` until you **register the
endpoint in the Databricks account console** (Security → Networking →
Endpoints → Register endpoint), using the PE's **Resource GUID**
(`properties.resourceGuid` in the PE's JSON view). `Pending` reads like a
failure but isn't; complete the registration and it transitions.

### 7. AWS vs Azure DNS-suffix divergence

The `service-direct` label is consistent across clouds, but the zone suffix
is not. When reading cross-cloud notes or `dig` output, watch the suffix:

| Cloud | Resolvable name |
|---|---|
| **Azure** | `<region>.service-direct.privatelink.azuredatabricks.net` |
| **AWS** | `<region>.service-direct.privatelink.cloud.databricks.com` |

On AWS the Lakebase endpoint host (`<instance>.database.<region>.cloud.databricks.com`)
resolves through the `<region>.service-direct.privatelink.cloud.databricks.com`
chain. The Azure equivalent rides `privatelink.azuredatabricks.net`. Mixing the
two suffixes is a common copy-paste error in playbooks that started life on the
other cloud.

### 8. Private-only is a *separate*, independent toggle

Completing service-direct Private Link does **not** block public internet
access on its own. Public and private access are independent settings. To
enforce private-only, set **Allow Public Network Access = Disable** on the
workspace resource (Azure portal → workspace → Settings). Do this deliberately,
after verifying private resolution works — not before.

### 9. Private-Link-locked workspaces resolve only `privatelink` hostnames

Once a workspace's network is locked to Private Link, clients in that network
resolve **only** hostnames under the `privatelink` DNS zones. Any flow that
hands back a **non-privatelink control-plane host** — for example an OAuth
callback or redirect that returns a public `<region>.cloud.databricks.com`
URL — can fail to resolve from inside the locked-down network, breaking the
flow even though the rest of the path is healthy.

Validate third-party OAuth / redirect flows (identity federation, partner
connectors, SaaS integrations) against the private-only posture **before**
cutover, and confirm any redirect hosts are reachable under the private DNS
zones.

## How this differs from classic front-end Private Link

| | Classic front-end PL | service-direct PL |
|---|---|---|
| **What it fronts** | Workspace web app + REST API (`/api/*`, `/oidc/v1/token`) | Performance-intensive services: Zerobus Ingest, Lakebase Autoscaling |
| **PE sub-resource** | `databricks_ui_api` | `service_direct` |
| **PE target** | The workspace resource | A per-region Databricks PLS resource ID |
| **Scope** | Per workspace | Per account, per region (affects all Premium workspaces in-region) |
| **DNS zone** | `privatelink.azuredatabricks.net` | `privatelink.azuredatabricks.net` (same zone) |
| **DNS record** | Workspace host A record | `<region>.service-direct` A record |
| **Maturity** | GA | Public Preview (as of 2026-05) |

Both can coexist and reuse the same `privatelink.azuredatabricks.net` zone.

## What this reference does NOT cover

- **The Serverless → Kafka outbound path** — that is the rest of this repo;
  start at [`pattern.md`](pattern.md).
- **Per-region PLS resource IDs** — those are published by Databricks and
  change over time; pull them from the current Microsoft Learn region table
  rather than hard-coding.
- **Terraform for this path** — this is a reference note; the steps above are
  portal/account-console flows. Provider coverage for the
  performance-intensive-services endpoint should be re-checked before
  automating, as the feature is in Public Preview.

## See also

- [`pattern.md`](pattern.md) — the repo's core outbound Serverless → Kafka pattern.
- [`why-transit.md`](why-transit.md) — long-form rationale for the outbound transit.
- Microsoft Learn — *Configure inbound Private Link for performance-intensive
  services* (the authoritative source for this note):
  <https://learn.microsoft.com/en-us/azure/databricks/security/network/front-end/service-direct-privatelink>
- Microsoft Learn — *Configure inbound (front-end) Private Link* (classic
  workspace front-end PL):
  <https://learn.microsoft.com/en-us/azure/databricks/security/network/front-end/front-end-private-connect>
