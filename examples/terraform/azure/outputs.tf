output "public_ips" {
  value = { for k, v in azurerm_public_ip.vm : "ln-${k}" => v.ip_address }
}

output "private_ips" {
  description = "Use these for client -> server tests (server is 10.99.1.20)"
  value       = { for k, v in azurerm_network_interface.vm : "ln-${k}" => v.private_ip_address }
}

output "ssh_hint" {
  value = "ssh ${var.vm_user}@<public ip>   then:  ln-test   |  ln-test --ref <branch>  |  ln-test <name-filter>"
}
