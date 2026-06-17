variable "subscription_id" {
  type        = string
  description = "Target Azure subscription ID."
}

variable "name_prefix" {
  type        = string
  description = "Short prefix for resource names (lowercase letters/numbers and hyphens)."
  default     = "docgw"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,18}$", var.name_prefix))
    error_message = "name_prefix must be 3-19 chars, start with a letter, lowercase letters/numbers/hyphens only."
  }
}

variable "environment" {
  type        = string
  description = "Environment short name (e.g. dev, test, prod)."
  default     = "dev"

  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "environment must be one of: dev, test, prod."
  }
}

variable "location" {
  type        = string
  description = "Azure region."
  default     = "canadacentral"
}

variable "allowed_group_object_id" {
  type        = string
  description = "Entra group object ID whose members may read documents. Assigned to the app and checked in code."

  validation {
    condition     = can(regex("^[0-9a-fA-F-]{36}$", var.allowed_group_object_id))
    error_message = "allowed_group_object_id must be a GUID."
  }
}

variable "docs_container_name" {
  type        = string
  description = "Blob container holding the legacy documents."
  default     = "legacy-docs"
}

variable "allowed_prefixes" {
  type        = list(string)
  description = "Optional blob path prefixes the gateway will serve (empty = whole container)."
  default     = []
}

variable "max_download_bytes" {
  type        = number
  description = "Maximum document size the gateway will stream (bytes)."
  default     = 104857600
}

variable "enable_private_networking" {
  type        = bool
  description = "When true, deploy a VNet + private endpoints for Storage and the Function, with public access locked down."
  default     = true
}

variable "deployer_ip" {
  type        = string
  description = "Public IP of the machine running Terraform, allowed through the storage firewall to seed containers and upload documents."
  default     = ""
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all resources."
  default = {
    workload = "document-gateway"
  }
}
