################################################################################
# Additional variables for AL-Go runner image
# These extend variable.windows.pkr.hcl with BC-specific options
################################################################################

variable "bc_generic_image" {
  type        = string
  default     = ""
  description = "Prototype generic digest override; empty uses the matched LTSC2022 toolset digest"
  validation {
    condition     = var.bc_generic_image == "" || can(regex("^mcr\\.microsoft\\.com/businesscentral@sha256:[0-9a-f]{64}$", var.bc_generic_image))
    error_message = "The prototype requires an immutable MCR Business Central digest."
  }
}

variable "bc_country" {
  type        = string
  default     = "us"
  description = "Business Central country code for artifact caching"
}

variable "bc_type" {
  type        = string
  default     = "Sandbox"
  description = "Business Central artifact type (Sandbox or OnPrem)"
}

variable "bc_select" {
  type        = string
  default     = "Latest"
  description = "Business Central version selection (Latest, Current, etc.)"
}

variable "bc_cache_skip" {
  type        = string
  default     = "false"
  description = "Set to 'true' to skip BC caching (faster builds for testing)"
}
