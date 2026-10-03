locals {
  proving_ground_tags_rg = {
    Name        = "Testing-Lab"
    Application = "Kubernetes"
    Environment = "Lab"
    Managed_By  = "Terraform"
  }

}


# =========================================================
# Resource Groups
# =========================================================

## Master RG
resource "azurerm_resource_group" "master_nodes" {
  name     = "rg-master-nodes"
  location = var.location
  tags     = local.proving_ground_tags_rg
}
## Worker RG
resource "azurerm_resource_group" "worker_nodes" {
  name     = "rg-worker-nodes"
  location = var.location
  tags     = local.proving_ground_tags_rg
}
## Network RG
resource "azurerm_resource_group" "network" {
  name     = "rg-k8s-network"
  location = var.location
  tags     = local.proving_ground_tags_rg
}

## Utils RG
resource "azurerm_resource_group" "utils" {
  name     = "rg-utils-network"
  location = var.location
  tags     = local.proving_ground_tags_rg
}

# =========================================================
# Networking
# =========================================================

## K8s VNET and subnets
module "k8s-vnet" {
  source = "./modules/network"

  resource_group_name = azurerm_resource_group.network.name
  location            = azurerm_resource_group.network.location
  tags                = local.proving_ground_tags_rg

  network = var.k8s_network
  subnet  = var.k8s_subnets
}

# =========================================================
# ZONE DISCOVERY
# =========================================================
module "regions" {
  source  = "Azure/avm-utl-regions/azurerm"
  version = "0.12.0"
}

locals {
  region_zones = module.regions.regions_by_name_or_display_name[var.location].zones
}

resource "terraform_data" "zone_guard" {
  input = local.region_zones

  lifecycle {
    precondition {
      condition     = length(local.region_zones) > 0
      error_message = "Region ${var.location} has no availability zones. Pick a zonal region."
    }

    precondition {
      condition     = length(setsubtract(var.k8s_config.zones, local.region_zones)) == 0
      error_message = "Requested zones ${jsonencode(var.k8s_config.zones)} but ${var.location} offers ${jsonencode(local.region_zones)}."
    }
  }
}

locals {
  masters = { for i in range(var.k8s_config.master_count) :
    tostring(i + 1) => {
      zone = var.k8s_config.zones[i % length(var.k8s_config.zones)]
    }
  }

  workers = { for i in range(var.k8s_config.worker_count) :
    tostring(i + 1) => {
      zone = var.k8s_config.zones[i % length(var.k8s_config.zones)]
    }
  }

  admin_ssh_public_key = file(var.admin_ssh_public_key_path)
}

resource "tls_private_key" "jumphost_automation" {
  algorithm = "ED25519"
}

# =========================================================
# COMPUTE POOLS
# =========================================================

module "masters" {
  source = "./modules/vm-pool"

  name_prefix = "k8s-master"
  nodes       = local.masters

  resource_group_name = azurerm_resource_group.master_nodes.name
  location            = azurerm_resource_group.master_nodes.location
  subnet_id           = module.k8s-vnet.subnet_ids["masters"]

  vm_size                   = var.k8s_config.vm_size_master
  disk_size_gb              = var.disk_size_gb
  disk_storage_account_type = var.disk_storage_type
  priority                  = var.k8s_config.priority
  eviction_policy           = var.k8s_config.eviction_policy

  admin_ssh_public_key       = local.admin_ssh_public_key
  additional_ssh_public_keys = [tls_private_key.jumphost_automation.public_key_openssh]
  source_image_reference     = var.ubuntu_image

  # Public frontend - in-VNet callers arrive from the LB or jumphost public IP.
  security_rules = concat(var.master_security_rules, [
    {
      name                    = "Allow-K8s-API-From-Egress-IPs"
      priority                = 1000
      direction               = "Inbound"
      access                  = "Allow"
      protocol                = "Tcp"
      source_port_range       = "*"
      destination_port_ranges = ["6443"]
      source_address_prefixes = concat([azurerm_public_ip.k8s_api.ip_address], values(module.jumphost.public_ips))
    }
  ])

  tags = local.proving_ground_tags_rg
}

