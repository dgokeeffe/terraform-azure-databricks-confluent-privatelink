# =============================================================================
# Local variables
# =============================================================================

locals {
  prefix = var.name_prefix != "" ? "${var.name_prefix}-" : ""

  vnet_name_for_subnets = var.create_vnet ? azurerm_virtual_network.transit[0].name : var.vnet_name
  vnet_resource_group   = var.create_vnet ? var.resource_group_name : var.existing_vnet_resource_group
  vnet_id               = var.create_vnet ? azurerm_virtual_network.transit[0].id : var.existing_vnet_id

  lb_subnet_id   = var.create_subnets ? azurerm_subnet.lb[0].id : var.existing_lb_subnet_id
  pe_subnet_id   = var.create_subnets ? azurerm_subnet.pe[0].id : var.existing_pe_subnet_id
  vmss_subnet_id = var.create_subnets ? azurerm_subnet.vmss[0].id : var.existing_vmss_subnet_id

  default_tags = {
    ManagedBy = "terraform"
    Module    = "vmss-haproxy-transit"
    Purpose   = "databricks-serverless-to-confluent"
  }

  tags = merge(local.default_tags, var.tags)
}

# =============================================================================
# Virtual Network (optional)
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
# Subnets (optional)
# =============================================================================

resource "azurerm_subnet" "lb" {
  count = var.create_subnets ? 1 : 0

  name                 = var.lb_subnet_name
  resource_group_name  = var.create_vnet ? var.resource_group_name : local.vnet_resource_group
  virtual_network_name = local.vnet_name_for_subnets
  address_prefixes     = [var.lb_subnet_address_prefix]

  private_link_service_network_policies_enabled = false

  depends_on = [azurerm_virtual_network.transit]
}

resource "azurerm_subnet" "pe" {
  count = var.create_subnets ? 1 : 0

  name                 = var.pe_subnet_name
  resource_group_name  = var.create_vnet ? var.resource_group_name : local.vnet_resource_group
  virtual_network_name = local.vnet_name_for_subnets
  address_prefixes     = [var.pe_subnet_address_prefix]

  private_endpoint_network_policies = "Disabled"

  depends_on = [azurerm_virtual_network.transit]
}

resource "azurerm_subnet" "vmss" {
  count = var.create_subnets ? 1 : 0

  name                 = var.vmss_subnet_name
  resource_group_name  = var.create_vnet ? var.resource_group_name : local.vnet_resource_group
  virtual_network_name = local.vnet_name_for_subnets
  address_prefixes     = [var.vmss_subnet_address_prefix]

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
    ignore_changes = [
      private_service_connection[0].private_connection_resource_id
    ]
  }

  depends_on = [azurerm_subnet.pe]
}

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
  sku                 = "Standard"
  sku_tier            = "Regional"
  tags                = local.tags

  frontend_ip_configuration {
    name                          = "frontend-confluent"
    subnet_id                     = local.lb_subnet_id
    private_ip_address_allocation = var.lb_frontend_ip != "" ? "Static" : "Dynamic"
    private_ip_address            = var.lb_frontend_ip != "" ? var.lb_frontend_ip : null
    private_ip_address_version    = "IPv4"
  }

  depends_on = [azurerm_subnet.lb]
}

# =============================================================================
# LB backend pool - targets VMSS (not PE IPs)
# =============================================================================

resource "azurerm_lb_backend_address_pool" "haproxy" {
  name            = "backend-haproxy-vmss"
  loadbalancer_id = azurerm_lb.transit.id
}

# =============================================================================
# Health probe and LB rule
# =============================================================================

resource "azurerm_lb_probe" "kafka" {
  name                = "probe-kafka-${var.kafka_port}"
  loadbalancer_id     = azurerm_lb.transit.id
  protocol            = "Tcp"
  port                = var.kafka_port
  interval_in_seconds = 5
  number_of_probes    = 2
}

resource "azurerm_lb_rule" "kafka" {
  name                           = "rule-kafka-${var.kafka_port}"
  loadbalancer_id                = azurerm_lb.transit.id
  protocol                       = "Tcp"
  frontend_port                  = var.kafka_port
  backend_port                   = var.kafka_port
  frontend_ip_configuration_name = "frontend-confluent"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.haproxy.id]
  probe_id                       = azurerm_lb_probe.kafka.id

  enable_floating_ip      = false
  enable_tcp_reset        = true
  idle_timeout_in_minutes = 4
  disable_outbound_snat   = true
  load_distribution       = "Default"
}

# =============================================================================
# VMSS with HAProxy (cloud-init provisioned)
# =============================================================================

resource "azurerm_linux_virtual_machine_scale_set" "haproxy" {
  name                = "${local.prefix}${var.vmss_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = var.vmss_sku
  instances           = var.vmss_instances
  admin_username      = var.vmss_admin_username
  tags                = local.tags

  admin_ssh_key {
    username   = var.vmss_admin_username
    public_key = var.vmss_admin_ssh_public_key
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  os_disk {
    storage_account_type = "Standard_LRS"
    caching              = "ReadWrite"
  }

  network_interface {
    name    = "nic-haproxy"
    primary = true

    ip_configuration {
      name                                   = "ipconfig-haproxy"
      primary                                = true
      subnet_id                              = local.vmss_subnet_id
      load_balancer_backend_address_pool_ids = [azurerm_lb_backend_address_pool.haproxy.id]
    }
  }

  custom_data = base64encode(
    templatefile("${path.module}/templates/cloud-init.yaml.tpl", {
      haproxy_cfg = indent(6, templatefile("${path.module}/templates/haproxy.cfg.tpl", {
        kafka_port      = var.kafka_port
        confluent_pe_ip = azurerm_private_endpoint.confluent.private_service_connection[0].private_ip_address
      }))
    })
  )

  upgrade_mode = "Manual"

  depends_on = [
    time_sleep.wait_for_pe,
    azurerm_lb_rule.kafka
  ]
}

# =============================================================================
# Private Link Service (exposes LB to Databricks)
# =============================================================================

resource "azurerm_private_link_service" "transit" {
  name                = "${local.prefix}${var.pls_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = local.tags

  load_balancer_frontend_ip_configuration_ids = [
    azurerm_lb.transit.frontend_ip_configuration[0].id
  ]

  dynamic "nat_ip_configuration" {
    for_each = range(var.pls_nat_ip_count)
    content {
      name                       = nat_ip_configuration.value == 0 ? "nat-primary" : "nat-secondary-${nat_ip_configuration.value}"
      subnet_id                  = local.lb_subnet_id
      private_ip_address_version = "IPv4"
      primary                    = nat_ip_configuration.value == 0
    }
  }

  auto_approval_subscription_ids = var.pls_auto_approval_subscription_ids
  visibility_subscription_ids    = var.pls_visibility_subscription_ids
}
