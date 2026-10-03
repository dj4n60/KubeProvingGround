## VNET
resource "azurerm_virtual_network" "vnet" {
  name                = "${var.network.vnet_name_prefix}-main"
  address_space       = [var.network.vnet_cidr]
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

## Subnets - one per entry in var.subnet, key is the role
resource "azurerm_subnet" "subnet" {
  # checkov:skip=CKV2_AZURE_31: NSGs are attached per NIC in the vm-pool module, so every node has its own rules. A subnet NSG would apply to all nodes at once.
  for_each             = var.subnet
  name                 = each.value.name
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [each.value.prefix]
}