# =========================================================
# CONTROL PLANE ENDPOINT
# =========================================================
resource "azurerm_public_ip" "k8s_api" {
  name                = "pip-k8s-api"
  resource_group_name = azurerm_resource_group.master_nodes.name
  location            = azurerm_resource_group.master_nodes.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.proving_ground_tags_rg
}

resource "azurerm_lb" "k8s_api" {
  name                = "lb-k8s-api"
  resource_group_name = azurerm_resource_group.master_nodes.name
  location            = azurerm_resource_group.master_nodes.location
  sku                 = "Standard"

  frontend_ip_configuration {
    name                 = "k8s-api-frontend"
    public_ip_address_id = azurerm_public_ip.k8s_api.id
  }

  tags = local.proving_ground_tags_rg
}

resource "azurerm_lb_backend_address_pool" "k8s_api" {
  name            = "k8s-api-masters"
  loadbalancer_id = azurerm_lb.k8s_api.id
}

resource "azurerm_network_interface_backend_address_pool_association" "k8s_api" {
  for_each                = module.masters.nic_ip_configurations
  network_interface_id    = each.value.nic_id
  ip_configuration_name   = each.value.ip_configuration_name
  backend_address_pool_id = azurerm_lb_backend_address_pool.k8s_api.id
}

resource "azurerm_lb_probe" "k8s_api" {
  name            = "k8s-api-6443"
  loadbalancer_id = azurerm_lb.k8s_api.id
  protocol        = "Tcp"
  port            = 6443
}

resource "azurerm_lb_rule" "k8s_api" {
  name                           = "k8s-api-6443"
  loadbalancer_id                = azurerm_lb.k8s_api.id
  protocol                       = "Tcp"
  frontend_port                  = 6443
  backend_port                   = 6443
  frontend_ip_configuration_name = azurerm_lb.k8s_api.frontend_ip_configuration[0].name
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.k8s_api.id]
  probe_id                       = azurerm_lb_probe.k8s_api.id
  disable_outbound_snat          = true
}

## ---------------------------------------------------------
## Egress - masters and workers share one outbound rule
## ---------------------------------------------------------
resource "azurerm_lb_backend_address_pool" "egress" {
  name            = "k8s-egress"
  loadbalancer_id = azurerm_lb.k8s_api.id
}

resource "azurerm_network_interface_backend_address_pool_association" "egress" {
  for_each = merge(
    { for k, v in module.masters.nic_ip_configurations : "${module.masters.name_prefix}-${k}" => v },
    { for k, v in module.workers.nic_ip_configurations : "${module.workers.name_prefix}-${k}" => v },
  )
  network_interface_id    = each.value.nic_id
  ip_configuration_name   = each.value.ip_configuration_name
  backend_address_pool_id = azurerm_lb_backend_address_pool.egress.id

  # Both pool writes touch the master NIC - run them one at a time.
  depends_on = [azurerm_network_interface_backend_address_pool_association.k8s_api]
}

# Azure allows one outbound rule per frontend and protocol.
resource "azurerm_lb_outbound_rule" "egress" {
  name                    = "k8s-egress"
  loadbalancer_id         = azurerm_lb.k8s_api.id
  protocol                = "All"
  backend_address_pool_id = azurerm_lb_backend_address_pool.egress.id

  frontend_ip_configuration {
    name = azurerm_lb.k8s_api.frontend_ip_configuration[0].name
  }
}

resource "azurerm_private_dns_zone" "k8s" {
  name                = var.k8s_api_endpoint.dns_zone
  resource_group_name = azurerm_resource_group.network.name
  tags                = local.proving_ground_tags_rg
}

resource "azurerm_private_dns_zone_virtual_network_link" "k8s" {
  name                 = "link-${module.k8s-vnet.vnet_name}"
  private_dns_zone_id  = azurerm_private_dns_zone.k8s.id
  virtual_network_id   = module.k8s-vnet.vnet_id
  registration_enabled = true
  tags                 = local.proving_ground_tags_rg
}

