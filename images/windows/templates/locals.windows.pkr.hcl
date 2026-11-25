locals {
    image_properties_map = {
      "win19" = {
            source_image_marketplace_sku = "MicrosoftWindowsServer:WindowsServer:2019-Datacenter"
            os_disk_size_gb = 256
      },
      "win22" = {
            # ALGo fork, build-time L1 (2026-11-25): the windowsserver2022 offer gets the
            # monthly LCU 13+ days before WindowsServer (Nov: 20348.5873 vs 5773), which
            # saves the in-guest LCU + DISM ResetBase (~20-25 min). Same Gen1/x64/no plan.
            source_image_marketplace_sku = "MicrosoftWindowsServer:windowsserver2022:2022-Datacenter"
            os_disk_size_gb = 256
      },
      "win25" = {
            source_image_marketplace_sku = "MicrosoftWindowsServer:WindowsServer:2025-Datacenter"
            os_disk_size_gb = 150
      }
  }

  source_image_marketplace_sku = local.image_properties_map[var.image_os].source_image_marketplace_sku
  os_disk_size_gb = coalesce(var.os_disk_size_gb, local.image_properties_map[var.image_os].os_disk_size_gb)
}
