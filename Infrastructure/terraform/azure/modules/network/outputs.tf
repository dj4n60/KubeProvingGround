output "vnet_name" {
  value = azurerm_virtual_network.vnet.name
}

output "vnet_id" {
  value = azurerm_virtual_network.vnet.id
}

output "subnet_ids" {
  description = "Subnet IDs keyed by role"
  value       = { for role, s in azurerm_subnet.subnet : role => s.id }
}
