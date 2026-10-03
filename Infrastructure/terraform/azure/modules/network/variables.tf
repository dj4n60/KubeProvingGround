variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}


variable "network" {
  type = object({
    vnet_name_prefix = string
    vnet_cidr        = string
  })
  description = "Azure VNET name prefix and address space"
}

variable "subnet" {
  type = map(object({
    name   = string
    prefix = string
  }))
  description = "Subnets to create in the VNET. Key is the role, e.g. masters."
}
