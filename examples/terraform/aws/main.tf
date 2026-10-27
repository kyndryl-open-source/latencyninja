locals {
  distros = {
    ubuntu = { family = "debian", owner = "099720109477", name = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" }
    debian = { family = "debian", owner = "136693071363", name = "debian-12-amd64-*" }
    rocky  = { family = "rhel", owner = "792107900819", name = "Rocky-9-EC2-Base-9.*.x86_64*" }
    fedora = { family = "rhel", owner = "125523088429", name = "Fedora-Cloud-Base-AmazonEC2.x86_64-42-*" }
  }

  lab_vms = var.enable_lab ? {
    client = { role = "client", ip = "10.99.1.10" }
    server = { role = "server", ip = "10.99.1.20" }
  } : {}

  vms = merge(
    { for d in var.test_distros : d => { distro = d, role = "test", ip = null } },
    { for n, v in local.lab_vms : n => { distro = "ubuntu", role = v.role, ip = v.ip } }
  )

  amis_needed = toset([for v in local.vms : v.distro])
}

data "aws_ami" "image" {
  for_each = { for d in local.amis_needed : d => d if !contains(keys(var.ami_overrides), d) }

  most_recent = true
  owners      = [local.distros[each.key].owner]

  filter {
    name   = "name"
    values = [local.distros[each.key].name]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# ---------- network ----------

resource "aws_vpc" "lab" {
  cidr_block           = "10.99.0.0/16"
  enable_dns_hostnames = true
  tags                 = merge(var.tags, { Name = "latencyninja" })
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id
  tags   = merge(var.tags, { Name = "latencyninja" })
}

resource "aws_subnet" "lab" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = "10.99.1.0/24"
  map_public_ip_on_launch = true
  tags                    = merge(var.tags, { Name = "latencyninja" })
}

resource "aws_route_table" "lab" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }

  tags = merge(var.tags, { Name = "latencyninja" })
}

resource "aws_route_table_association" "lab" {
  subnet_id      = aws_subnet.lab.id
  route_table_id = aws_route_table.lab.id
}

resource "aws_security_group" "lab" {
  name_prefix = "latencyninja-"
  vpc_id      = aws_vpc.lab.id
  description = "SSH from allowed_ssh_cidrs, everything between lab VMs"

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  ingress {
    description = "Between lab VMs"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "latencyninja" })
}

resource "aws_key_pair" "lab" {
  key_name_prefix = "latencyninja-"
  public_key      = var.ssh_public_keys[0]
  tags            = var.tags
}

# ---------- VMs ----------

resource "aws_instance" "vm" {
  for_each = local.vms

  ami                    = lookup(var.ami_overrides, each.value.distro, null) != null ? var.ami_overrides[each.value.distro] : data.aws_ami.image[each.value.distro].id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.lab.id
  private_ip             = each.value.ip
  vpc_security_group_ids = [aws_security_group.lab.id]
  key_name               = aws_key_pair.lab.key_name

  root_block_device {
    volume_size = var.disk_gb
    volume_type = "gp3"
  }

  user_data = templatefile("${path.module}/../common/cloud-init/user-data.yaml.tftpl", {
    hostname      = "ln-${each.key}"
    user          = var.vm_user
    ssh_keys      = var.ssh_public_keys
    provision_b64 = base64encode(file("${path.module}/../common/cloud-init/provision.sh"))
    role          = each.value.role
    family        = local.distros[each.value.distro].family
    repo_url      = var.repo_url
    repo_ref      = var.repo_ref
    lab_ip        = ""
    route_net     = ""
    route_via     = ""
  })

  tags = merge(var.tags, { Name = "ln-${each.key}" })
}
