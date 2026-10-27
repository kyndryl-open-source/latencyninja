# ---------- Proxmox connection ----------

variable "proxmox_endpoint" {
  description = "Proxmox API URL, e.g. https://pve.example.com:8006/"
  type        = string
}

variable "proxmox_api_token" {
  description = "API token as user@realm!tokenid=secret (export TF_VAR_proxmox_api_token)"
  type        = string
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Skip TLS verification (self-signed certificate)"
  type        = bool
  default     = true
}

variable "proxmox_ssh_user" {
  description = "SSH user on the Proxmox node, used to upload cloud-init snippets (needs your key in its authorized_keys)"
  type        = string
  default     = "root"
}

variable "node_name" {
  description = "Proxmox node that hosts the VMs"
  type        = string
}

# ---------- Storage and network ----------

variable "disk_datastore" {
  description = "Datastore for VM disks (e.g. local-lvm, local-zfs)"
  type        = string
  default     = "local-lvm"
}

variable "image_datastore" {
  description = "Datastore for downloaded cloud images. Must allow the 'import' content type (Proxmox VE 8.4+)"
  type        = string
  default     = "local"
}

variable "snippet_datastore" {
  description = "Datastore for cloud-init snippets. Must allow the 'snippets' content type"
  type        = string
  default     = "local"
}

variable "bridge" {
  description = "Bridge for the management/primary NIC (DHCP is expected)"
  type        = string
  default     = "vmbr0"
}

variable "lab_bridge_a" {
  description = "Bridge for lab segment A (client side, 10.99.1.0/24). Leave both lab bridges empty for a flat lab on `bridge` with no router"
  type        = string
  default     = ""
}

variable "lab_bridge_b" {
  description = "Bridge for lab segment B (server side, 10.99.2.0/24). May equal lab_bridge_a when the segments are separated by VLAN"
  type        = string
  default     = ""
}

variable "lab_vlan_a" {
  description = "VLAN tag for segment A, or null for untagged"
  type        = number
  default     = null
}

variable "lab_vlan_b" {
  description = "VLAN tag for segment B, or null for untagged"
  type        = number
  default     = null
}

# ---------- Access ----------

variable "ssh_public_keys" {
  description = "SSH public keys injected for the VM user"
  type        = list(string)
}

variable "vm_user" {
  description = "Login user created by cloud-init (passwordless sudo)"
  type        = string
  default     = "ninja"
}

# ---------- What to build ----------

variable "test_distros" {
  description = "Distro VMs that run the functional test suite. Any of: ubuntu, debian, fedora, rocky"
  type        = set(string)
  default     = ["ubuntu", "fedora"]

  validation {
    condition     = alltrue([for d in var.test_distros : contains(["ubuntu", "debian", "fedora", "rocky"], d)])
    error_message = "test_distros may only contain ubuntu, debian, fedora and rocky."
  }
}

variable "enable_lab" {
  description = "Build the client / router / server lab for real-traffic tests"
  type        = bool
  default     = true
}

variable "vm_id_start" {
  description = "First VM ID; VMs are numbered upwards from here"
  type        = number
  default     = 9100
}

variable "cpu_cores" {
  type    = number
  default = 2
}

variable "memory_mb" {
  type    = number
  default = 2048
}

variable "disk_gb" {
  type    = number
  default = 20
}

variable "tags" {
  type    = list(string)
  default = ["latencyninja", "terraform"]
}

# ---------- Latency Ninja source ----------

variable "repo_url" {
  type    = string
  default = "https://github.com/kyndryl-open-source/latencyninja.git"
}

variable "repo_ref" {
  description = "Branch or tag the VMs check out"
  type        = string
  default     = "main"
}

# ---------- Cloud images (override when a URL moves) ----------

variable "image_urls" {
  type = map(string)
  default = {
    ubuntu = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
    debian = "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
    fedora = "https://download.fedoraproject.org/pub/fedora/linux/releases/42/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-42-1.1.x86_64.qcow2"
    rocky  = "https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"
  }
}
