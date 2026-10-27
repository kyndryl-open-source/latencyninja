locals {
  distros = {
    ubuntu = {
      family = "debian"
      image  = { publisher = "Canonical", offer = "ubuntu-24_04-lts", sku = "server", version = "latest" }
      plan   = null
    }
    debian = {
      family = "debian"
      image  = { publisher = "Debian", offer = "debian-12", sku = "12-gen2", version = "latest" }
      plan   = null
    }
    rocky = {
      family = "rhel"
      image  = { publisher = "resf", offer = "rockylinux-x86_64", sku = "9-base", version = "latest" }
      plan   = { name = "9-base", product = "rockylinux-x86_64", publisher = "resf" }
    }
  }

  lab_vms = var.enable_lab ? {
    client = { role = "client", ip = "10.99.1.10" }
    server = { role = "server", ip = "10.99.1.20" }
  } : {}

  vms = merge(
    { for d in var.test_distros : d => { distro = d, role = "test", ip = null } },
    { for n, v in local.lab_vms : n => { distro = "ubuntu", role = v.role, ip = v.ip } }
  )
}

resource "azurerm_resource_group" "lab" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# The Rocky image is a marketplace offer: the terms must be accepted once per subscription
resource "azurerm_marketplace_agreement" "rocky" {
  count = contains(var.test_distros, "rocky") ? 1 : 0

  publisher = "resf"
  offer     = "rockylinux-x86_64"
  plan      = "9-base"
}

resource "azurerm_virtual_network" "lab" {
  name                = "latencyninja"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  address_space       = ["10.99.0.0/16"]
  tags                = var.tags
}

resource "azurerm_subnet" "lab" {
  name                 = "lab"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = ["10.99.1.0/24"]
}

# VM-to-VM traffic inside the VNet is allowed by Azure's default rules
resource "azurerm_network_security_group" "lab" {
  name                = "latencyninja"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = var.tags

  security_rule {
    name                       = "ssh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefixes    = var.allowed_ssh_cidrs
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "lab" {
  subnet_id                 = azurerm_subnet.lab.id
  network_security_group_id = azurerm_network_security_group.lab.id
}

resource "azurerm_public_ip" "vm" {
  for_each = local.vms

  name                = "ln-${each.key}"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_interface" "vm" {
  for_each = local.vms

  name                = "ln-${each.key}"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = var.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.lab.id
    private_ip_address_allocation = each.value.ip == null ? "Dynamic" : "Static"
    private_ip_address            = each.value.ip
    public_ip_address_id          = azurerm_public_ip.vm[each.key].id
  }
}

resource "azurerm_linux_virtual_machine" "vm" {
  for_each = local.vms

  name                  = "ln-${each.key}"
  computer_name         = "ln-${each.key}"
  location              = azurerm_resource_group.lab.location
  resource_group_name   = azurerm_resource_group.lab.name
  size                  = var.vm_size
  admin_username        = var.vm_user
  network_interface_ids = [azurerm_network_interface.vm[each.key].id]
  tags                  = var.tags

  dynamic "admin_ssh_key" {
    for_each = toset(var.ssh_public_keys)
    content {
      username   = var.vm_user
      public_key = admin_ssh_key.value
    }
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = var.disk_gb
  }

  source_image_reference {
    publisher = local.distros[each.value.distro].image.publisher
    offer     = local.distros[each.value.distro].image.offer
    sku       = local.distros[each.value.distro].image.sku
    version   = local.distros[each.value.distro].image.version
  }

  dynamic "plan" {
    for_each = local.distros[each.value.distro].plan == null ? [] : [local.distros[each.value.distro].plan]
    content {
      name      = plan.value.name
      product   = plan.value.product
      publisher = plan.value.publisher
    }
  }

  custom_data = base64encode(templatefile("${path.module}/../common/cloud-init/user-data.yaml.tftpl", {
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
  }))

  depends_on = [azurerm_marketplace_agreement.rocky]
}