resource "azurerm_private_dns_a_record" "k8s_api" {
  name                = var.k8s_api_endpoint.record_name
  private_dns_zone_id = azurerm_private_dns_zone.k8s.id
  ttl                 = 300
  records             = [azurerm_public_ip.k8s_api.ip_address]
  tags                = local.proving_ground_tags_rg
}

## ---------------------------------------------------------
## Workers - pool
## ---------------------------------------------------------
module "workers" {
  source = "./modules/vm-pool"

  name_prefix = "k8s-worker"
  nodes       = local.workers

  resource_group_name = azurerm_resource_group.worker_nodes.name
  location            = azurerm_resource_group.worker_nodes.location
  subnet_id           = module.k8s-vnet.subnet_ids["workers"]

  vm_size                   = var.k8s_config.vm_size_worker
  disk_size_gb              = var.disk_size_gb
  disk_storage_account_type = var.disk_storage_type
  priority                  = var.k8s_config.priority
  eviction_policy           = var.k8s_config.eviction_policy

  admin_ssh_public_key       = local.admin_ssh_public_key
  additional_ssh_public_keys = [tls_private_key.jumphost_automation.public_key_openssh]
  source_image_reference     = var.ubuntu_image

  security_rules = var.worker_security_rules

  tags = local.proving_ground_tags_rg
}

## ---------------------------------------------------------
## Jumphost - pool
## ---------------------------------------------------------
module "jumphost" {
  source = "./modules/vm-pool"

  name_prefix = "k8s-jumphost"
  nodes       = { "1" = {} }

  resource_group_name = azurerm_resource_group.utils.name
  location            = azurerm_resource_group.utils.location
  subnet_id           = module.k8s-vnet.subnet_ids["utils"]

  vm_size                   = var.jumphost.vm_size
  disk_size_gb              = var.disk_size_gb
  disk_storage_account_type = var.disk_storage_type
  priority                  = var.jumphost.priority
  eviction_policy           = var.jumphost.eviction_policy

  admin_ssh_public_key   = local.admin_ssh_public_key
  source_image_reference = var.ubuntu_image

  custom_data = templatefile("${path.module}/cloud-init/jumphost.yaml.tftpl", {
    automation_private_key = tls_private_key.jumphost_automation.private_key_openssh
    automation_public_key  = tls_private_key.jumphost_automation.public_key_openssh
  })

  assign_public_ip = true
  security_rules   = var.jumphost_security_rules

  tags = local.proving_ground_tags_rg
}

locals {
  ansible_inventory = {
    all = {
      children = {
        (module.masters.name_prefix) = {
          hosts = { for k, ip in module.masters.private_ips : "${module.masters.name_prefix}-${k}" => { ansible_host = ip } }
        }
        (module.workers.name_prefix) = {
          hosts = { for k, ip in module.workers.private_ips : "${module.workers.name_prefix}-${k}" => { ansible_host = ip } }
        }
        (module.jumphost.name_prefix) = {
          hosts = { for k, ip in module.jumphost.public_ips : "${module.jumphost.name_prefix}-${k}" => { ansible_host = ip } }
        }
      }
      vars = {
        ansible_user = "azureadm"
      }
    }
  }
}

resource "local_file" "ansible_inventory" {
  filename = "${path.root}/cluster.json"
  content  = jsonencode(local.ansible_inventory)

  depends_on = [module.masters, module.workers, module.jumphost]
}

resource "terraform_data" "ansible_sync" {
  triggers_replace = [
    module.jumphost.public_ips["1"],
    sha1(join("", [for f in fileset("${path.root}/../../ansible", "**") : filesha1("${path.root}/../../ansible/${f}")])),
    local_file.ansible_inventory.content_sha1,
  ]

  depends_on = [module.jumphost]

  provisioner "local-exec" {
    command = "scp -r -o ConnectTimeout=10 -o ConnectionAttempts=60 -o StrictHostKeyChecking=accept-new ${path.root}/../../ansible azureadm@${module.jumphost.public_ips["1"]}:/home/azureadm && scp -o ConnectTimeout=10 -o ConnectionAttempts=60 ${local_file.ansible_inventory.filename} azureadm@${module.jumphost.public_ips["1"]}:/home/azureadm/ansible/inventory/cluster.json"
  }
}
