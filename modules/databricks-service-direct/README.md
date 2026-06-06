# Module: `databricks-service-direct`

Inbound **"service-direct"** Private Link to Databricks **performance-intensive
services** (Zerobus Ingest, Lakebase Autoscaling) on Azure.

This is the *inbound* counterpart to the rest of this repo (which is about
*outbound* Serverless → Kafka via NCC). Read
[`../../docs/service-direct-privatelink.md`](../../docs/service-direct-privatelink.md)
for the rationale and the idiosyncrasies this module encodes.

> **Status — Public Preview.** Both the platform feature and the
> `databricks_endpoint` resource (provider ≥ v1.107.0) are in Public Preview.
> Confirm with a real `terraform plan/apply` before production use.

## What it creates

1. **`azurerm_private_endpoint`** → the Databricks per-region PLS for
   performance-intensive services, target sub-resource `service_direct`
   (`is_manual_connection = true`).
2. **`azurerm_private_dns_zone`** `privatelink.azuredatabricks.net` (optional —
   reuse an existing one) + VNet links + an **A record `<region>.service-direct`**
   pointing at the PE's private IP.
3. **`databricks_endpoint`** → registers the PE on the Databricks account side,
   driving it `PENDING` → `APPROVED` (`use_case = SERVICE_DIRECT`).

## Usage

```hcl
provider "databricks" {
  alias      = "account"                              # MUST be account-level
  host       = "https://accounts.azuredatabricks.net"
  account_id = var.databricks_account_id
}

module "service_direct" {
  source = "../../modules/databricks-service-direct"

  providers = { databricks = databricks.account }

  region                     = "australiaeast"
  resource_group_name        = "rg-service-direct-pe"
  private_endpoint_subnet_id = "/subscriptions/.../subnets/pe-subnet"
  databricks_pls_resource_id = "/subscriptions/.../privateLinkServices/<pls>"
  databricks_account_id      = var.databricks_account_id

  create_private_dns_zone = true
  vnet_ids_to_link        = ["/subscriptions/.../virtualNetworks/<vnet>"]
}
```

A runnable caller lives in [`../../examples/service-direct/`](../../examples/service-direct/).

## Provider requirements

| Provider | Version | Why |
|---|---|---|
| `databricks` | `>= 1.107.0`, **account-level** | `databricks_endpoint` (added v1.107.0) |
| `azurerm` | `>= 3.80.0` | private endpoint + private DNS |
| `azapi` | `>= 2.0.0` | reads the PE's `properties.resourceGuid` (azurerm doesn't export it) |
| `time` | `>= 0.9.0` | PE settle delay before account-side registration |

## Inputs you must supply

- **`databricks_pls_resource_id`** — the per-region PLS resource ID for
  performance-intensive services. Databricks manages these per region; pull the
  current value from the MS Learn region table and don't hard-code long-term:
  <https://learn.microsoft.com/en-us/azure/databricks/resources/ip-domain-region#service-direct-resource-ids>
- **`private_endpoint_subnet_id`** — an existing subnet with PE network policies
  disabled (Azure default); different from the workspace's own subnets.
- **`databricks_account_id`** — and the account-level `databricks` provider.

## Preview-era caveats baked into this module

- **PLS + sub-resource shape.** MS Learn says connect by the PLS *resource ID*
  with sub-resource `service_direct`, so the module uses
  `private_connection_resource_id` + `subresource_names = ["service_direct"]`.
  If a future provider/platform change treats the target as a pure Private Link
  Service, `azurerm` may reject `subresource_names` — switch to
  `private_connection_resource_alias` and drop `subresource_names`.
- **`resourceGuid` via azapi.** `databricks_endpoint` needs the PE's
  `properties.resourceGuid`, which `azurerm` does not export; the module reads
  it (and the private IP) from raw ARM via an `azapi_resource` data source.
- **Account-level + regional blast radius.** Registering this endpoint affects
  **all Premium workspaces in the region** — it is not workspace-scoped. Plan it
  as a regional decision. Limits: 5 per region, 100 per account.

## Outputs

`private_endpoint_id`, `private_endpoint_name`, `private_endpoint_resource_guid`,
`private_ip_address`, `dns_fqdn`, `dns_zone_name`, `endpoint_id`,
`endpoint_state`, `endpoint_use_case`, `connection_summary`.
