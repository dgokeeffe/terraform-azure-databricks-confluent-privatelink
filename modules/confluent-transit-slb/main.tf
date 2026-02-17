# =============================================================================
# Local Variables
# =============================================================================

locals {
  # Naming
  prefix = var.name_prefix != "" ? "${var.name_prefix}-" : ""

  # Determine VNet name for subnet creation
  vnet_name_for_subnets = var.create_vnet ? azurerm_virtual_network.transit[0].name : var.vnet_name

  # Determine resource group for VNet operations
  vnet_resource_group = var.create_vnet ? var.resource_group_name : var.existing_vnet_resource_group

  # Determine subnet IDs
  lb_subnet_id = var.create_subnets ? azurerm_subnet.lb[0].id : var.existing_lb_subnet_id
  pe_subnet_id = var.create_subnets ? azurerm_subnet.pe[0].id : var.existing_pe_subnet_id

  # Determine VNet ID for backend pool
  vnet_id = var.create_vnet ? azurerm_virtual_network.transit[0].id : var.existing_vnet_id

  # Kafka ports including optional REST proxy
  all_kafka_ports = var.enable_kafka_rest_proxy ? distinct(concat(var.kafka_ports, [443])) : var.kafka_ports

  # Default tags
  default_tags = {
    ManagedBy = "terraform"
    Module    = "confluent-transit-slb"
    Purpose   = "databricks-serverless-to-confluent"
  }

  tags = merge(local.default_tags, var.tags)
}

# =============================================================================
# Virtual Network (Optional)
# =============================================================================

resource "azurerm_virtual_network" "transit" {
  count = var.create_vnet ? 1 : 0

  name                = "${local.prefix}${var.vnet_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = var.vnet_address_space
  tags                = local.tags
}

# =============================================================================
# Subnets (Optional)
# =============================================================================

# Subnet for Load Balancer and Private Link Service
resource "azurerm_subnet" "lb" {
  count = var.create_subnets ? 1 : 0

  name                 = var.lb_subnet_name
  resource_group_name  = var.create_vnet ? var.resource_group_name : local.vnet_resource_group
  virtual_network_name = local.vnet_name_for_subnets
  address_prefixes     = [var.lb_subnet_address_prefix]

  # Required for Private Link Service
  private_link_service_network_policies_enabled = false

  depends_on = [azurerm_virtual_network.transit]
}

# Subnet for Private Endpoint to Confluent
resource "azurerm_subnet" "pe" {
  count = var.create_subnets ? 1 : 0

  name                 = var.pe_subnet_name
  resource_group_name  = var.create_vnet ? var.resource_group_name : local.vnet_resource_group
  virtual_network_name = local.vnet_name_for_subnets
  address_prefixes     = [var.pe_subnet_address_prefix]

  # Required for Private Endpoints
  private_endpoint_network_policies = "Disabled"

  depends_on = [azurerm_virtual_network.transit]
}

# =============================================================================
# Private Endpoint to Confluent Cloud
# =============================================================================

resource "azurerm_private_endpoint" "confluent" {
  name                = "${local.prefix}${var.pe_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = local.pe_subnet_id
  tags                = local.tags

  private_service_connection {
    name                              = "confluent-kafka-psc"
    private_connection_resource_alias = var.confluent_private_link_service_alias
    is_manual_connection              = true
    request_message                   = var.pe_request_message
  }

  lifecycle {
    # Confluent PE connection state changes after approval
    ignore_changes = [
      private_service_connection[0].private_connection_resource_id
    ]
  }

  depends_on = [
    azurerm_subnet.pe
  ]
}

# Wait for PE to be provisioned before creating LB backend
resource "time_sleep" "wait_for_pe" {
  depends_on = [azurerm_private_endpoint.confluent]

  create_duration = "30s"
}

# =============================================================================
# Azure Standard Load Balancer
# =============================================================================

resource "azurerm_lb" "transit" {
  name                = "${local.prefix}${var.lb_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = var.lb_sku
  sku_tier            = "Regional"
  tags                = local.tags

  frontend_ip_configuration {
    name                          = "frontend-confluent"
    subnet_id                     = local.lb_subnet_id
    private_ip_address_allocation = var.lb_frontend_ip != "" ? "Static" : "Dynamic"
    private_ip_address            = var.lb_frontend_ip != "" ? var.lb_frontend_ip : null
    private_ip_address_version    = "IPv4"
  }

  depends_on = [
    azurerm_subnet.lb
  ]
}

# =============================================================================
# Backend Address Pool
# =============================================================================

resource "azurerm_lb_backend_address_pool" "confluent" {
  name            = "backend-confluent-pe"
  loadbalancer_id = azurerm_lb.transit.id
}

# Add Confluent PE IP to backend pool
resource "azurerm_lb_backend_address_pool_address" "confluent_pe" {
  name                    = "confluent-pe-address"
  backend_address_pool_id = azurerm_lb_backend_address_pool.confluent.id
  virtual_network_id      = local.vnet_id
  ip_address              = azurerm_private_endpoint.confluent.private_service_connection[0].private_ip_address

  depends_on = [time_sleep.wait_for_pe]
}

# =============================================================================
# Health Probes - One per Kafka port
# =============================================================================

resource "azurerm_lb_probe" "kafka" {
  for_each = toset([for p in local.all_kafka_ports : tostring(p)])

  name                = "probe-kafka-${each.value}"
  loadbalancer_id     = azurerm_lb.transit.id
  protocol            = "Tcp"
  port                = tonumber(each.value)
  interval_in_seconds = var.health_probe_interval
  number_of_probes    = var.health_probe_count
}

# =============================================================================
# Load Balancing Rules - One per Kafka port
# =============================================================================

resource "azurerm_lb_rule" "kafka" {
  for_each = toset([for p in local.all_kafka_ports : tostring(p)])

  name                           = "rule-kafka-${each.value}"
  loadbalancer_id                = azurerm_lb.transit.id
  protocol                       = "Tcp"
  frontend_port                  = tonumber(each.value)
  backend_port                   = tonumber(each.value)
  frontend_ip_configuration_name = "frontend-confluent"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.confluent.id]
  probe_id                       = azurerm_lb_probe.kafka[each.value].id

  # LB configuration optimized for Kafka
  enable_floating_ip      = false
  enable_tcp_reset        = true
  idle_timeout_in_minutes = 4
  disable_outbound_snat   = true
  load_distribution       = "Default" # 5-tuple hash
}

# =============================================================================
# Private Link Service (Exposes LB to Databricks)
# =============================================================================

resource "azurerm_private_link_service" "transit" {
  name                = "${local.prefix}${var.pls_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = local.tags

  load_balancer_frontend_ip_configuration_ids = [
    azurerm_lb.transit.frontend_ip_configuration[0].id
  ]

  # NAT IP configurations for the PLS
  dynamic "nat_ip_configuration" {
    for_each = range(var.pls_nat_ip_count)
    content {
      name                       = nat_ip_configuration.value == 0 ? "nat-primary" : "nat-secondary-${nat_ip_configuration.value}"
      subnet_id                  = local.lb_subnet_id
      private_ip_address_version = "IPv4"
      primary                    = nat_ip_configuration.value == 0
    }
  }

  # Auto-approval settings
  auto_approval_subscription_ids = var.pls_auto_approval_subscription_ids
  visibility_subscription_ids    = var.pls_visibility_subscription_ids

  # Enable proxy protocol if needed (usually not for Kafka)
  enable_proxy_protocol = var.enable_proxy_protocol
}
