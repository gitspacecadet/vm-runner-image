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

variable "source_gallery_image_version" {
  type        = string
  # SPIKE ONLY (branch spike/l13-thin-run, never merge): L13 base layer from
  # deploy run 45791462248 (recipe b3af4600, bc_cache_skip=true).
  default     = "1.20261126.0923"
  description = "L13 thin build: gallery version (in gallery_name/gallery_image_name) of the base layer to boot. Empty = marketplace source (full build)."
}

variable "bc_cache_skip" {
  type        = string
  default     = "false"
  description = "Set to 'true' to skip BC caching (faster builds for testing)"
}
