locals {
  distros = {
    ubuntu = { family = "debian", image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64" }
    debian = { family = "debian", image = "debian-cloud/debian-12" }
    rocky  = { family = "rhel", image = "rocky-linux-cloud/rocky-linux-9" }
  }

  lab_vms = var.enable_lab ? {
    client = { role = "client", ip = "10.99.1.10" }
    server = { role = "server", ip = "10.99.1.20" }
  } : {}

  vms = merge(
    { for d in var.test_distros : d => { distro = d, role = "test", ip = null } },
    { for n, v in local.lab_vms : n => { distro = "ubuntu", role = v.role, ip = v.ip } }
  )

  ssh_keys = join("\n", [for k in var.ssh_public_keys : "${var.vm_user}:${k}"])
}

resource "google_compute_network" "lab" {
  name                    = "latencyninja"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "lab" {
  name          = "latencyninja"
  network       = google_compute_network.lab.id
  ip_cidr_range = "10.99.1.0/24"
}

resource "google_compute_firewall" "ssh" {
  name          = "latencyninja-ssh"
  network       = google_compute_network.lab.name
  source_ranges = var.allowed_ssh_cidrs
  target_tags   = ["latencyninja"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "internal" {
  name          = "latencyninja-internal"
  network       = google_compute_network.lab.name
  source_ranges = [google_compute_subnetwork.lab.ip_cidr_range]
  target_tags   = ["latencyninja"]

  allow {
    protocol = "all"
  }
}

resource "google_compute_instance" "vm" {
  for_each = local.vms

  name         = "ln-${each.key}"
  machine_type = var.machine_type
  tags         = ["latencyninja"]
  labels       = var.labels

  boot_disk {
    initialize_params {
      image = local.distros[each.value.distro].image
      size  = var.disk_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.lab.id
    network_ip = each.value.ip

    access_config {} # ephemeral public IP
  }

  metadata = {
    ssh-keys       = local.ssh_keys
    enable-oslogin = "FALSE"
    # GCE images do not all run cloud-init, so the shared provisioner is started from a startup script
    startup-script = templatefile("${path.module}/../common/cloud-init/startup-script.sh.tftpl", {
      user          = var.vm_user
      role          = each.value.role
      family        = local.distros[each.value.distro].family
      repo_url      = var.repo_url
      repo_ref      = var.repo_ref
      provision_b64 = base64encode(file("${path.module}/../common/cloud-init/provision.sh"))
    })
  }
}
