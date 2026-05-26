# =============================================================================
# Identity / scoping
# =============================================================================

variable "azure_subscription_id" {
  description = "Azure subscription ID where the transit infrastructure lives."
  type        = string
}

variable "location" {
  description = "Azure region. Must match Databricks workspace region AND Confluent Cloud cluster region."
  type        = string
}

variable "environment" {
  description = "Environment tag (dev / nonprod / prod)."
  type        = string
  default     = "prod"
}

variable "resource_group_name" {
  description = "Resource group to create for the transit. Use a dedicated RG to keep the lifecycle isolated."
  type        = string
  default     = "rg-confluent-transit"
}

variable "name_prefix" {
  description = "Optional prefix applied to all created resource names (helps when multiple transits live in the same RG)."
  type        = string
  default     = ""
}

variable "pe_request_message" {
  description = "Free-form message included with the PE-to-Confluent connection request (e.g., a change-management ticket reference)."
  type        = string
  default     = "Databricks serverless connectivity via transit architecture"
}

variable "extra_tags" {
  description = "Extra tags merged on top of the defaults (Workload, Environment, ManagedBy)."
  type        = map(string)
  default     = {}
}

# =============================================================================
# Confluent Cloud target
# =============================================================================

variable "confluent_cluster_id" {
  description = "Confluent Cloud cluster ID (e.g., lkc-XXXXXX)."
  type        = string

  validation {
    condition     = can(regex("^(pkc|lkc)-[a-z0-9]+$", var.confluent_cluster_id))
    error_message = "Confluent cluster ID must be in format: pkc-XXXXX or lkc-XXXXX"
  }
}

variable "confluent_network_id" {
  description = <<-EOT
    Confluent Network ID — the second component in the cluster FQDN for
    Dedicated/Enterprise clusters running in a Confluent Network.
    Cluster FQDN is {cluster-id}.{network-id}.{region}.azure.confluent.cloud.
    Find this in Confluent Cloud Console: Networks -> <network> -> Network ID.
  EOT
  type    = string
}

variable "confluent_private_link_service_alias" {
  description = <<-EOT
    Confluent Cloud Private Link Service alias.
    Fetch from: Confluent Cloud Console -> Cluster -> Settings ->
                Networking -> Private Link -> Azure Private Link Service alias.
    Typically of the form s-XXXXX.privatelink.confluent.cloud.
    NOTE: modern Dedicated/Enterprise clusters may publish a different
    alias format. If the transit module's regex rejects what Confluent
    gives you, contact Confluent support for the correct alias or relax
    the validation in modules/vmss-haproxy-transit/variables.tf.
  EOT
  type = string
}

variable "confluent_schema_registry_fqdn" {
  description = <<-EOT
    Optional: FQDN of the Confluent Cloud Schema Registry (if using
    Avro / Protobuf / JSON-Schema topics). Typically
    psrc-XXXXX.<region>.azure.confluent.cloud. Leave empty to skip.
    Note: Schema Registry uses a separate Confluent PLS — if registered
    here, the transit PE still proxies broker traffic only. To proxy
    SR traffic too, add a second PE/HAProxy chain (not in this example).
  EOT
  type    = string
  default = ""
}

# =============================================================================
# Transit VNet
# =============================================================================

variable "create_vnet" {
  description = "Create a new VNet for the transit, or use an existing one (set to false to reuse e.g. an existing platform VNet)."
  type        = bool
  default     = true
}

variable "vnet_name" {
  description = "Transit VNet name (created or referenced)."
  type        = string
  default     = "vnet-confluent-transit"
}

variable "vnet_address_space" {
  description = "Address space for the transit VNet (if creating). Pick something that does NOT overlap with on-prem / hub / spoke ranges."
  type        = list(string)
  default     = ["10.220.0.0/16"]
}

variable "existing_vnet_id" {
  description = "Resource ID of existing VNet (required if create_vnet = false)."
  type        = string
  default     = ""
}

variable "existing_vnet_resource_group" {
  description = "RG of existing VNet (required if create_vnet = false)."
  type        = string
  default     = ""
}

variable "lb_subnet_address_prefix" {
  description = "Subnet CIDR for the LB + PLS NAT pool. /27 minimum recommended; /28 only if traffic is light."
  type        = string
  default     = "10.220.1.0/27"
}

variable "pe_subnet_address_prefix" {
  description = "Subnet CIDR for the PE to Confluent. /28 is plenty (one PE = one NIC)."
  type        = string
  default     = "10.220.2.0/28"
}

variable "vmss_subnet_address_prefix" {
  description = "Subnet CIDR for HAProxy VMSS instances. /27 supports up to ~27 instances (Azure reserves 5 IPs)."
  type        = string
  default     = "10.220.3.0/27"
}

variable "lb_frontend_ip" {
  description = "Optional static private IP for the LB frontend (must be in the LB subnet range). Leave empty for dynamic allocation."
  type        = string
  default     = ""
}

# =============================================================================
# VMSS / HAProxy
# =============================================================================

variable "vmss_sku" {
  description = "VM size for HAProxy instances. Standard_B2s is fine for moderate throughput; bump to Standard_D2s_v5 for sustained > ~200 MB/s."
  type        = string
  default     = "Standard_B2s"
}

variable "vmss_instances" {
  description = "Number of HAProxy instances. Two is the minimum for HA; three if you want N+1 within the AZ for patching headroom."
  type        = number
  default     = 2
}

variable "vmss_admin_ssh_public_key" {
  description = "SSH public key for the HAProxy VMs. Required by Azure even though no human should SSH in normally."
  type        = string
}

variable "kafka_port" {
  description = "TCP port the LB / HAProxy / PE listen on. Confluent Cloud Kafka is 9092 (TLS terminates at the brokers, not the LB)."
  type        = number
  default     = 9092
}

variable "pls_nat_ip_count" {
  description = "Number of NAT IPs on the transit PLS. Each NAT IP supports ~64K concurrent connections. One is enough for most workloads."
  type        = number
  default     = 1
}

# =============================================================================
# Databricks
# =============================================================================

variable "databricks_account_id" {
  description = "Databricks account UUID. Find in account console -> User profile dropdown -> Account ID."
  type        = string
}

variable "databricks_workspace_ids" {
  description = "List of Databricks workspace IDs (numeric strings) to bind the new NCC to. If reusing an existing NCC, this can be empty."
  type        = list(string)
}

variable "ncc_name" {
  description = "Name for the NCC (only used if this terraform creates a new NCC; reuse pattern is in main.tf comments)."
  type        = string
  default     = "ncc-confluent"
}

variable "databricks_managed_subscription_id" {
  description = <<-EOT
    Databricks' managed serverless subscription ID for the target region.
    Populates the transit PLS's visibility + auto-approval allow-lists so
    the NCC's auto-provisioned PE attaches without manual approval.
    Find in: Databricks docs ->
      'Microsoft Azure subscriptions used by Databricks-managed services'
    (varies by region; check current value before applying).
  EOT
  type = string
}
