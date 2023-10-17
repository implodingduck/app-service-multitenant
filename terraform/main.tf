terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=3.73.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "=3.1.0"
    }
    azapi = {
      source = "azure/azapi"
      version = "=1.3.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.15.0"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

locals {
  name = "asmulti${random_string.unique.result}"
  loc_for_naming = lower(replace(var.location, " ", ""))
  loc_short = "${upper(substr(var.location, 0 , 1))}US"
  gh_repo = "app-service-multitenant"
  tags = {
    "managed_by" = "terraform"
    "repo"       = local.gh_repo
  }
}

resource "random_string" "unique" {
  length  = 8
  special = false
  upper   = false
}


data "azurerm_client_config" "current" {}

data "azurerm_log_analytics_workspace" "default" {
  name                = "DefaultWorkspace-${data.azurerm_client_config.current.subscription_id}-${local.loc_short}"
  resource_group_name = "DefaultResourceGroup-${local.loc_short}"
} 

resource "azurerm_resource_group" "rg" {
  name     = "rg-${local.gh_repo}-${random_string.unique.result}-${local.loc_for_naming}"
  location = var.location
  tags = local.tags
}

resource "azurerm_service_plan" "this" {
  name                = "asp-${local.name}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = "B1"
}

resource "azurerm_linux_web_app" "this" {
  name                = local.name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_service_plan.this.location
  service_plan_id     = azurerm_service_plan.this.id

  site_config {
    application_stack {
        python_version = "3.10"
    }
    app_command_line = "./run.sh"
  }

  app_settings = {
    MICROSOFT_PROVIDER_AUTHENTICATION_SECRET = "@Microsoft.KeyVault(VaultName=${azurerm_key_vault.kv.name};SecretName=${azurerm_key_vault_secret.secret.name})"
  }

  auth_settings_v2 {
    auth_enabled = true
    default_provider = "azureactivedirectory"
    active_directory_v2 {
        client_id = azuread_application.this.application_id
        tenant_auth_endpoint = "https://login.microsoftonline.com/common/v2.0"
        client_secret_setting_name = "MICROSOFT_PROVIDER_AUTHENTICATION_SECRET"
    }
    login {
      token_store_enabled = true
    }
  }

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_key_vault" "kv" {
  name                       = "kv-${local.name}"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  purge_protection_enabled   = false

}

resource "azurerm_key_vault_access_policy" "sp" {
  key_vault_id = azurerm_key_vault.kv.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  key_permissions = [
    "Create",
    "Get",
    "Purge",
    "Recover",
    "Delete"
  ]

  secret_permissions = [
    "Set",
    "Purge",
    "Get",
    "List",
    "Delete"
  ]

  certificate_permissions = [
    "Purge"
  ]

  storage_permissions = [
    "Purge"
  ]

}

resource "azurerm_key_vault_access_policy" "as" {
  key_vault_id = azurerm_key_vault.kv.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_linux_web_app.this.identity[0].principal_id

  secret_permissions = [
    "Get",
    "List"
  ]

}

resource "azuread_application" "this" {
    display_name     = local.name
    owners           = [data.azurerm_client_config.current.object_id]
    sign_in_audience = "AzureADMultipleOrgs"
    web {
        redirect_uris = [ "https://${local.name}.azurewebsites.net/.auth/login/aad/callback" ]
        implicit_grant {
          access_token_issuance_enabled = false
          id_token_issuance_enabled     = true
        }
    }
}

resource "azuread_application_password" "this" {
  application_object_id = azuread_application.this.object_id
}

resource "azurerm_key_vault_secret" "secret" {
  name         = "SECRET"
  value        = azuread_application_password.this.value
  key_vault_id = azurerm_key_vault.kv.id
}

resource "local_file" "push" {
    content     = <<-EOT
az webapp up -g ${azurerm_resource_group.rg.name} -n ${local.name} -l ${local.loc_for_naming} -r "PYTHON:3.10"
EOT
    filename = "../push.sh"
}