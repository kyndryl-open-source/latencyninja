output "vms" {
  description = "VM names and IDs"
  value = merge(
    { for k, v in proxmox_virtual_environment_vm.test : "ln-${k}" => v.vm_id },
    { for k, v in proxmox_virtual_environment_vm.lab : "ln-${k}" => v.vm_id }
  )
}

output "management_ips" {
  description = "Primary IPv4 per VM as reported by the guest agent (empty until the agent is up)"
  value = merge(
    { for k, v in proxmox_virtual_environment_vm.test : "ln-${k}" => try(v.ipv4_addresses[1][0], "") },
    { for k, v in proxmox_virtual_environment_vm.lab : "ln-${k}" => try(v.ipv4_addresses[1][0], "") }
  )
}

output "ssh_hint" {
  value = "ssh ${var.vm_user}@<ip>   then:  ln-test   (runs the suite)  |  ln-test --ref <branch>  |  ln-test <name-filter>"
}
