resource "azurerm_network_interface" "node" {
  for_each            = var.nodes
  name                = "${var.name_prefix}-${each.key}-nic"
  resource_group_name = var.resource_group_name
  location            = var.location

  ip_configuration {
    name                          = "${var.name_prefix}-${each.key}-nic"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"

    # Same flag on both sides: no public IP exists to attach when false.
    public_ip_address_id = var.assign_public_ip ? azurerm_public_ip.node[each.key].id : null
  }

  tags = var.tags
}

## ---------------------------------------------------------
## Public IP - only for pools that ask for.
## ---------------------------------------------------------
resource "azurerm_public_ip" "node" {
  for_each            = var.assign_public_ip ? var.nodes : {}
  name                = "${var.name_prefix}-${each.key}-PublicIP"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = var.tags
}


resource "azurerm_linux_virtual_machine" "node" {
  for_each              = var.nodes
  name                  = "${var.name_prefix}-${each.key}"
  resource_group_name   = var.resource_group_name
  location              = var.location
  size                  = coalesce(each.value.vm_size, var.vm_size)
  zone                  = each.value.zone
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.node[each.key].id]

  priority        = var.priority
  eviction_policy = var.priority == "Spot" ? var.eviction_policy : null
  custom_data     = var.custom_data == null ? null : base64encode(var.custom_data)

  # no spot
  admin_ssh_key {
    username   = var.admin_username
    public_key = var.admin_ssh_public_key
  }

  dynamic "admin_ssh_key" {
    for_each = var.additional_ssh_public_keys
    content {
      username   = var.admin_username
      public_key = admin_ssh_key.value
    }
  }

  os_disk {
    caching              = var.disk_caching
    storage_account_type = var.disk_storage_account_type
    disk_size_gb         = coalesce(each.value.disk_size_gb, var.disk_size_gb)
  }

  # Block in the provider schema, so it cannot take the object directly.
  source_image_reference {
    publisher = var.source_image_reference.publisher
    offer     = var.source_image_reference.offer
    sku       = var.source_image_reference.sku
    version   = var.source_image_reference.version
  }

  tags = var.tags
}

resource "azurerm_network_security_group" "node" {
  for_each            = var.nodes
  name                = "nsg-${var.name_prefix}-${each.key}"
  resource_group_name = var.resource_group_name
  location            = var.location

  dynamic "security_rule" {
    for_each = var.security_rules
    content {
      name                       = security_rule.value.name
      priority                   = security_rule.value.priority
      direction                  = security_rule.value.direction
      access                     = security_rule.value.access
      protocol                   = security_rule.value.protocol
      source_port_range          = security_rule.value.source_port_range
      destination_port_ranges    = security_rule.value.destination_port_ranges
      source_address_prefixes    = security_rule.value.source_address_prefixes
      destination_address_prefix = "*"
    }
  }

  tags = var.tags
}

resource "azurerm_network_interface_security_group_association" "node" {
  for_each                  = var.nodes
  network_interface_id      = azurerm_network_interface.node[each.key].id
  network_security_group_id = azurerm_network_security_group.node[each.key].id
}
