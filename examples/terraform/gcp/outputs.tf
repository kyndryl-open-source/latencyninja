output "public_ips" {
  value = { for k, v in google_compute_instance.vm : "ln-${k}" => v.network_interface[0].access_config[0].nat_ip }
}

output "private_ips" {
  description = "Use these for client -> server tests (server is 10.99.1.20)"
  value       = { for k, v in google_compute_instance.vm : "ln-${k}" => v.network_interface[0].network_ip }
}

output "ssh_hint" {
  value = "ssh ${var.vm_user}@<public ip>   then:  ln-test   |  ln-test --ref <branch>  |  ln-test <name-filter>"
}
