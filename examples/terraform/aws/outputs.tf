output "public_ips" {
  value = { for k, v in aws_instance.vm : "ln-${k}" => v.public_ip }
}

output "private_ips" {
  description = "Use these for client -> server tests (server is 10.99.1.20)"
  value       = { for k, v in aws_instance.vm : "ln-${k}" => v.private_ip }
}

output "ssh_hint" {
  value = "ssh ${var.vm_user}@<public ip>   then:  ln-test   |  ln-test --ref <branch>  |  ln-test <name-filter>"
}
