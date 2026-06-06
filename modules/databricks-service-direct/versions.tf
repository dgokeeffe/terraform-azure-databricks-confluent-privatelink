terraform {
  required_version = ">= 1.5.0"

  required_providers {
    databricks = {
      source = "databricks/databricks"
      # databricks_endpoint (Public Preview) was added in provider v1.107.0.
      # It must be configured with an ACCOUNT-level provider (host =
      # https://accounts.azuredatabricks.net, account_id set).
      version = ">= 1.107.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.80.0"
    }
    azapi = {
      source = "azure/azapi"
      # Used only to read the private endpoint's properties.resourceGuid,
      # which azurerm does not export but databricks_endpoint requires.
      version = ">= 2.0.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9.0"
    }
  }
}
