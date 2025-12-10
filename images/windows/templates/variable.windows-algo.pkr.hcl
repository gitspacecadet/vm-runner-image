################################################################################
# Additional variables for AL-Go runner image
# These extend variable.windows.pkr.hcl with BC-specific options
################################################################################

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
