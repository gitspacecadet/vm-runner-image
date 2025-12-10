################################################################################
# Packer plugin requirements
# This file is auto-loaded by Packer and declares required plugins
################################################################################

packer {
  required_plugins {
    azure = {
      version = ">= 2.0.0"
      source  = "github.com/hashicorp/azure"
    }
  }
}
