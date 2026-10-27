variable "subscription_id" {
  type = string
}

variable "location" {
  type    = string
  default = "westeurope"
}

variable "resource_group_name" {
  type    = string
  default = "latencyninja-lab"
}

variable "ssh_public_keys" {
  description = "SSH public keys for the VM user (Azure requires at least one)"
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
  description = "Distro VMs that run the functional suite. Any of: ubuntu, debian, rocky (Fedora is not on the Azure marketplace)"
  type        = set(string)
  default     = ["ubuntu", "rocky"]

  validation {
    condition     = alltrue([for d in var.test_distros : contains(["ubuntu", "debian", "rocky"], d)])
    error_message = "test_distros may only contain ubuntu, debian and rocky on Azure."
  }
}

variable "enable_lab" {
  description = "Build a client and a server (10.99.1.10 / 10.99.1.20, same subnet). No router VM in the cloud examples"
  type        = bool
  default     = true
}

variable "vm_size" {
  type    = string
  default = "Standard_B2s"
}

variable "disk_gb" {
  type    = number
  default = 30
}

variable "repo_url" {
  type    = string
  default = "https://github.com/kyndryl-open-source/latencyninja.git"
}

variable "repo_ref" {
  type    = string
  default = "main"
}

variable "tags" {
  type    = map(string)
  default = { Project = "latencyninja", ManagedBy = "terraform" }
}
