# =============================================================================
# Local variables
# =============================================================================

locals {
  prefix = var.name_prefix != "" ? "${var.name_prefix}-" : ""

  vnet_name_for_subnets = var.create_vnet ? azurerm_virtual_network.transit[0].name : var.vnet_name
  vnet_resource_group   = var.create_vnet ? var.resource_group_name : var.existing_vnet_resource_group
  vnet_id               = var.create_vnet ? azurerm_virtual_network.transit[0].id : var.existing_vnet_id

  appgw_subnet_id             = var.create_subnets ? azurerm_subnet.appgw[0].id : var.existing_appgw_subnet_id
  pe_subnet_id                = var.create_subnets ? azurerm_subnet.pe[0].id : var.existing_pe_subnet_id
  appgw_privatelink_subnet_id = var.create_subnets ? azurerm_subnet.appgw_privatelink[0].id : var.existing_appgw_privatelink_subnet_id

  appgw_full_name = "${local.prefix}${var.appgw_name}"

  default_tags = {
    ManagedBy = "terraform"
    Module    = "appgw-transit"
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

resource "azurerm_subnet" "appgw" {
  count = var.create_subnets ? 1 : 0

  name                 = var.appgw_subnet_name
  resource_group_name  = var.create_vnet ? var.resource_group_name : local.vnet_resource_group
  virtual_network_name = local.vnet_name_for_subnets
  address_prefixes     = [var.appgw_subnet_address_prefix]

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

resource "azurerm_subnet" "appgw_privatelink" {
  count = var.create_subnets ? 1 : 0

  name                 = var.appgw_privatelink_subnet_name
  resource_group_name  = var.create_vnet ? var.resource_group_name : local.vnet_resource_group
  virtual_network_name = local.vnet_name_for_subnets
  address_prefixes     = [var.appgw_privatelink_subnet_address_prefix]

  private_link_service_network_policies_enabled = false

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
    name                              = "confluent-kafka"
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
# Application Gateway v2 with TCP proxy (azapi - azurerm lacks TCP support)
#
# NOTE: TCP listener/routing on App GW v2 requires API version 2024-05-01+.
# The azurerm provider does not yet support TCP listeners.
# =============================================================================

resource "azurerm_public_ip" "appgw_management" {
  name                = "${local.prefix}${var.appgw_name}-unused-public-ip"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azapi_resource" "appgw" {
  type      = "Microsoft.Network/applicationGateways@2024-05-01"
  name      = local.appgw_full_name
  location  = var.location
  parent_id = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${var.resource_group_name}"
  tags      = local.tags

  body = {
    properties = {
      sku = {
        name     = "Standard_v2"
        tier     = "Standard_v2"
        capacity = var.appgw_sku_capacity
      }

      gatewayIPConfigurations = [
        {
          name = "appgw-ip-config"
          properties = {
            subnet = {
              id = local.appgw_subnet_id
            }
          }
        }
      ]

      frontendIPConfigurations = [
        {
          name = "frontend-private"
          properties = {
            privateIPAllocationMethod = "Static"
            privateIPAddress          = var.appgw_frontend_ip
            subnet = {
              id = local.appgw_subnet_id
            }
            privateLinkConfiguration = {
              id = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${var.resource_group_name}/providers/Microsoft.Network/applicationGateways/${local.appgw_full_name}/privateLinkConfigurations/privatelink-config"
            }
          }
        },
        {
          name = "frontend-public-unused"
          properties = {
            publicIPAddress = {
              id = azurerm_public_ip.appgw_management.id
            }
          }
        }
      ]

      frontendPorts = [
        {
          name = "port-kafka"
          properties = {
            port = var.kafka_port
          }
        }
      ]

      backendAddressPools = [
        {
          name = "backend-confluent-pe"
          properties = {
            backendAddresses = [
              {
                ipAddress = azurerm_private_endpoint.confluent.private_service_connection[0].private_ip_address
              },
            ]
          }
        }
      ]

      backendSettingsCollection = [
        {
          name = "backend-settings-kafka"
          properties = {
            port     = var.kafka_port
            protocol = "Tcp"
            timeout  = 60
          }
        }
      ]

      listeners = [
        {
          name = "listener-kafka"
          properties = {
            frontendIPConfiguration = {
              id = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${var.resource_group_name}/providers/Microsoft.Network/applicationGateways/${local.appgw_full_name}/frontendIPConfigurations/frontend-private"
            }
            frontendPort = {
              id = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${var.resource_group_name}/providers/Microsoft.Network/applicationGateways/${local.appgw_full_name}/frontendPorts/port-kafka"
            }
            protocol = "Tcp"
          }
        }
      ]

      routingRules = [
        {
          name = "rule-kafka"
          properties = {
            ruleType = "Basic"
            priority = 100
            listener = {
              id = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${var.resource_group_name}/providers/Microsoft.Network/applicationGateways/${local.appgw_full_name}/listeners/listener-kafka"
            }
            backendAddressPool = {
              id = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${var.resource_group_name}/providers/Microsoft.Network/applicationGateways/${local.appgw_full_name}/backendAddressPools/backend-confluent-pe"
            }
            backendSettings = {
              id = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${var.resource_group_name}/providers/Microsoft.Network/applicationGateways/${local.appgw_full_name}/backendSettingsCollection/backend-settings-kafka"
            }
          }
        }
      ]

      privateLinkConfigurations = [
        {
          name = "privatelink-config"
          properties = {
            ipConfigurations = [
              {
                name = "privatelink-ipconfig"
                properties = {
                  privateIPAllocationMethod = "Dynamic"
                  primary                   = true
                  subnet = {
                    id = local.appgw_privatelink_subnet_id
                  }
                }
              }
            ]
          }
        }
      ]
    }
  }

  depends_on = [
    time_sleep.wait_for_pe,
    azurerm_subnet.appgw,
    azurerm_subnet.appgw_privatelink,
    azurerm_public_ip.appgw_management
  ]
}

# =============================================================================
# Data sources
# =============================================================================

data "azurerm_subscription" "current" {}
