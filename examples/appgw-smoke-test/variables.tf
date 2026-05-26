variable "azure_subscription_id" {
  description = "Azure subscription ID to deploy the smoke test into."
  type        = string
}

variable "resource_group_name" {
  description = "Existing resource group to deploy into. Will NOT be created or destroyed by this terraform."
  type        = string
}

variable "databricks_account_id" {
  description = "Databricks account UUID. NCC creation and the App GW PE rule REST call require this."
  type        = string
}

variable "databricks_workspace_id" {
  description = "Numeric Databricks workspace ID to bind the NCC to."
  type        = string
}

variable "databricks_host" {
  description = "Databricks account-level API host."
  type        = string
  default     = "https://accounts.azuredatabricks.net"
}

variable "azure_tenant_id" {
  description = "Azure AD tenant ID that the Databricks account is registered against. Required explicitly because az-cli auth otherwise picks the user's default tenant, which may differ when the user has guest access to multiple tenants."
  type        = string
}

variable "test_fqdn" {
  description = "Arbitrary FQDN to register in the NCC PE rule. Used by the notebook test and by the backend's self-signed TLS cert SAN. AVOID reserved TLDs (.internal, .local, .test) — Databricks NCC rejects these. Use a real-public-looking domain that isn't resolvable in practice. example.com is RFC 2606 reserved for documentation, which suits us."
  type        = string
  default     = "smoke-broker.appgw-test.example.com"
}
