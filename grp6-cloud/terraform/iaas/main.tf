terraform {
  backend "local" {
    path          = "/home/grp6/tfstate/iaas/default.tfstate"
    workspace_dir = "/home/grp6/tfstate/iaas"
  }
  required_providers {
    proxmox = { source = "bpg/proxmox" }
  }
}

variable "pm_token" { sensitive = true }
variable "name"     { default = "vm-test" }
variable "size"     { default = "small" }   # small | medium | large
variable "ip"       { default = "10.6.0.60" }
variable "os"       { default = "linux" }   # linux | windows
variable "admin_password" {
  default   = ""
  sensitive = true
}

locals {
  sizes = {
    small  = { cpu = 1, ram = 2048 }
    medium = { cpu = 2, ram = 4096 }
    large  = { cpu = 4, ram = 8192 }
  }
  templates  = { linux = 9000, windows = 9100 }
  is_windows = var.os == "windows"
}

provider "proxmox" {
  endpoint  = "https://10.6.0.1:8006/"
  api_token = var.pm_token
  insecure  = true
}

resource "proxmox_virtual_environment_vm" "vm" {
  name      = var.name
  node_name = "pve1"
  tags      = ["grp6", var.os, var.size]

  clone { vm_id = local.templates[var.os] }

  cpu    { cores = local.sizes[var.size].cpu }
  memory { dedicated = local.sizes[var.size].ram }
  agent  { enabled = false }

  network_device { bridge = "vmbr1" }

  initialization {
    datastore_id = "local-zfs"
    interface    = "ide2"
    type = local.is_windows ? "configdrive2" : "nocloud"

    dns { servers = ["8.8.8.8"] }

    ip_config {
      ipv4 {
        address = "${var.ip}/24"
        gateway = "10.6.0.1"
      }
    }

    user_account {
      username = local.is_windows ? "Administrator" : "grp6"
      password = local.is_windows ? var.admin_password : null
      keys     = local.is_windows ? [] : split("\n", trimspace(file("grp6_keys.pub")))
    }
  }
}
