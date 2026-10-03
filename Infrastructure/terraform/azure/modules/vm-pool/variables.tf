# =========================================================
# POOL IDENTITY
# =========================================================

variable "name_prefix" {
  type        = string
  description = "Resource prefix for the pool."
}

variable "nodes" {
  description = "Ordinal key => per-node config. Keys are permanent identity: never renumbered, never reused, gaps are normal."

  type = map(object({
    zone         = optional(string) # null = no zone pinning
    vm_size      = optional(string) # null = var.vm_size
    disk_size_gb = optional(number) # null = var.disk_size_gb
  }))

  validation {
    condition     = alltrue([for k, _ in var.nodes : can(tonumber(k))])
    error_message = "Node keys must be numeric ordinals (\"1\", \"2\", ...), not names."
  }

  # Azure exposes at most 3 zones per region, always named "1" "2" "3".
  # null is allowed and means no zone pinning - used by single-node
  validation {
    condition = alltrue([
      for n in values(var.nodes) : n.zone == null || contains(["1", "2", "3"], n.zone)
    ])
    error_message = "node zone must be \"1\", \"2\", \"3\" or null."
  }
}

# =========================================================
# PLACEMENT - passed in by root, never looked up here
# =========================================================

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "subnet_id" {
  type = string
}

# =========================================================
# POOL DEFAULTS - per-node entries in var.nodes win
# =========================================================

variable "vm_size" {
  type = string
}

variable "disk_size_gb" {
  type    = number
  default = 30
}

variable "disk_storage_account_type" {
  type    = string
  default = "Standard_LRS"
}

variable "disk_caching" {
  type    = string
  default = "None"
}

variable "admin_username" {
  type    = string
  default = "azureadm"
}

variable "admin_ssh_public_key" {
  type        = string
  description = "Key material, not a path. Root does the file() read."
}

variable "additional_ssh_public_keys" {
  type        = list(string)
  default     = []
  description = "Extra public keys trusted for admin_username, alongside admin_ssh_public_key."
}

variable "custom_data" {
  type        = string
  default     = null
  description = "Plain-text cloud-init config, not base64. Root does the file()/templatefile() read; module base64-encodes it."
}

variable "priority" {
  type    = string
  default = "Regular"

  validation {
    condition     = contains(["Regular", "Spot"], var.priority)
    error_message = "priority must be \"Regular\" or \"Spot\"."
  }
}

variable "eviction_policy" {
  type        = string
  default     = null
  description = "Only used when priority is Spot, forced to null otherwise."
}

variable "source_image_reference" {
  description = "Resolved once in root so pools share one image version."
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = string
  })
}

# =========================================================
# NETWORK ACCESS - one NSG per NIC
# =========================================================

variable "assign_public_ip" {
  type    = bool
  default = false
}

variable "security_rules" {
  description = "Applied to every node in the pool. Empty = Azure defaults only."
  type = list(object({
    name                    = string
    priority                = number
    direction               = string
    access                  = string
    protocol                = string
    source_port_range       = optional(string, "*")
    destination_port_ranges = list(string)
    source_address_prefixes = list(string)
  }))
  default = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
