variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "europe-west1"
}

variable "zone" {
  type    = string
  default = "europe-west1-b"
}

variable "ssh_public_keys" {
  description = "SSH public keys for the VM user"
  type        = list(string)
}

variable "allowed_ssh_cidrs" {
  description = "Source ranges allowed to SSH in. Use your own address (x.x.x.x/32), not 0.0.0.0/0"
  type        = list(string)
}

variable "vm_user" {
  type    = string
  default = "ninja"
}

variable "test_distros" {
  description = "Distro VMs that run the functional suite. Any of: ubuntu, debian, rocky (Fedora has no public GCE image)"
  type        = set(string)
  default     = ["ubuntu", "rocky"]

  validation {
    condition     = alltrue([for d in var.test_distros : contains(["ubuntu", "debian", "rocky"], d)])
    error_message = "test_distros may only contain ubuntu, debian and rocky on GCP."
  }
}

variable "enable_lab" {
  description = "Build a client and a server (10.99.1.10 / 10.99.1.20, same subnet). No router VM in the cloud examples"
  type        = bool
  default     = true
}

variable "machine_type" {
  type    = string
  default = "e2-medium"
}

variable "disk_gb" {
  type    = number
  default = 20
}

variable "repo_url" {
  type    = string
  default = "https://github.com/kyndryl-open-source/latencyninja.git"
}

variable "repo_ref" {
  type    = string
  default = "main"
}

variable "labels" {
  type    = map(string)
  default = { project = "latencyninja", managed-by = "terraform" }
}
