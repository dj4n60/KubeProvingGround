output "k8s_working_nodes" {
  value = module.workers.private_ips
}

output "k8s_master_nodes" {
  value = module.masters.private_ips
}

output "jumphost" {
  value = module.jumphost.private_ips
}

output "jumphost_public_ip" {
  value = module.jumphost.public_ips
}

output "k8s_api_fqdn" {
  value = "${azurerm_private_dns_a_record.k8s_api.name}.${azurerm_private_dns_zone.k8s.name}"
}

output "k8s_api_lb_ip" {
  value = azurerm_public_ip.k8s_api.ip_address
}

output "ansible_inventory" {
  value = local.ansible_inventory
}
