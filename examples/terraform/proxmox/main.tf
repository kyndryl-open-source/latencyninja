locals {
  distros = {
    ubuntu = { family = "debian", image = var.image_urls["ubuntu"] }
    debian = { family = "debian", image = var.image_urls["debian"] }
    fedora = { family = "rhel", image = var.image_urls["fedora"] }
    rocky  = { family = "rhel", image = var.image_urls["rocky"] }
  }

  split_lab = var.lab_bridge_a != "" && var.lab_bridge_b != ""

  # Lab VMs run Ubuntu: the distro matrix is covered by the test VMs
  lab_vms = var.enable_lab ? merge(
    {
      client = { role = "client", ip_a = "10.99.1.10", route_net = "10.99.2.0/24", route_via = "10.99.1.1" }
      server = { role = "server", ip_b = "10.99.2.20", route_net = "10.99.1.0/24", route_via = "10.99.2.1" }
    },
    local.split_lab ? { router = { role = "router", ip_a = "10.99.1.1", ip_b = "10.99.2.1" } } : {}
  ) : {}

  # Every VM, in a stable order so VM IDs don't shift when the selection changes
  all_names = concat(sort(tolist(var.test_distros)), ["client", "router", "server"])
  vm_ids    = { for i, n in local.all_names : n => var.vm_id_start + i }

  provision_b64 = base64encode(file("${path.module}/../common/cloud-init/provision.sh"))

  images = toset(concat(
    [for d in var.test_distros : d],
    var.enable_lab ? ["ubuntu"] : []
  ))
}

resource "proxmox_virtual_environment_download_file" "image" {
  for_each = local.images

  node_name    = var.node_name
  datastore_id = var.image_datastore
  content_type = "import"
  url          = local.distros[each.key].image
  # The import content type only accepts .qcow2/.raw/.vmdk names, whatever the URL ends in
  file_name = "latencyninja-${each.key}.qcow2"
  overwrite = false
}

# ---------- cloud-init user data ----------

resource "proxmox_virtual_environment_file" "user_data" {
  for_each = merge(
    { for d in var.test_distros : d => { family = local.distros[d].family, role = "test", lab_ip = "", route_net = "", route_via = "" } },
    { for n, v in local.lab_vms : n => {
      family    = "debian"
      role      = v.role
      lab_ip    = lookup(v, "ip_a", lookup(v, "ip_b", ""))
      route_net = local.split_lab ? lookup(v, "route_net", "") : ""
      route_via = local.split_lab ? lookup(v, "route_via", "") : ""
    } }
  )

  node_name    = var.node_name
  datastore_id = var.snippet_datastore
  content_type = "snippets"

  source_raw {
    file_name = "ln-${each.key}-user-data.yaml"
    data = templatefile("${path.module}/../common/cloud-init/user-data.yaml.tftpl", {
      hostname      = "ln-${each.key}"
      user          = var.vm_user
      ssh_keys      = var.ssh_public_keys
      provision_b64 = local.provision_b64
      role          = each.value.role
      family        = each.value.family
      repo_url      = var.repo_url
      repo_ref      = var.repo_ref
      lab_ip        = each.value.lab_ip
      route_net     = each.value.route_net
      route_via     = each.value.route_via
    })
  }
}

# ---------- distro test VMs ----------

resource "proxmox_virtual_environment_vm" "test" {
  for_each = var.test_distros

  name      = "ln-${each.key}"
  node_name = var.node_name
  vm_id     = local.vm_ids[each.key]
  tags      = concat(var.tags, ["test", each.key])

  # Boot only after the image import finishes; keep running across host reboots
  on_boot         = false
  stop_on_destroy = true

  agent {
    enabled = true
  }

  cpu {
    cores = var.cpu_cores
    type  = "host"
  }

  memory {
    dedicated = var.memory_mb
  }

  disk {
    datastore_id = var.disk_datastore
    import_from  = proxmox_virtual_environment_download_file.image[each.key].id
    interface    = "scsi0"
    size         = var.disk_gb
    discard      = "on"
    iothread     = true
  }

  network_device {
    bridge = var.bridge
  }

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id      = var.disk_datastore
    user_data_file_id = proxmox_virtual_environment_file.user_data[each.key].id

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }
}

# ---------- lab VMs (client / router / server) ----------

resource "proxmox_virtual_environment_vm" "lab" {
  for_each = local.lab_vms

  name      = "ln-${each.key}"
  node_name = var.node_name
  vm_id     = local.vm_ids[each.key]
  tags      = concat(var.tags, ["lab", each.key])

  on_boot         = false
  stop_on_destroy = true

  agent {
    enabled = true
  }

  cpu {
    cores = var.cpu_cores
    type  = "host"
  }

  memory {
    dedicated = var.memory_mb
  }

  disk {
    datastore_id = var.disk_datastore
    import_from  = proxmox_virtual_environment_download_file.image["ubuntu"].id
    interface    = "scsi0"
    size         = var.disk_gb
    discard      = "on"
    iothread     = true
  }

  # NIC 0: management (DHCP) so you can always SSH in
  network_device {
    bridge = var.bridge
  }

  # NIC 1: segment A (client, router); NIC 2: segment B (router) or segment B for the server
  dynamic "network_device" {
    for_each = local.split_lab ? compact([
      contains(keys(each.value), "ip_a") ? "a" : "",
      contains(keys(each.value), "ip_b") ? "b" : ""
    ]) : []
    content {
      bridge  = network_device.value == "a" ? var.lab_bridge_a : var.lab_bridge_b
      vlan_id = network_device.value == "a" ? var.lab_vlan_a : var.lab_vlan_b
    }
  }

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id      = var.disk_datastore
    user_data_file_id = proxmox_virtual_environment_file.user_data[each.key].id

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    dynamic "ip_config" {
      for_each = local.split_lab ? compact([
        contains(keys(each.value), "ip_a") ? "a" : "",
        contains(keys(each.value), "ip_b") ? "b" : ""
      ]) : []
      content {
        ipv4 {
          address = "${ip_config.value == "a" ? each.value.ip_a : each.value.ip_b}/24"
          # No gateway: the management NIC owns the default route; the far segment is routed by ln-lab-route
        }
      }
    }
  }
}
