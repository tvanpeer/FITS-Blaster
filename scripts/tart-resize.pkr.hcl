# tart-resize.pkr.hcl — Packer template behind scripts/tart-resize-base.sh.
#
# Clones a base VM, grows the clone's disk, moves the recovery partition to the end of the
# disk ("relocate", so macOS updates keep working) and lets macOS claim the new space
# (diskutil repairDisk + apfs resizeContainer, done by the plugin over SSH). The base VM
# itself is not changed. See docs/internal/testing.md (VMs, Resize a base VM).

packer {
  required_plugins {
    tart = {
      version = "= 1.21.0"
      source  = "github.com/cirruslabs/tart"
    }
  }
}

variable "base" { type = string }
variable "name" { type = string }
variable "disk_gb" { type = number }

source "tart-cli" "resize" {
  vm_base_name         = var.base
  vm_name              = var.name
  disk_size_gb         = var.disk_gb
  recovery_partition   = "relocate"
  headless             = true
  ssh_username         = "fitstester"
  ssh_private_key_file = "~/.ssh/fitsvm_ed25519"
  ssh_timeout          = "300s"
}

build {
  sources = ["source.tart-cli.resize"]

  # Show the result: the container's new size and the recovery partition at the end.
  provisioner "shell" {
    inline = [
      "sw_vers",
      "diskutil list physical",
      "diskutil apfs list | grep -E 'Container Reference|Size \\(Capacity|Capacity In Use|Not Allocated'",
      "df -h /",
    ]
  }
}
