source "azure-arm" "image" {
  client_cert_path                       = var.client_cert_path
  client_id                              = var.client_id
  client_secret                          = var.client_secret
  object_id                              = var.object_id
  oidc_request_token                     = var.oidc_request_token
  oidc_request_url                       = var.oidc_request_url
  subscription_id                        = var.subscription_id
  tenant_id                              = var.tenant_id
  use_azure_cli_auth                     = var.use_azure_cli_auth

  allowed_inbound_ip_addresses           = var.allowed_inbound_ip_addresses
  build_key_vault_name                   = var.build_key_vault_name
  build_key_vault_secret_name            = var.build_key_vault_secret_name
  build_resource_group_name              = var.build_resource_group_name
  communicator                           = "winrm"
  image_publisher                        = split(":", local.source_image_marketplace_sku)[0]
  image_offer                            = split(":", local.source_image_marketplace_sku)[1]
  image_sku                              = split(":", local.source_image_marketplace_sku)[2]
  image_version                          = var.source_image_version
  location                               = var.location
  managed_image_name                     = var.managed_image_name
  managed_image_resource_group_name      = var.managed_image_resource_group_name
  managed_image_storage_account_type     = var.managed_image_storage_account_type
  os_disk_size_gb                        = local.os_disk_size_gb
  os_type                                = var.image_os_type
  private_virtual_network_with_public_ip = var.private_virtual_network_with_public_ip
  temp_resource_group_name               = var.temp_resource_group_name
  virtual_network_name                   = var.virtual_network_name
  virtual_network_resource_group_name    = var.virtual_network_resource_group_name
  virtual_network_subnet_name            = var.virtual_network_subnet_name
  vm_size                                = var.vm_size
  winrm_expiration_time                  = var.winrm_expiration_time
  winrm_insecure                         = "true"
  winrm_use_ssl                          = "true"
  winrm_timeout                          = var.winrm_timeout
  winrm_username                         = var.winrm_username

  # Gallery publish removed from Packer (2026-06-14): the runtime UAMI that authenticates
  # this build has only Contributor scoped to AZURE_BUILD_RESOURCE_GROUP, NOT gallery write.
  # A separate publish-to-gallery job in BuildALGoRunnerImage.yaml runs on OIDC as the
  # image-builder UAMI (sub Contributor) and calls `az sig image-version create` against
  # the captured managed image. This keeps gallery write off the high-blast-radius runtime
  # identity (assumable by every CI job on the pool via IMDS).
  # See gh-vmss-img-runners FromVmImageAgent doc 15 (2026-06-14) for the RBAC rationale.

  dynamic "azure_tag" {
    for_each = var.azure_tags
    content {
      name  = azure_tag.key
      value = azure_tag.value
    }
  }
}
