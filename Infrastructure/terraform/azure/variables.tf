variable "subscription_id" {
  type        = string
  description = "Azure subscription ID"
}

variable "location" {
  type        = string
  description = "Azure location"
}

variable "admin_ssh_public_key_path" {
  type        = string
  description = "Path to the SSH public key installed for the admin user on every VM"
  default     = "~/.ssh/id_ed25519.pub"
}

variable "k8s_network" {
  type = object({
    vnet_name_prefix = string
    vnet_cidr        = string
  })

  default = {
    vnet_name_prefix = "vnet-proving-ground"
    vnet_cidr        = "192.168.0.0/16"
  }
}

variable "k8s_subnets" {
  type = map(object({
    name   = string
    prefix = string
  }))
  description = "Subnets in the VNET, keyed by role."
  default = {
    masters = { name = "subnet-masters", prefix = "192.168.0.0/24" }
    workers = { name = "subnet-workers", prefix = "192.168.1.0/24" }
    utils   = { name = "subnet-utils", prefix = "192.168.254.0/24" }
  }
}

# =========================================================
# NODE IMAGE
# =========================================================
variable "ubuntu_image" {
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = string
  })

  default = {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}

# =========================================================
# CLUSTER SHAPE
# =========================================================
variable "k8s_config" {
  type = object({
    master_count    = number
    worker_count    = number
    vm_size_master  = string
    vm_size_worker  = string
    priority        = string
    eviction_policy = string
    zones           = list(string)
  })

  default = {
    master_count    = 1
    worker_count    = 2
    vm_size_master  = "Standard_D2s_v3"
    vm_size_worker  = "Standard_D2s_v3"
    priority        = "Spot"
    eviction_policy = "Delete"
    zones           = ["1"] #["1", "2", "3"]
  }

  # Zone validation checks for master nodes
  validation {
    condition     = length(var.k8s_config.zones) > 0
    error_message = "Zones must not be empty"
  }

  # Azure names zones per region, never more than 3, always "1" "2" "3".
  # A region may expose fewer - that check needs module.regions and
  # lives in the zone_guard precondition in main.tf.
  validation {
    condition     = alltrue([for z in var.k8s_config.zones : contains(["1", "2", "3"], z)])
    error_message = "zones may only contain \"1\", \"2\" or \"3\"."
  }

  validation {
    condition     = var.k8s_config.master_count % 2 == 1
    error_message = "master_count must be odd. An even count adds a node without adding fault tolerance."
  }

  validation {
    condition     = var.k8s_config.master_count >= 1 && var.k8s_config.master_count <= 7
    error_message = "master_count must be between 1 and 7."
  }
}

variable "k8s_api_endpoint" {
  type = object({
    dns_zone    = string
    record_name = string
    lb_host_num = number
  })

  default = {
    dns_zone    = "proving-ground.internal"
    record_name = "k8s-api"
    lb_host_num = 250
  }
}

variable "disk_storage_type" {
  type    = string
  default = "StandardSSD_LRS"
}

variable "disk_size_gb" {
  type    = number
  default = 30
}


variable "jumphost" {
  type = object({
    vm_size         = string
    priority        = string
    eviction_policy = string
  })

  default = {
    vm_size         = "Standard_D2s_v3"
    priority        = "Spot"
    eviction_policy = "Delete"
  }
}

# NSG rules
variable "master_security_rules" {
  type = list(object({
    name                    = string
    priority                = number
    direction               = string # "Inbound" or "Outbound"
    access                  = string # "Allow" or "Deny"
    protocol                = string # "Tcp", "Udp", "*"
    source_port_range       = optional(string, "*")
    destination_port_ranges = list(string)
    source_address_prefixes = list(string)
  }))
  default = []

  # Example: 10 ports allowed from 2 subnets, in a single rule
  # default = [
  #   {
  #     name      = "Allow-K8s-Control-Plane-Ports"
  #     priority  = 100
  #     direction = "Inbound"
  #     access    = "Allow"
  #     protocol  = "Tcp"
  #     destination_port_ranges = [
  #       "6443", "2379-2380", "10250", "10251", "10252",
  #       "10255", "10256", "179", "4789", "9099",
  #     ]
  #     source_address_prefixes = [
  #       "192.168.1.0/24",   # subnet_worker
  #       "192.168.254.0/24", # subnet_utils
  #     ]
  #   }
  # ]
}

variable "worker_security_rules" {
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

variable "jumphost_security_rules" {
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
  default = [
    {
      name                    = "Allow-SSH-From-Internet"
      priority                = 100
      direction               = "Inbound"
      access                  = "Allow"
      protocol                = "Tcp"
      destination_port_ranges = ["22"]
      source_address_prefixes = ["0.0.0.0/0"]
    }
  ]
}
