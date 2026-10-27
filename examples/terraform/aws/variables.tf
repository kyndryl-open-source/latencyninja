variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "ssh_public_keys" {
  description = "SSH public keys for the VM user. The first one is also registered as the EC2 key pair"
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
  description = "Distro VMs that run the functional suite. Any of: ubuntu, debian, fedora, rocky"
  type        = set(string)
  default     = ["ubuntu", "fedora"]

  validation {
    condition     = alltrue([for d in var.test_distros : contains(["ubuntu", "debian", "fedora", "rocky"], d)])
    error_message = "test_distros may only contain ubuntu, debian, fedora and rocky."
  }
}

variable "enable_lab" {
  description = "Build a client and a server (10.99.1.10 / 10.99.1.20, same subnet) for real-traffic tests. No router: AWS does not let you override the local VPC route"
  type        = bool
  default     = true
}

variable "instance_type" {
  type    = string
  default = "t3.small"
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

variable "ami_overrides" {
  description = "Pin an AMI per distro instead of the newest public one, e.g. { fedora = \"ami-0123...\" }"
  type        = map(string)
  default     = {}
}

variable "tags" {
  type    = map(string)
  default = { Project = "latencyninja", ManagedBy = "terraform" }
}
