output "name_prefix" {
  description = "Resource name prefix, for consumers that need the pool's identity string."
  value       = var.name_prefix
}

output "private_ips" {
  description = "Ordinal => private IP."
  value       = { for k, v in azurerm_linux_virtual_machine.node : k => v.private_ip_address }
}

output "nic_ip_configurations" {
  description = "Ordinal => NIC ID and its ip_configuration name."
  value = { for k, v in azurerm_network_interface.node : k => {
    nic_id                = v.id
    ip_configuration_name = v.ip_configuration[0].name
  } }

  # NIC writes race - a parallel pool association drops the NSG.
  depends_on = [azurerm_network_interface_security_group_association.node]
}

output "public_ips" {
  description = "Ordinal => public IP. Empty unless assign_public_ip is true."
  value       = { for k, v in azurerm_public_ip.node : k => v.ip_address }
}
